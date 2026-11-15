import AppKit
import SwiftUI
import Testing
import Vision

@testable import Herm

@Suite(.serialized) @MainActor
struct GroupChatOpeningTests {
    @Test
    func openingRoomWithStartedTailPreservesHistoryAndStatus() async {
        let client = OpeningRoomClient(messageCount: 2, bookkeepingCount: 400, startedTail: true)
        let store = GroupChatStore()
        store.bind(to: client)
        await store.poll("existing")
        #expect(client.sendCount == 0)
        #expect(store.events["existing"]?.map(\.seq) == [1, 2, 402])
    }

    @Test
    func openingRoomWithBookkeepingTailLoadsConversationWithoutSending() async {
        let client = OpeningRoomClient(messageCount: 2, bookkeepingCount: GroupChatStore.historyWindow)
        let store = GroupChatStore()
        store.bind(to: client)
        await store.poll("existing")
        #expect(client.sendCount == 0)
        #expect(store.events["existing"]?.map(\.seq) == [1, 2])
    }

    @Test(arguments: [2, 80])
    func openingExistingRoomRendersHistoryWithoutSending(messageCount: Int) async throws {
        let client = OpeningRoomClient(messageCount: messageCount)
        let store = GroupChatStore()
        store.bind(to: client)
        await store.refreshRooms()
        let bots = BotModeModel()
        let host = NSHostingView(
            rootView: GroupChatView(
                store: store, botMode: bots, roomID: "existing",
                toolbar: { identity, actions in
                    AnyView(
                        HStack {
                            identity
                            actions
                        })
                }, onDisbanded: {}
            ).dockThemedRoot().environment(\.dockHostVisible, true))
        host.frame = NSRect(x: 0, y: 0, width: 700, height: 650)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            if store.events["existing"]?.count == messageCount { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()
        #expect(client.sendCount == 0)
        #expect(store.events["existing"]?.count == messageCount)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let image = try #require(bitmap.cgImage)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        try VNImageRequestHandler(cgImage: image).perform([request])
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        #expect(text.contains("Stored message \(messageCount)"))
        if messageCount == 2 {
            await store.send("New message", to: "existing")
            try await Task.sleep(for: .milliseconds(200))
            host.layoutSubtreeIfNeeded()
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let updatedImage = try #require(bitmap.cgImage)
            let updatedRequest = VNRecognizeTextRequest()
            updatedRequest.recognitionLevel = .accurate
            try VNImageRequestHandler(cgImage: updatedImage).perform([updatedRequest])
            let updatedText = (updatedRequest.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: " ")
            #expect(client.sendCount == 1)
            #expect(store.events["existing"]?.map(\.text) == ["Stored message 1", "Stored message 2", "New message"])
            #expect(updatedText.contains("Stored message 2"))
            #expect(updatedText.contains("New message"))
        }
    }
}

@MainActor
private final class OpeningRoomClient: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    private let messageCount: Int
    private let bookkeepingCount: Int
    private let startedTail: Bool
    private(set) var sendCount = 0

    init(messageCount: Int, bookkeepingCount: Int = 0, startedTail: Bool = false) {
        self.messageCount = messageCount
        self.bookkeepingCount = bookkeepingCount
        self.startedTail = startedTail
    }
    func connect() async throws {}
    func close() {}

    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        switch method {
        case "groups.capabilities": return ["driver": true]
        case "groups.list":
            return [
                "rooms": [["room_id": "existing", "name": "Existing room", "members": [], "latest_seq": messageCount]]
            ]
        case "groups.log":
            let since = params["since_seq"] as? Int ?? 0
            let originalLatest = messageCount + bookkeepingCount
            let latest = originalLatest + sendCount
            let end = min(latest, since + (params["limit"] as? Int ?? 500))
            let events: [[String: Any]] =
                since < end
                ? ((since + 1)...end).map { seq in
                    let kind: String
                    if seq <= messageCount || seq > originalLatest {
                        kind = "message.user"
                    } else if startedTail && seq == originalLatest {
                        kind = "turn.started"
                    } else {
                        kind = "turn.settled"
                    }
                    return [
                        "seq": seq, "event_id": "stored-\(seq)",
                        "kind": kind,
                        "created_at": 1_700_000_000.0,
                        "payload": [
                            "text": seq > originalLatest ? "New message" : "Stored message \(seq)",
                            "thread_id": "main", "member_id": "bot",
                        ],
                    ]
                } : []
            return ["events": events, "cursor": end, "latest_seq": latest, "has_more": end < latest]
        case "groups.state": return ["driver_status": ["working": false]]
        case "groups.send":
            sendCount += 1
            return [:]
        default: return [:]
        }
    }
}
