import Foundation
import Testing

@testable import Herm

@MainActor
struct GroupChatPresenceTests {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func member(_ id: String) -> GroupRoom.Member {
        GroupRoom.Member(memberID: id, profile: id, handle: id, displayName: id.capitalized)
    }

    private func event(_ seq: Int, _ kind: GroupRoomEvent.Kind, id: String? = nil, at offset: TimeInterval = 0)
        -> GroupRoomEvent
    {
        GroupRoomEvent(id: id ?? "e\(seq)", seq: seq, kind: kind, text: "t", createdAt: start + offset)
    }

    @Test func parsesTurnReceiptsRoutingAndOutcomes() {
        let rows: [[String: Any]] = [
            [
                "seq": 3, "kind": "turn.settled", "created_at": 1_700_000_010.0,
                "payload": [
                    "member_id": "a", "passed": true, "seen_through_seq": 2, "discussion_event_id": "d",
                    "round_index": 1, "thread_id": "t-1",
                ],
            ],
            ["seq": 4, "kind": "room.routed", "payload": ["member_ids": ["a"], "everyone": true]],
            ["seq": 5, "kind": "room.assignment", "payload": ["lead_member_id": "l", "member_ids": ["b"]]],
            ["seq": 6, "kind": "room.activity", "payload": ["status": "bounded"]],
            ["seq": 7, "kind": "room.activity", "payload": ["status": "working"]],
            ["seq": 8, "kind": "turn.settled", "payload": [:]],
            ["seq": 9, "kind": "message.user", "payload": ["text": "hi"]],
        ]
        let signals = rows.compactMap(GroupRoomSignal.init)
        #expect(
            signals.map(\.kind) == [
                .settled(memberID: "a", passed: true), .routed(memberIDs: []),
                .assigned(leadID: "l", memberIDs: ["b"]), .ended(bounded: true),
            ])
        #expect(signals[0].seenThroughSeq == 2)
        #expect(signals[0].roundIndex == 1)
        #expect(signals[0].threadID == "t-1")
        #expect(signals[0].createdAt == Date(timeIntervalSince1970: 1_700_000_010))
    }

    @Test func driverInfoReadsCapsRoutesAndRouting() {
        let info = GroupRoomDriverInfo(
            state: [
                "driver_status": [
                    "max_rounds": 3, "max_continues": 2,
                    "peer_routes": [
                        ["room_id": "r", "member_id": "p", "status": "unavailable"],
                        ["room_id": "other", "member_id": "q", "status": "unavailable"],
                        ["room_id": "r", "member_id": "ok", "status": "ready"],
                    ],
                ],
                "context": ["routing": "lead", "lead_member_id": "l"],
            ], roomID: "r")
        #expect(info.maxRounds == 3)
        #expect(info.maxContinues == 2)
        #expect(info.isOffline("p"))
        #expect(!info.isOffline("q"))
        #expect(!info.isOffline("ok"))
        #expect(info.routing == "lead")
        #expect(info.leadMemberID == "l")
    }

    @Test func activityStallsAfterTwoMinutesWithoutProgress() throws {
        let rows = try #require(
            GroupMemberActivity.list(from: [
                "member_activity": [
                    [
                        "member_id": "a", "status": "running", "started_at": 1_700_000_000.0,
                        "progress_at": 1_700_000_100.0, "tool": "terminal", "round_index": 1,
                    ],
                    ["member_id": "b", "status": "queued", "tool": ""],
                ]
            ]))
        #expect(rows[0].tool == "terminal")
        #expect(rows[0].roundIndex == 1)
        #expect(rows[1].tool == nil)
        #expect(!rows[0].isStalled(now: start + 200))
        #expect(rows[0].isStalled(now: start + 220))
        #expect(!rows[1].isStalled(now: start + 10_000))
    }

    @Test func presencePrefersApprovalThenStallThenReplyingThenQueued() throws {
        let members = ["a", "b", "c", "d", "e", "f"].map(member)
        let activity = [
            GroupMemberActivity(memberID: "a", status: "running", threadID: "main"),
            GroupMemberActivity(memberID: "b", status: "running", threadID: "t-1", tool: "web"),
            GroupMemberActivity(memberID: "c", status: "queued", threadID: "main"),
            GroupMemberActivity(memberID: "d", status: "running", threadID: "main"),
        ]
        let approval = try #require(
            GroupRoomApproval([
                "kind": "approval", "member_id": "a", "task_id": "t", "request_id": "q", "execution_generation": 1,
            ]))
        let presence = GroupPresence.members(
            members, activity: activity, approvals: [approval],
            driver: GroupRoomDriverInfo(peerRoutes: ["e": "needs_reauthorization"]), stalled: ["d"])
        #expect(presence["a"]?.presence == .approval)
        #expect(presence["b"]?.presence == .replying(tool: "web"))
        #expect(presence["b"]?.threadID == "t-1")
        #expect(presence["c"]?.presence == .queued)
        #expect(presence["d"]?.presence == .stalled)
        #expect(presence["e"]?.presence == .offline)
        #expect(presence["f"]?.presence == .idle)
        #expect(GroupMemberPresence.replying(tool: "web").mood == .tool)
        #expect(GroupMemberPresence.stalled.mood == .sleepy)
        #expect(GroupMemberPresence.replying(tool: "web").label(threadTitle: "Plan") == "Using web in Plan")
        #expect(GroupMemberPresence.idle.label(threadTitle: nil) == nil)
        #expect(GroupPresence.queued(activity: activity, thread: "main") == ["c"])
        #expect(GroupPresence.threads(activity: activity)["t-1"] == ["b"])
    }

    @Test func roundSummariesTallyRepliesPassesAndPlaceAfterTheLastRow() throws {
        let events = [
            event(1, .user, id: "d"),
            event(2, .started(memberID: "a")),
            event(3, .member(memberID: "a"), at: 5),
            event(5, .started(memberID: "b")),
        ]
        let signals = [
            GroupRoomSignal(seq: 4, kind: .settled(memberID: "a", passed: false), discussionID: "d"),
            GroupRoomSignal(seq: 6, kind: .settled(memberID: "b", passed: true), discussionID: "d"),
            GroupRoomSignal(seq: 7, kind: .ended(bounded: false), discussionID: "d", createdAt: start + 14),
        ]
        let summaries = GroupRoundSummary.summaries(events: events, signals: signals)
        let summary = try #require(summaries.first)
        #expect(summary.replied == ["a"])
        #expect(summary.passed == ["b"])
        #expect(summary.label == "1 replied · 1 passed · 14s")
        #expect(summary.isNotable)
        // The trailing turn.started row is never a footer anchor.
        #expect(GroupRoundSummary.anchors(summaries, events: events).keys.sorted() == ["e3"])
        #expect(GroupRoundSummary.elapsed(80) == "1m 20s")
        #expect(GroupRoundSummary.elapsed(3_900) == "1h 5m")
    }

    @Test func continueOnlyWhileTheCapIsTheLatestUnfencedOutcome() {
        let events = [event(1, .user, id: "d"), event(2, .member(memberID: "a"))]
        let bounded = [
            GroupRoomSignal(seq: 3, kind: .ended(bounded: true), threadID: "main", discussionID: "d")
        ]
        let summary = GroupRoundSummary.summaries(events: events, signals: bounded)[0]
        #expect(summary.canContinue(signals: bounded, events: events, maxContinues: 1))
        #expect(!summary.canContinue(signals: bounded, events: events, maxContinues: nil))
        let stopped = bounded + [GroupRoomSignal(seq: 4, kind: .stopRequested)]
        #expect(!summary.canContinue(signals: stopped, events: events, maxContinues: 1))
        let newer = events + [event(5, .user, id: "n")]
        #expect(!summary.canContinue(signals: bounded, events: newer, maxContinues: 1))
        let used =
            bounded + [
                GroupRoomSignal(seq: 4, kind: .continued, discussionID: "d"),
                GroupRoomSignal(seq: 6, kind: .ended(bounded: true), discussionID: "d"),
            ]
        let spent = GroupRoundSummary.summaries(events: events, signals: used)[0]
        #expect(spent.continues == 1)
        #expect(!spent.canContinue(signals: used, events: events, maxContinues: 1))
    }

    @Test func readReceiptsSitUnderTheLastRowAMemberSawAndSkipLaterAuthors() {
        let events = [
            event(1, .user), event(2, .member(memberID: "a")), event(3, .user), event(5, .member(memberID: "b")),
        ]
        let signals = [
            GroupRoomSignal(seq: 4, kind: .settled(memberID: "c", passed: true), seenThroughSeq: 3),
            GroupRoomSignal(seq: 6, kind: .settled(memberID: "b", passed: false), seenThroughSeq: 3),
            GroupRoomSignal(seq: 7, kind: .settled(memberID: "d", passed: true), seenThroughSeq: 2),
        ]
        let anchors = GroupReadReceipts.anchors(events: events, signals: signals, thread: "main")
        #expect(anchors["e3"] == ["c"])
        #expect(anchors["e2"] == ["d"])
        #expect(
            GroupReadReceipts.anchors(events: events, signals: signals, thread: "main", excluding: ["c"])["e3"] == nil)
    }

    @Test func handoffLineNamesTheLeadsPickAndReactingNamesTheAnswered() {
        let events = [event(1, .user, id: "d"), event(2, .member(memberID: "a"))]
        let names: (String) -> String = { $0.capitalized }
        let solo = [GroupRoomSignal(seq: 3, kind: .assigned(leadID: "l", memberIDs: ["l"]), discussionID: "d")]
        #expect(
            GroupHandoff.line(signals: solo, events: events, thread: "main", names: names)?.text
                == "L is taking this one")
        let handed = [GroupRoomSignal(seq: 3, kind: .assigned(leadID: "l", memberIDs: ["a", "b"]), discussionID: "d")]
        #expect(
            GroupHandoff.line(signals: handed, events: events, thread: "main", names: names)?.text
                == "L gave this to A and B")
        let routed = [GroupRoomSignal(seq: 3, kind: .routed(memberIDs: []), discussionID: "d")]
        #expect(GroupHandoff.line(signals: routed, events: events, thread: "main", names: names) == nil)
        #expect(GroupReacting.target(of: "b", round: 1, events: events) == "a")
        #expect(GroupReacting.target(of: "b", round: 0, events: events) == nil)
        #expect(GroupReacting.target(of: "a", round: 1, events: events) == nil)
    }

    @Test func draftsWakeTheMembersTheyWouldReach() {
        let members = ["ada", "bo", "cy"].map(member)
        #expect(GroupMentionTargets.attentive(draft: "", members: members, driver: nil).isEmpty)
        #expect(GroupMentionTargets.attentive(draft: "hey @bo and @c", members: members, driver: nil) == ["bo"])
        #expect(GroupMentionTargets.attentive(draft: "@all go", members: members, driver: nil).count == 3)
        #expect(GroupMentionTargets.attentive(draft: "mail me@ada.dev", members: members, driver: nil).count == 3)
        let lead = GroupRoomDriverInfo(routing: "lead", leadMemberID: "cy")
        #expect(GroupMentionTargets.attentive(draft: "plan it", members: members, driver: lead) == ["cy"])
    }

    @Test func quietRoomsDozeOnlyWhenIdleAndUntouched() {
        let last = start
        let later = start + GroupRoomQuiet.interval
        #expect(GroupRoomQuiet.isDozing(lastActivity: last, working: false, draft: "", now: later))
        #expect(!GroupRoomQuiet.isDozing(lastActivity: last, working: true, draft: "", now: later))
        #expect(!GroupRoomQuiet.isDozing(lastActivity: last, working: false, draft: "h", now: later))
        #expect(!GroupRoomQuiet.isDozing(lastActivity: last, working: false, draft: "", now: later - 1))
        #expect(!GroupRoomQuiet.isDozing(lastActivity: nil, working: false, draft: "", now: later))
    }

    @Test func stageTitleNamesWritersQuietMembersOrWhoIsNext() {
        #expect(GroupReplying.stageTitle(replying: ["Ada"], stalled: [], queued: ["Bo"]) == "Ada is replying")
        #expect(GroupReplying.stageTitle(replying: ["Ada"], stalled: ["Ada"], queued: []) == "Ada has gone quiet")
        #expect(GroupReplying.stageTitle(replying: [], stalled: [], queued: ["Bo", "Cy"]) == "Bo and Cy are up next")
        #expect(GroupReplying.stageTitle(replying: [], stalled: [], queued: []) == "")
    }

    @Test func chatterRibbonWordsAreSeededAndFit() {
        let first = GroupChatterRibbon.layout(seed: 7, width: 66)
        #expect(first.map(\.width) == GroupChatterRibbon.layout(seed: 7, width: 66).map(\.width))
        #expect(!first.isEmpty)
        #expect(first.allSatisfy { $0.x + $0.width <= 66 })
    }
}
