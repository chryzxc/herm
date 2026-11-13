import Foundation
import Testing

@testable import Herm

@MainActor
struct GroupChatTests {
    @Test(arguments: ["groups.stop", "groups.rename", "groups.approve"])
    func failedRoomActionsKeepTheirErrorAndReleasePendingState(method: String) async throws {
        let client = RoomClient()
        client.failingMethod = method
        let store = GroupChatStore(defaults: freshDefaults())
        store.bind(to: client)
        switch method {
        case "groups.stop": await store.stop("r")
        case "groups.rename": await store.rename("r", to: "New name")
        default:
            let approval = try #require(
                GroupRoomApproval([
                    "kind": "approval", "member_id": "m", "task_id": "t", "request_id": "q",
                    "execution_generation": 1,
                ]))
            await store.respond(to: approval, in: "r", approve: true)
        }
        #expect(store.errorMessage?.contains("refused") == true)
        #expect(store.pendingRooms.isEmpty)
    }

    @Test func mapsRoomLogEventsAndSkipsBookkeeping() {
        let rows: [[String: Any]] = [
            ["seq": 1, "event_id": "a", "kind": "room.created", "payload": [:]],
            [
                "seq": 2, "event_id": "b", "kind": "message.user",
                "payload": ["text": "@cypher hey", "thread_id": "main"],
            ],
            ["seq": 3, "event_id": "c", "kind": "turn.started", "payload": ["member_id": "cypher"]],
            ["seq": 4, "event_id": "d", "kind": "message.member", "payload": ["member_id": "cypher", "text": "hi"]],
            ["seq": 5, "event_id": "e", "kind": "turn.failed", "payload": ["member_id": "forge", "error": "boom"]],
            ["seq": 6, "event_id": "f", "kind": "turn.settled", "payload": ["member_id": "cypher"]],
        ]
        let events = rows.compactMap(GroupRoomEvent.init)
        #expect(
            events.map(\.kind) == [
                .user, .started(memberID: "cypher"), .member(memberID: "cypher"), .failed(memberID: "forge"),
            ])
        #expect(events[0].text == "@cypher hey")
        #expect(events[3].text == "boom")
    }

    @Test func dropsDisbandedRoomsAndDefaultsMemberLabels() {
        #expect(GroupRoom(["room_id": "r", "name": "x", "members": [], "disbanded_at": 1.0]) == nil)
        let room = GroupRoom([
            "room_id": "r", "name": "Audit",
            "members": [["member_id": "default", "profile": "default", "handle": "hermes"]],
        ])
        #expect(room?.member("default")?.displayName == "hermes")
    }

    @Test func pollPagesThroughTheLogAndResumesFromTheCursor() async {
        let client = RoomClient()
        let store = GroupChatStore(defaults: freshDefaults())
        store.bind(to: client)
        await store.poll("r")
        #expect(store.events["r"]?.map(\.seq) == [1, 2])
        #expect(client.sinceSeqs == [0, 0, 1])
        await store.poll("r")
        #expect(client.sinceSeqs.last == 2)
        #expect(store.events["r"]?.count == 2)
        #expect(store.workingRooms.contains("r"))
        #expect(store.approvals["r"]?.first?.summary == "rm -rf build")
        #expect(store.retries["r"]?.first?.taskID == "t9")
        #expect(store.blockedRooms.contains("r"))
    }

    @Test func malformedLogPageDoesNotCommitEarlierPages() async {
        let client = RoomClient()
        client.logOverrides[1] = ["events": "malformed", "cursor": 2, "has_more": false]
        let store = GroupChatStore(defaults: freshDefaults())
        store.bind(to: client)
        await store.poll("r")
        #expect(store.events["r", default: []].isEmpty)
        client.logOverrides = [:]
        await store.poll("r")
        #expect(store.events["r"]?.map(\.seq) == [1, 2])
    }

    @Test func overlappingPollsDoNotDuplicateEvents() async {
        let client = RoomClient()
        let (pause, release) = AsyncStream<Void>.makeStream()
        let (started, signal) = AsyncStream<Void>.makeStream()
        client.logPause = pause
        client.logStarted = signal
        let store = GroupChatStore(defaults: freshDefaults())
        store.bind(to: client)
        let old = Task { await store.poll("r") }
        for await _ in started { break }
        await store.poll("r")
        release.yield(())
        release.finish()
        await old.value
        #expect(store.events["r"]?.map(\.seq) == [1, 2])
    }

    @Test func retryUsesTheOfferedAttemptAndRejectsStaleActions() async throws {
        let client = RoomClient()
        let store = GroupChatStore(defaults: freshDefaults())
        store.bind(to: client)
        await store.poll("r")
        let action = try #require(store.retries["r"]?.first)
        await store.retry(action, in: "r")
        #expect(client.retryParams?["task_id"] as? String == "t9")
        #expect(client.retryParams?["member_id"] as? String == "cypher")
        #expect(client.retryParams?["execution_generation"] as? Int == 3)
        let stale = try #require(
            GroupRoomRetry([
                "kind": "retry", "task_id": "t9", "member_id": "cypher", "execution_generation": 2,
            ]))
        client.retryParams = nil
        await store.retry(stale, in: "r")
        #expect(client.retryParams == nil)
    }

    @Test func disbandRequiresAMatchingTombstone() async {
        let client = RoomClient()
        let store = GroupChatStore(defaults: freshDefaults())
        store.bind(to: client)
        await store.refreshRooms()
        await store.disband("r")
        #expect(store.rooms.contains { $0.id == "r" })
        #expect(store.errorMessage != nil)
    }

    @Test func disbandRemovesRoomOnlyAfterConfirmedRefresh() async {
        let client = RoomClient()
        let store = GroupChatStore(defaults: freshDefaults())
        store.bind(to: client)
        await store.refreshRooms()
        client.disbandResult = ["tombstone": ["room_id": "r", "disbanded_at": 1.0]]
        client.listPages = [0: ["rooms": []]]
        await store.disband("r")
        #expect(store.rooms.isEmpty)
        #expect(store.errorMessage == nil)
    }

    @Test func disbandDoesNotTreatFailedEmptyRefreshAsConfirmation() async {
        let client = RoomClient()
        client.listPages = [0: ["rooms": []]]
        let store = GroupChatStore(defaults: freshDefaults())
        store.bind(to: client)
        await store.refreshRooms()
        client.disbandResult = ["tombstone": ["room_id": "r", "disbanded_at": 1.0]]
        client.failingMethod = "groups.list"
        await store.disband("r")
        #expect(store.errorMessage?.contains("could not be verified") == true)
    }

    @Test func longRoomsOpenAtTheTailAndLoadEarlierOnDemand() async {
        let client = RoomClient()
        client.latest = GroupChatStore.historyWindow + 1
        let store = GroupChatStore(defaults: freshDefaults())
        store.bind(to: client)
        await store.poll("r")
        #expect(store.earliestLoadedSeq["r"] == 1)
        #expect(client.sinceSeqs.dropFirst().first == 1)
        await store.loadEarlier("r")
        #expect(store.earliestLoadedSeq["r"] == 0)
        #expect(store.events["r"]?.first?.seq == 1)
    }

    @Test func memberTurnsSplitOnDriverPromptsAndMatchRoomReplies() {
        let rows: [[String: Any]] = [
            ["role": "user", "content": "[Discussion] ..."],
            [
                "role": "assistant", "content": "",
                "tool_calls": [["id": "c1", "function": ["name": "terminal", "arguments": "{\"command\":\"ls\"}"]]],
            ],
            ["role": "tool", "content": "a.txt"],
            ["role": "assistant", "content": "Found a.txt"],
            ["role": "user", "content": "[Discussion] ..."],
        ]
        let turns = GroupMemberTurn.turns(from: rows)
        #expect(turns.count == 2)
        #expect(turns[0].tools.map(\.name) == ["terminal"])
        #expect(turns[0].matches("Found a.txt\n"))
        #expect(turns[1].reply == nil)
    }

    @Test func eventsCarryTheirThreadAndSendTargetsIt() async {
        let event = GroupRoomEvent([
            "seq": 1, "event_id": "a", "kind": "message.user", "payload": ["text": "hi", "thread_id": "t-1"],
        ])
        #expect(event?.threadID == "t-1")
        let client = RoomClient()
        let store = GroupChatStore(defaults: freshDefaults())
        store.bind(to: client)
        await store.send("hello", to: "r", thread: "t-1")
        #expect((client.sent?["payload"] as? [String: Any])?["thread_id"] as? String == "t-1")
    }

    @Test func attachmentsUploadThenRideOnTheSendManifest() async throws {
        let client = RoomClient()
        let store = GroupChatStore(defaults: freshDefaults())
        store.bind(to: client)
        await store.refreshRooms()
        #expect(store.supportsAttachments)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("notes-\(UUID().uuidString).txt")
        try Data("hello".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try await store.uploadAttachment(url, to: "r")
        #expect(client.uploaded?["kind"] as? String == "file")
        #expect(client.uploaded?["mime"] as? String == "text/plain")
        #expect(client.uploaded?["data_base64"] as? String == Data("hello".utf8).base64EncodedString())
        await store.send("", attachments: [file], to: "r")
        let payload = client.sent?["payload"] as? [String: Any]
        #expect((payload?["attachments"] as? [[String: Any]])?.first?["attachment_id"] as? String == "att-1")
        let echoed = GroupRoomEvent([
            "seq": 3, "kind": "message.user", "payload": ["text": "", "attachments": [file.manifest]],
        ])
        #expect(echoed?.attachments == [file])
        #expect(GroupRoomAttachment.kind(forMIME: "image/png") == "image")
        #expect(GroupRoomAttachment.kind(forMIME: "application/pdf") == "pdf")
    }

    @Test func imageAttachmentsDownloadOnceAndRefusalsStayNamedRows() async {
        let client = RoomClient()
        let store = GroupChatStore(defaults: freshDefaults())
        store.bind(to: client)
        let image = GroupRoomAttachment(id: "img", kind: "image", name: "shot.png", mime: "image/png", size: 70)
        await store.loadImage(image, event: "e-1", in: "r")
        await store.loadImage(image, event: "e-1", in: "r")
        #expect(store.attachmentImages["img"] != nil)
        #expect(client.downloads == 1)
        let refused = GroupRoomAttachment(id: "gone", kind: "image", name: "x.png", mime: "image/png", size: 1)
        await store.loadImage(refused, event: "other", in: "r")
        await store.loadImage(refused, event: "other", in: "r")
        #expect(store.attachmentImages["gone"] == nil)
        #expect(client.downloads == 2)
        let file = GroupRoomAttachment(id: "doc", kind: "file", name: "a.txt", mime: "text/plain", size: 1)
        await store.loadImage(file, event: "e-1", in: "r")
        #expect(client.downloads == 2)
    }

    @Test func stopRemainsAvailableWhileSendIsPending() async {
        let client = RoomClient()
        let (pause, release) = AsyncStream<Void>.makeStream()
        let (started, didStart) = AsyncStream<Void>.makeStream()
        client.sendPause = pause
        client.sendStarted = didStart
        let store = GroupChatStore(defaults: freshDefaults())
        store.bind(to: client)
        let task = Task { await store.send("hello", to: "r") }
        for await _ in started { break }
        #expect(store.pendingRooms.contains("r"))
        #expect(store.sendingRooms.contains("r"))
        await store.send("duplicate", to: "r")
        await store.stop("r")
        #expect(client.sendCount == 1)
        #expect(client.stopCount == 1)
        #expect(store.pendingRooms.contains("r"))
        release.yield(())
        release.finish()
        await task.value
        #expect(store.pendingRooms.isEmpty)
        #expect(store.sendingRooms.isEmpty)
    }

    @Test func oldRenameCompletionCannotClearNewSendOrRefreshNewBinding() async {
        let old = RoomClient()
        let (pause, release) = AsyncStream<Void>.makeStream()
        let (started, didStart) = AsyncStream<Void>.makeStream()
        old.renamePause = pause
        old.renameStarted = didStart
        let store = GroupChatStore(defaults: freshDefaults())
        store.bind(to: old)
        let rename = Task { await store.rename("r", to: "old") }
        for await _ in started { break }
        let replacement = RoomClient()
        let (newPause, newRelease) = AsyncStream<Void>.makeStream()
        let (newStarted, newDidStart) = AsyncStream<Void>.makeStream()
        replacement.sendPause = newPause
        replacement.sendStarted = newDidStart
        store.bind(to: replacement)
        let send = Task { await store.send("new", to: "r") }
        for await _ in newStarted { break }
        release.yield(())
        release.finish()
        await rename.value
        #expect(store.pendingRooms.contains("r"))
        newRelease.yield(())
        newRelease.finish()
        await send.value
    }

    @Test func oldStateResponseCannotUpdateNewBinding() async {
        let old = RoomClient()
        let (pause, release) = AsyncStream<Void>.makeStream()
        let (started, didStart) = AsyncStream<Void>.makeStream()
        old.statePause = pause
        old.stateStarted = didStart
        let store = GroupChatStore(defaults: freshDefaults())
        store.bind(to: old)
        let polling = Task { await store.poll("r") }
        for await _ in started { break }
        let replacement = RoomClient()
        store.bind(to: replacement)
        await store.refreshRooms()
        release.yield(())
        release.finish()
        await polling.value
        #expect(!store.workingRooms.contains("r"))
        #expect(store.retries["r"] == nil)
    }

    @Test func oldSendCompletionCannotClearNewBindingPendingState() async {
        let old = RoomClient()
        let (oldPause, oldRelease) = AsyncStream<Void>.makeStream()
        let (oldStarted, oldDidStart) = AsyncStream<Void>.makeStream()
        old.sendPause = oldPause
        old.sendStarted = oldDidStart
        let store = GroupChatStore(defaults: freshDefaults())
        store.bind(to: old)
        let oldSend = Task { await store.send("old", to: "r") }
        for await _ in oldStarted { break }
        let replacement = RoomClient()
        let (newPause, newRelease) = AsyncStream<Void>.makeStream()
        let (newStarted, newDidStart) = AsyncStream<Void>.makeStream()
        replacement.sendPause = newPause
        replacement.sendStarted = newDidStart
        store.bind(to: replacement)
        let newSend = Task { await store.send("new", to: "r") }
        for await _ in newStarted { break }
        oldRelease.yield(())
        oldRelease.finish()
        await oldSend.value
        #expect(store.pendingRooms.contains("r"))
        #expect(!store.workingRooms.contains("r"))
        newRelease.yield(())
        newRelease.finish()
        await newSend.value
        #expect(store.pendingRooms.isEmpty)
    }

    @Test func roomListCollectsAllPagesAndKeepsPreviousOnInvalidCursor() async {
        let client = RoomClient()
        client.listPages = [
            0: ["rooms": [["room_id": "r", "members": []]], "next_offset": 1],
            1: ["rooms": [["room_id": "s", "members": []]], "next_offset": NSNull()],
        ]
        let store = GroupChatStore(defaults: freshDefaults())
        store.bind(to: client)
        await store.refreshRooms()
        #expect(store.rooms.map(\.id) == ["r", "s"])
        client.listPages = [0: ["rooms": [], "next_offset": 0]]
        await store.refreshRooms()
        #expect(store.rooms.map(\.id) == ["r", "s"])
    }

    @Test func malformedRoomRowDoesNotReplaceValidList() async {
        let client = RoomClient()
        let store = GroupChatStore(defaults: freshDefaults())
        store.bind(to: client)
        await store.refreshRooms()
        #expect(store.rooms.map(\.id) == ["r"])
        client.listPages = [0: ["rooms": [["name": "missing identity"]]]]
        await store.refreshRooms()
        #expect(store.rooms.map(\.id) == ["r"])
    }

    @Test func remoteMemberNeverLooksUpLocalSession() async {
        let client = RoomClient()
        client.listPages = [
            0: [
                "rooms": [
                    [
                        "room_id": "r",
                        "members": [
                            ["member_id": "peer", "profile": "same-name", "target": ["kind": "peer"]]
                        ],
                    ]
                ]
            ]
        ]
        let store = GroupChatStore(defaults: freshDefaults())
        store.bind(to: client)
        await store.refreshRooms()
        await store.poll("r")
        #expect(client.sessionListCount == 0)
    }

    @Test func oldRoomListResponseCannotReplaceNewBinding() async {
        let old = RoomClient()
        let (pause, release) = AsyncStream<Void>.makeStream()
        let (started, didStart) = AsyncStream<Void>.makeStream()
        old.listPause = pause
        old.listStarted = didStart
        let store = GroupChatStore(defaults: freshDefaults())
        store.bind(to: old)
        for await _ in started { break }
        let replacement = RoomClient()
        replacement.listPages = [0: ["rooms": [["room_id": "new", "members": []]]]]
        store.bind(to: replacement)
        await store.refreshRooms()
        release.yield(())
        release.finish()
        await Task.yield()
        #expect(store.rooms.map(\.id) == ["new"])
    }

    @Test func olderRefreshCannotReplaceNewerSnapshotOnSameBinding() async {
        let client = RoomClient()
        client.listPages = [0: ["rooms": [["room_id": "old", "members": []]]]]
        let (pause, release) = AsyncStream<Void>.makeStream()
        let (started, didStart) = AsyncStream<Void>.makeStream()
        let store = GroupChatStore(defaults: freshDefaults())
        let (initial, initialStarted) = AsyncStream<Void>.makeStream()
        client.listStarted = initialStarted
        store.bind(to: client)
        for await _ in initial { break }
        await store.refreshRooms()
        client.listPause = pause
        client.listStarted = didStart
        let oldRefresh = Task { await store.refreshRooms() }
        for await _ in started { break }
        client.listPages = [0: ["rooms": [["room_id": "new", "members": []]]]]
        await store.refreshRooms()
        release.yield(())
        release.finish()
        _ = await oldRefresh.value
        #expect(store.rooms.map(\.id) == ["new"])
    }

    @Test func roomsStartReadAndTurnUnreadOnLaterActivity() async {
        let client = RoomClient()
        let store = GroupChatStore(defaults: freshDefaults())
        store.bind(to: client)
        await store.refreshRooms()
        #expect(store.rooms.first.map(store.isUnread) == false)
        client.listedSeq = 9
        await store.refreshRooms()
        #expect(store.rooms.first.map(store.isUnread) == true)
        store.markSeen("r", through: 9)
        #expect(store.rooms.first.map(store.isUnread) == false)
    }

    @Test func backgroundPollDoesNotMarkRoomRead() async {
        let client = RoomClient()
        client.listedSeq = 0
        let store = GroupChatStore(defaults: freshDefaults())
        store.bind(to: client)
        await store.refreshRooms()
        client.listedSeq = 2
        await store.refreshRooms()
        #expect(store.rooms.first.map(store.isUnread) == true)
        await store.poll("r")
        #expect(store.rooms.first.map(store.isUnread) == true)
    }

    @Test func rebindingDoesNotReuseUnverifiedRoomReadMarkers() async {
        let defaults = freshDefaults()
        defaults.set(["r": 42], forKey: "groupChat.seenSeq")
        let store = GroupChatStore(defaults: defaults)
        let first = RoomClient()
        store.bind(to: first)
        store.markSeen("r", through: 50)
        store.bind(to: RoomClient())
        #expect(store.seenSeq["r"] == nil)
        #expect((defaults.dictionary(forKey: "groupChat.seenSeq")?["r"] as? Int) == 42)
    }

    @Test func roomLinkInviteRoundTripsIntoAPeerSeatAndRegisters() async throws {
        let client = RoomClient()
        let store = GroupChatStore(defaults: freshDefaults())
        store.bind(to: client)
        let requestCode = RoomLinkCode.encode(
            RemoteMemberRequest(roomID: "r", homeInstallID: "home", memberID: "peer-1", handle: "scout"))
        let request = try #require(RoomLinkCode.decode(RemoteMemberRequest.self, from: " \(requestCode)\n"))
        let bot = BotSummary(
            id: "scout", name: "Scout", title: nil, description: nil, model: nil, isActive: false, chat: nil,
            avatarURL: nil, preview: nil, lastActive: nil, isHidden: false, hasAvatar: false, isDefault: false)
        let inviteCode = try #require(await store.invite(request, bot: bot))
        #expect(client.invited?["authority_epoch"] as? Int == 1)
        let invite = try #require(RoomLinkCode.decode(RemoteMemberInvite.self, from: inviteCode))
        let target = invite.rosterRow["target"] as? [String: Any]
        #expect(target?["kind"] as? String == "peer")
        #expect(target?["capability_digest"] as? String == "abc")
        #expect(target?["installation_id"] as? String == "far")

        let local = BotSummary(
            id: "forge", name: "Forge", title: nil, description: nil, model: nil, isActive: false, chat: nil,
            avatarURL: nil, preview: nil, lastActive: nil, isHidden: false, hasAvatar: false, isDefault: false)
        #expect(await store.create(name: "Mixed", bots: [local], remote: [invite], roomID: "r") == "r")
        #expect(client.registered?["target_url"] as? String == "https://far.example/roomlink")
        #expect((client.registered?["catalog"] as? [String: Any])?["catalog_digest"] as? String == "abc")
    }

    @Test func roomListCarriesTheNewestMessageAsAPreview() async {
        let client = RoomClient()
        let store = GroupChatStore(defaults: freshDefaults())
        store.bind(to: client)
        await store.refreshRooms()
        #expect(store.lastMessages["r"]?.text == "You: m1")
        let calls = client.sinceSeqs.count
        await store.refreshRooms()
        #expect(client.sinceSeqs.count == calls, "unchanged rooms are not re-read")
    }

    @Test func staysHiddenWithoutARoomDriver() async {
        let client = RoomClient()
        client.driver = false
        let store = GroupChatStore(defaults: freshDefaults())
        store.bind(to: client)
        await store.refreshRooms()
        #expect(!store.isAvailable)
        client.driver = true
        await store.refreshRooms()
        #expect(store.isAvailable)
        #expect(store.rooms.map(\.id) == ["r"])
    }
}

@MainActor
private final class RoomClient: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    var sendPause: AsyncStream<Void>?
    var sendStarted: AsyncStream<Void>.Continuation?
    var renamePause: AsyncStream<Void>?
    var renameStarted: AsyncStream<Void>.Continuation?
    var sendCount = 0
    var stopCount = 0
    var sessionListCount = 0
    var driver = true
    var latest = 2
    var listedSeq = 2
    var failingMethod: String?
    var retryParams: [String: Any]?
    var listPages: [Int: [String: Any]]?
    var listPause: AsyncStream<Void>?
    var listStarted: AsyncStream<Void>.Continuation?
    var statePause: AsyncStream<Void>?
    var stateStarted: AsyncStream<Void>.Continuation?
    var disbandResult: [String: Any] = [:]
    var logOverrides: [Int: [String: Any]] = [:]
    var logPause: AsyncStream<Void>?
    var logStarted: AsyncStream<Void>.Continuation?
    private(set) var sinceSeqs: [Int] = []
    private(set) var sent: [String: Any]?
    private(set) var uploaded: [String: Any]?
    private(set) var invited: [String: Any]?
    private(set) var registered: [String: Any]?
    private(set) var downloads = 0

    func connect() async throws {}
    func close() {}

    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        if method == failingMethod { throw HermesGateway.GatewayError.httpRefused(500, "refused") }
        switch method {
        case "session.list":
            sessionListCount += 1
            return [:]
        case "groups.capabilities":
            return ["driver": driver, "methods": ["groups.send", "groups.attachment.upload"]]
        case "groups.attachment.download":
            downloads += 1
            guard params["event_id"] as? String == "e-1" else { throw HermesGateway.GatewayError.httpRefused(404, "") }
            // A 1×1 PNG.
            return [
                "data_base64":
                    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII="
            ]
        case "groups.attachment.upload":
            uploaded = params
            return [
                "attachment_id": "att-1", "kind": params["kind"] ?? "", "name": params["name"] ?? "",
                "mime": params["mime"] ?? "", "size": 5,
            ]
        case "groups.list":
            let result: [String: Any]
            if let listPages {
                result = listPages[params["offset"] as? Int ?? 0] ?? [:]
            } else {
                result = ["rooms": [["room_id": "r", "name": "Audit", "members": [], "latest_seq": listedSeq]]]
            }
            listStarted?.yield(())
            if let listPause {
                self.listPause = nil
                for await _ in listPause { break }
            }
            return result
        case "groups.stop":
            stopCount += 1
            return [:]
        case "groups.rename":
            if let renamePause {
                renameStarted?.yield(())
                for await _ in renamePause { break }
            }
            return [:]
        case "groups.retry":
            retryParams = params
            return [:]
        case "groups.disband":
            return disbandResult
        case "groups.send":
            sendCount += 1
            if let sendPause {
                sendStarted?.yield(())
                for await _ in sendPause { break }
            }
            sent = params
            return [:]
        case "groups.peer.invite":
            invited = params
            return [
                "grant": "g", "target_profile": "scout",
                "catalog": ["installation_id": "far", "catalog_digest": "abc"],
                "endpoint": ["available": true, "url": "https://far.example/roomlink"],
            ]
        case "groups.peer.register":
            registered = params
            return [:]
        case "groups.log":
            let since = params["since_seq"] as? Int ?? 0
            sinceSeqs.append(since)
            if since == 1, let logPause {
                self.logPause = nil
                logStarted?.yield(())
                for await _ in logPause { break }
            }
            if let override = logOverrides[since] { return override }
            guard since < latest else {
                return ["events": [], "cursor": latest, "latest_seq": latest, "has_more": false]
            }
            let seq = since + 1
            return [
                "events": [
                    ["seq": seq, "event_id": "e\(seq)", "kind": "message.user", "payload": ["text": "m\(seq)"]]
                ],
                "cursor": seq, "latest_seq": latest, "has_more": seq < latest,
            ]
        case "groups.state":
            if let statePause {
                stateStarted?.yield(())
                for await _ in statePause { break }
            }
            return [
                "driver_status": [
                    "working": true, "blocked": true,
                    "pending_actions": [
                        ["kind": "retry", "task_id": "t9", "member_id": "cypher", "execution_generation": 3],
                        [
                            "kind": "approval", "member_id": "cypher", "task_id": "t", "execution_generation": 1,
                            "request_id": "q", "approval": ["command": "rm -rf build"],
                        ],
                    ],
                ]
            ]
        default:
            return [:]
        }
    }
}

private func freshDefaults() -> UserDefaults {
    UserDefaults(suiteName: "GroupChatTests.\(UUID().uuidString)")!
}
