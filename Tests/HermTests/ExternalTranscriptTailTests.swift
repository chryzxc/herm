import AppKit
import Testing

@testable import Herm

@MainActor
struct ExternalTranscriptTailTests {
    @Test func simultaneousWindowsShareASessionReadButOtherProfilesDoNot() async throws {
        let client = ExternalReadClient()
        let pool = ExternalTranscriptReads()
        let path = "/api/sessions/chat/messages?profile=one"
        let first = Task { try await pool.fetch(path, client: client)["read"] as? Int }
        let second = Task { try await pool.fetch(path, client: client)["read"] as? Int }
        let results = try await [first.value, second.value]
        #expect(results == [1, 1])
        #expect(client.paths == [path])
        let otherProfile = "/api/sessions/chat/messages?profile=two"
        let other = try await pool.fetch(otherProfile, client: client)
        #expect(other["read"] as? Int == 2)
    }

    @Test func refreshKeepsOlderRowsAndImagesWhenAppendingANewReply() throws {
        let old = (1...800).map { ChatMessage(role: .user, text: "Message \($0)") }
        let image = NSImage(size: NSSize(width: 1, height: 1))
        let last = old[799].attachingImages([image])
        let live = ChatMessage(role: .hermes, text: "")
        let reply = ChatMessage(role: .hermes, text: "Finished")
        let current = Array(old.dropLast()) + [last, live]
        let recent = Array(old.suffix(20)) + [reply]
        let previousRows = Dictionary(uniqueKeysWithValues: zip(1...800, old.map(\.id)))
        let tailRows = Dictionary(uniqueKeysWithValues: zip(781...801, recent.map(\.id)))
        let result = ExternalTranscriptTail.merge(
            current: current, previousRows: previousRows, tail: recent, tailRows: tailRows, liveID: live.id)
        let merge = try #require(result)
        #expect(merge.messages.count == 802)
        #expect(Array(merge.messages.prefix(800).map(\.id)) == old.map(\.id))
        #expect(merge.messages[799].images.first === image)
        #expect(merge.messages[800].id == reply.id)
        #expect(merge.messages.last?.id == live.id)
        #expect(merge.inserted == [reply.id])
    }

    @Test func tailRereadDoesNotShiftTheOlderPageCursor() throws {
        var previous = TranscriptHistoryCursor(storageSessionID: "chat", profileID: nil)
        previous.nextOffset = 800
        previous.seenRowIDs = Set(1...800)
        var tail = TranscriptHistoryCursor(storageSessionID: "chat", profileID: nil)
        tail.nextOffset = 120
        tail.seenRowIDs = Set(686...805)
        let merged = try #require(ExternalTranscriptTail.cursor(keeping: previous, observing: tail))
        #expect(merged.nextOffset == 800)
        #expect(merged.hasMore)
        #expect(merged.seenRowIDs == Set(1...805))
    }

    @Test func legacyTailRequiresAnUnambiguousOverlap() throws {
        let earlier = ChatMessage(role: .hermes, text: "Old reply")
        let prompt = ChatMessage(role: .user, text: "Question")
        let reparsed = ChatMessage(role: .user, text: prompt.text)
        let reply = ChatMessage(role: .hermes, text: "New reply")
        let live = ChatMessage(role: .hermes, text: "")
        let merge = try #require(
            ExternalTranscriptTail.merge(
                current: [earlier, prompt, live], previousRows: [:], tail: [reparsed, reply], tailRows: [:],
                liveID: live.id
            ))
        #expect(merge.messages.map(\.id) == [earlier.id, prompt.id, reply.id, live.id])
        #expect(
            ExternalTranscriptTail.merge(
                current: [earlier, prompt, live], previousRows: [:], tail: [reparsed, reparsed, reply], tailRows: [:],
                liveID: live.id
            ) == nil)
    }
}

@MainActor
private final class ExternalReadClient: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    private(set) var paths: [String] = []

    func connect() async throws {}
    func close() {}
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] { [:] }

    func fetchHTTP(_ path: String) async throws -> [String: Any] {
        paths.append(path)
        let read = paths.count
        await Task.yield()
        return ["read": read]
    }
}
