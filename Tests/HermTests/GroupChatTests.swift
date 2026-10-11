import Foundation
import Testing
@testable import Herm

@MainActor
struct GroupChatTests {
    @Test func mapsRoomLogEventsAndSkipsBookkeeping() {
        let rows: [[String: Any]] = [
            ["seq": 1, "event_id": "a", "kind": "room.created", "payload": [:]],
            ["seq": 2, "event_id": "b", "kind": "message.user", "payload": ["text": "@cypher hey", "thread_id": "main"]],
            ["seq": 3, "event_id": "c", "kind": "turn.started", "payload": ["member_id": "cypher"]],
            ["seq": 4, "event_id": "d", "kind": "message.member", "payload": ["member_id": "cypher", "text": "hi"]],
            ["seq": 5, "event_id": "e", "kind": "turn.failed", "payload": ["member_id": "forge", "error": "boom"]],
            ["seq": 6, "event_id": "f", "kind": "turn.settled", "payload": ["member_id": "cypher"]]
        ]
        let events = rows.compactMap(GroupRoomEvent.init)
        #expect(events.map(\.kind) == [.user, .started(memberID: "cypher"), .member(memberID: "cypher"), .failed(memberID: "forge")])
        #expect(events[0].text == "@cypher hey")
        #expect(events[3].text == "boom")
    }

    @Test func dropsDisbandedRoomsAndDefaultsMemberLabels() {
        #expect(GroupRoom(["room_id": "r", "name": "x", "members": [], "disbanded_at": 1.0]) == nil)
        let room = GroupRoom(["room_id": "r", "name": "Audit", "members": [["member_id": "default", "profile": "default", "handle": "hermes"]]])
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
        #expect(store.retries["r"] == ["t9"])
        #expect(store.blockedRooms.contains("r"))
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
            ["role": "assistant", "content": "", "tool_calls": [["id": "c1", "function": ["name": "terminal", "arguments": "{\"command\":\"ls\"}"]]]],
            ["role": "tool", "content": "a.txt"],
            ["role": "assistant", "content": "Found a.txt"],
            ["role": "user", "content": "[Discussion] ..."]
        ]
        let turns = GroupMemberTurn.turns(from: rows)
        #expect(turns.count == 2)
        #expect(turns[0].tools.map(\.name) == ["terminal"])
        #expect(turns[0].matches("Found a.txt\n"))
        #expect(turns[1].reply == nil)
    }

    @Test func eventsCarryTheirThreadAndSendTargetsIt() async {
        let event = GroupRoomEvent(["seq": 1, "event_id": "a", "kind": "message.user", "payload": ["text": "hi", "thread_id": "t-1"]])
        #expect(event?.threadID == "t-1")
        let client = RoomClient()
        let store = GroupChatStore(defaults: freshDefaults())
        store.bind(to: client)
        await store.send("hello", to: "r", thread: "t-1")
        #expect((client.sent?["payload"] as? [String: Any])?["thread_id"] as? String == "t-1")
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

    @Test func roomLinkInviteRoundTripsIntoAPeerSeatAndRegisters() async throws {
        let client = RoomClient()
        let store = GroupChatStore(defaults: freshDefaults())
        store.bind(to: client)
        let requestCode = RoomLinkCode.encode(RemoteMemberRequest(roomID: "r", homeInstallID: "home", memberID: "peer-1", handle: "scout"))
        let request = try #require(RoomLinkCode.decode(RemoteMemberRequest.self, from: " \(requestCode)\n"))
        let bot = BotSummary(id: "scout", name: "Scout", title: nil, description: nil, model: nil, isActive: false, chat: nil,
                             avatarURL: nil, preview: nil, lastActive: nil, isHidden: false, hasAvatar: false, isDefault: false)
        let inviteCode = try #require(await store.invite(request, bot: bot))
        #expect(client.invited?["authority_epoch"] as? Int == 1)
        let invite = try #require(RoomLinkCode.decode(RemoteMemberInvite.self, from: inviteCode))
        let target = invite.rosterRow["target"] as? [String: Any]
        #expect(target?["kind"] as? String == "peer")
        #expect(target?["capability_digest"] as? String == "abc")
        #expect(target?["installation_id"] as? String == "far")

        let local = BotSummary(id: "forge", name: "Forge", title: nil, description: nil, model: nil, isActive: false, chat: nil,
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
    var driver = true
    var latest = 2
    var listedSeq = 2
    private(set) var sinceSeqs: [Int] = []
    private(set) var sent: [String: Any]?
    private(set) var invited: [String: Any]?
    private(set) var registered: [String: Any]?

    func connect() async throws {}
    func close() {}

    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        switch method {
        case "groups.capabilities":
            return ["driver": driver]
        case "groups.list":
            return ["rooms": [["room_id": "r", "name": "Audit", "members": [], "latest_seq": listedSeq]]]
        case "groups.send":
            sent = params
            return [:]
        case "groups.peer.invite":
            invited = params
            return ["grant": "g", "target_profile": "scout",
                    "catalog": ["installation_id": "far", "catalog_digest": "abc"],
                    "endpoint": ["available": true, "url": "https://far.example/roomlink"]]
        case "groups.peer.register":
            registered = params
            return [:]
        case "groups.log":
            let since = params["since_seq"] as? Int ?? 0
            sinceSeqs.append(since)
            guard since < latest else { return ["events": [], "cursor": latest, "latest_seq": latest, "has_more": false] }
            let seq = since + 1
            return [
                "events": [["seq": seq, "event_id": "e\(seq)", "kind": "message.user", "payload": ["text": "m\(seq)"]]],
                "cursor": seq, "latest_seq": latest, "has_more": seq < latest
            ]
        case "groups.state":
            return ["driver_status": ["working": true, "blocked": true, "pending_actions": [["kind": "retry", "task_id": "t9"], [
                "kind": "approval", "member_id": "cypher", "task_id": "t", "execution_generation": 1,
                "request_id": "q", "approval": ["command": "rm -rf build"]
            ]]]]
        default:
            return [:]
        }
    }
}

private func freshDefaults() -> UserDefaults {
    UserDefaults(suiteName: "GroupChatTests.\(UUID().uuidString)")!
}
