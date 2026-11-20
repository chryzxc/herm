import Foundation

/// Room-log bookkeeping Herm reads but never renders as a row: turn receipts,
/// routing answers and discussion outcomes. Parsed from the same `groups.log`
/// pages as `GroupRoomEvent`; Hermes owns every one of them.
struct GroupRoomSignal: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// A member's turn finished; `passed` means it chose not to reply.
        case settled(memberID: String, passed: Bool)
        case failed(memberID: String)
        case cancelled(memberID: String)
        /// The router picked who answers; empty means everyone.
        case routed(memberIDs: [String])
        /// The lead handed the message to these members.
        case assigned(leadID: String, memberIDs: [String])
        /// The discussion finished (`room.activity` settled) or paused at its cap (`bounded`).
        case ended(bounded: Bool)
        case continued
        case stopRequested
    }

    let seq: Int
    let kind: Kind
    let threadID: String?
    let discussionID: String?
    let roundIndex: Int?
    /// The last room seq the member's turn had seen (terminal receipts only).
    let seenThroughSeq: Int?
    let createdAt: Date

    init(
        seq: Int, kind: Kind, threadID: String? = nil, discussionID: String? = nil, roundIndex: Int? = nil,
        seenThroughSeq: Int? = nil, createdAt: Date = .now
    ) {
        self.seq = seq
        self.kind = kind
        self.threadID = threadID
        self.discussionID = discussionID
        self.roundIndex = roundIndex
        self.seenThroughSeq = seenThroughSeq
        self.createdAt = createdAt
    }

    init?(_ raw: [String: Any]) {
        guard let seq = raw["seq"] as? Int, let kindName = raw["kind"] as? String else { return nil }
        let payload = raw["payload"] as? [String: Any] ?? [:]
        let memberID = payload["member_id"] as? String
        let members = (payload["member_ids"] as? [String]) ?? []
        switch kindName {
        case "turn.settled":
            guard let memberID else { return nil }
            kind = .settled(memberID: memberID, passed: payload["passed"] as? Bool == true)
        case "turn.failed":
            guard let memberID else { return nil }
            kind = .failed(memberID: memberID)
        case "turn.cancelled":
            guard let memberID else { return nil }
            kind = .cancelled(memberID: memberID)
        case "room.routed":
            kind = .routed(memberIDs: payload["everyone"] as? Bool == true ? [] : members)
        case "room.assignment":
            guard let lead = payload["lead_member_id"] as? String else { return nil }
            kind = .assigned(leadID: lead, memberIDs: members)
        case "room.activity":
            guard let status = payload["status"] as? String, status == "settled" || status == "bounded" else {
                return nil
            }
            kind = .ended(bounded: status == "bounded")
        case "room.continued":
            kind = .continued
        case "room.stop_requested":
            kind = .stopRequested
        default:
            return nil
        }
        self.seq = seq
        threadID = payload["thread_id"] as? String
        discussionID = payload["discussion_event_id"] as? String
        roundIndex = payload["round_index"] as? Int
        seenThroughSeq = payload["seen_through_seq"] as? Int
        createdAt = (raw["created_at"] as? Double).map(Date.init(timeIntervalSince1970:)) ?? .now
    }
}

/// The `groups.state` facts Herm projects beyond working/blocked: round caps,
/// RoomLink route health and how unaddressed messages are routed.
struct GroupRoomDriverInfo: Equatable, Sendable {
    var maxRounds: Int?
    var maxContinues: Int?
    /// member → `ready`, `needs_reauthorization` or `unavailable`.
    var peerRoutes: [String: String] = [:]
    /// `everyone`, `lead` or `auto`.
    var routing = "everyone"
    var leadMemberID: String?

    init(
        maxRounds: Int? = nil, maxContinues: Int? = nil, peerRoutes: [String: String] = [:],
        routing: String = "everyone", leadMemberID: String? = nil
    ) {
        self.maxRounds = maxRounds
        self.maxContinues = maxContinues
        self.peerRoutes = peerRoutes
        self.routing = routing
        self.leadMemberID = leadMemberID
    }

    init(state: [String: Any], roomID: String) {
        let status = state["driver_status"] as? [String: Any] ?? [:]
        maxRounds = status["max_rounds"] as? Int
        maxContinues = status["max_continues"] as? Int
        for row in status["peer_routes"] as? [[String: Any]] ?? [] {
            guard (row["room_id"] as? String).map({ $0 == roomID }) ?? true,
                let member = row["member_id"] as? String, let value = row["status"] as? String
            else { continue }
            peerRoutes[member] = value
        }
        let context = state["context"] as? [String: Any] ?? [:]
        routing = context["routing"] as? String ?? "everyone"
        leadMemberID = (context["lead_member_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// A RoomLink member whose route can't carry a turn right now.
    func isOffline(_ memberID: String) -> Bool {
        guard let status = peerRoutes[memberID] else { return false }
        return status != "ready"
    }
}

/// What one member is doing, as a face can show it. Ordered by precedence.
enum GroupMemberPresence: Equatable, Sendable {
    case approval
    case stalled
    case replying(tool: String?)
    case queued
    case offline
    case idle

    var mood: BotMood {
        switch self {
        case .approval: .approval
        case .stalled: .sleepy
        case .replying(let tool): tool == nil ? .thinking : .tool
        case .queued: .queued
        case .offline: .offline
        case .idle: .idle
        }
    }

    var isActive: Bool {
        switch self {
        case .approval, .stalled, .replying, .queued: true
        case .offline, .idle: false
        }
    }

    /// Short live state for the mention list and hover card; nil when idle.
    func label(threadTitle: String?) -> String? {
        let place = threadTitle.map { " in \($0)" } ?? ""
        switch self {
        case .approval: return "Waiting for your approval"
        case .stalled: return "Gone quiet\(place)"
        case .replying(let tool): return tool.map { "Using \($0)\(place)" } ?? "Replying\(place)"
        case .queued: return "Up next\(place)"
        case .offline: return "Offline"
        case .idle: return nil
        }
    }
}

@MainActor
enum GroupPresence {
    /// Each member's presence across the whole room (any thread), with the thread it is in.
    static func members(
        _ members: [GroupRoom.Member], activity: [GroupMemberActivity]?, approvals: [GroupRoomApproval],
        driver: GroupRoomDriverInfo?, stalled: Set<String>
    ) -> [String: (presence: GroupMemberPresence, threadID: String?)] {
        var result: [String: (presence: GroupMemberPresence, threadID: String?)] = [:]
        let waiting = Set(approvals.map(\.memberID))
        for member in members {
            let rows = (activity ?? []).filter { $0.memberID == member.memberID }
            let live = rows.first(where: \.isReplying) ?? rows.first(where: \.isQueued)
            let presence: GroupMemberPresence =
                if waiting.contains(member.memberID) {
                    .approval
                } else if let live, live.isReplying {
                    stalled.contains(member.memberID) ? .stalled : .replying(tool: live.tool)
                } else if live != nil {
                    .queued
                } else if driver?.isOffline(member.memberID) == true {
                    .offline
                } else {
                    .idle
                }
            result[member.memberID] = (presence, live?.threadID)
        }
        return result
    }

    /// Queued members of one thread, in admission order: who goes next.
    static func queued(activity: [GroupMemberActivity]?, thread: String) -> [String] {
        var ids: [String] = []
        for item in activity ?? [] where item.isQueued && !ids.contains(item.memberID) {
            if (item.threadID ?? GroupChatStore.mainThreadID) == thread { ids.append(item.memberID) }
        }
        return ids
    }

    /// Threads with a member replying or queued, and who.
    static func threads(activity: [GroupMemberActivity]?) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for item in activity ?? [] where item.isReplying || item.isQueued {
            let thread = item.threadID ?? GroupChatStore.mainThreadID
            if result[thread]?.contains(item.memberID) != true { result[thread, default: []].append(item.memberID) }
        }
        return result
    }
}

/// How one finished user message went: who replied, who passed, and whether
/// it paused at its round cap.
struct GroupRoundSummary: Equatable, Sendable {
    let discussionID: String
    let threadID: String
    let replied: [String]
    let passed: [String]
    let failed: [String]
    let duration: TimeInterval?
    let bounded: Bool
    let endSeq: Int
    let continues: Int

    /// "3 replied · 1 passed · 14s".
    var label: String {
        var parts: [String] = []
        if !replied.isEmpty { parts.append("\(replied.count) replied") }
        if !passed.isEmpty { parts.append("\(passed.count) passed") }
        if !failed.isEmpty { parts.append("\(failed.count) failed") }
        if let duration { parts.append(GroupRoundSummary.elapsed(duration)) }
        return parts.joined(separator: " · ")
    }

    /// `45s`, `1m 20s`, `1h 5m`.
    static func elapsed(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return s % 60 == 0 ? "\(s / 60)m" : "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \((s % 3600) / 60)m"
    }

    /// Worth a footer: a pass, a cap, or more than one member taking part.
    var isNotable: Bool { bounded || !passed.isEmpty || replied.count + failed.count + passed.count > 1 }

    /// Each discussion's latest outcome, oldest first.
    @MainActor static func summaries(events: [GroupRoomEvent], signals: [GroupRoomSignal]) -> [GroupRoundSummary] {
        var order: [String] = []
        var ends: [String: GroupRoomSignal] = [:]
        var continues: [String: Int] = [:]
        for signal in signals {
            guard let discussion = signal.discussionID else { continue }
            switch signal.kind {
            case .ended:
                if ends[discussion] == nil { order.append(discussion) }
                ends[discussion] = signal
            case .continued:
                continues[discussion, default: 0] += 1
            default: break
            }
        }
        let starts = Dictionary(
            events.filter { $0.kind == .user }.map { ($0.id, $0.createdAt) }, uniquingKeysWith: { first, _ in first })
        return order.compactMap { discussion in
            guard let end = ends[discussion] else { return nil }
            var replied: [String] = []
            var passed: [String] = []
            var failed: [String] = []
            for signal in signals where signal.discussionID == discussion && signal.seq < end.seq {
                switch signal.kind {
                case .settled(let id, let didPass):
                    if didPass {
                        if !passed.contains(id), !replied.contains(id) { passed.append(id) }
                    } else if !replied.contains(id) {
                        replied.append(id)
                        passed.removeAll { $0 == id }
                    }
                case .failed(let id):
                    if !failed.contains(id) { failed.append(id) }
                default: break
                }
            }
            failed.removeAll { replied.contains($0) }
            guard case .ended(let bounded) = end.kind else { return nil }
            return GroupRoundSummary(
                discussionID: discussion, threadID: end.threadID ?? GroupChatStore.mainThreadID,
                replied: replied, passed: passed, failed: failed,
                duration: starts[discussion].map { end.createdAt.timeIntervalSince($0) },
                bounded: bounded, endSeq: end.seq, continues: continues[discussion] ?? 0)
        }
    }

    /// The visible row each footer follows: the last one before its outcome.
    static func anchors(_ summaries: [GroupRoundSummary], events: [GroupRoomEvent]) -> [String: [GroupRoundSummary]] {
        var result: [String: [GroupRoundSummary]] = [:]
        for summary in summaries {
            guard
                let anchor = events.last(where: { event in
                    if case .started = event.kind { return false }
                    return event.seq < summary.endSeq
                })
            else { continue }
            result[anchor.id, default: []].append(summary)
        }
        return result
    }

    /// Hermes' `paused_discussion`: the latest outcome is the cap, and no Stop or
    /// newer message in its thread fenced it since its own message.
    @MainActor func canContinue(signals: [GroupRoomSignal], events: [GroupRoomEvent], maxContinues: Int?) -> Bool {
        guard bounded, let maxContinues, continues < maxContinues else { return false }
        let source = events.first { $0.id == discussionID }?.seq ?? endSeq
        if signals.contains(where: { $0.seq > source && $0.kind == .stopRequested }) { return false }
        return !events.contains {
            $0.seq > source && $0.kind == .user && ($0.threadID ?? GroupChatStore.mainThreadID) == threadID
        }
    }
}

@MainActor
enum GroupReadReceipts {
    /// Each member's newest receipt in the thread, placed under the last visible
    /// row it had seen. Members replying right now are left out; their face is live.
    static func anchors(
        events: [GroupRoomEvent], signals: [GroupRoomSignal], thread: String, excluding: Set<String> = []
    ) -> [String: [String]] {
        var seen: [String: Int] = [:]
        var order: [String] = []
        for signal in signals where (signal.threadID ?? GroupChatStore.mainThreadID) == thread {
            guard let through = signal.seenThroughSeq else { continue }
            let member: String
            switch signal.kind {
            case .settled(let id, _), .failed(let id), .cancelled(let id): member = id
            default: continue
            }
            if seen[member] == nil { order.append(member) }
            seen[member] = max(seen[member] ?? 0, through)
        }
        var result: [String: [String]] = [:]
        for member in order where !excluding.contains(member) {
            guard let through = seen[member],
                let anchor = events.last(where: { event in
                    guard event.seq <= through else { return false }
                    switch event.kind {
                    case .user: return true
                    case .member(let id): return id != member
                    default: return false
                    }
                })
            else { continue }
            // A member that answered after the row already shows by its own reply.
            if events.contains(where: { $0.seq > anchor.seq && $0.kind == .member(memberID: member) }) { continue }
            result[anchor.id, default: []].append(member)
        }
        return result
    }
}

extension GroupReplying {
    /// The reply stage's line: who is writing, who went quiet, or who goes next.
    static func stageTitle(replying: [String], stalled: [String], queued: [String]) -> String {
        func names(_ list: [String]) -> String {
            list.count <= 3
                ? ListFormatter.localizedString(byJoining: list)
                : "\(list.prefix(2).joined(separator: ", ")) and \(list.count - 2) others"
        }
        if !replying.isEmpty, stalled.count == replying.count {
            return "\(names(stalled)) \(stalled.count == 1 ? "has" : "have") gone quiet"
        }
        if !replying.isEmpty { return label(replying) }
        guard !queued.isEmpty else { return "" }
        return "\(names(queued)) \(queued.count == 1 ? "is" : "are") up next"
    }
}

@MainActor
enum GroupHandoff {
    /// "Aegis is taking this one" / "Ada gave this to Linus" for the thread's open
    /// discussion, while its routed members are still to answer.
    static func line(
        signals: [GroupRoomSignal], events: [GroupRoomEvent], thread: String, names: (String) -> String
    ) -> (leadID: String?, memberIDs: [String], text: String)? {
        guard let message = events.last(where: { $0.kind == .user }) else { return nil }
        let latest = signals.last {
            $0.discussionID == message.id && ($0.threadID ?? GroupChatStore.mainThreadID) == thread
                && {
                    switch $0.kind {
                    case .routed, .assigned: return true
                    default: return false
                    }
                }($0)
        }
        switch latest?.kind {
        case .assigned(let lead, let members):
            guard !members.isEmpty else { return nil }
            if members == [lead] { return (lead, members, "\(names(lead)) is taking this one") }
            let others = members.map(names)
            return (lead, members, "\(names(lead)) gave this to \(ListFormatter.localizedString(byJoining: others))")
        case .routed(let members):
            guard !members.isEmpty else { return nil }
            let picked = members.map(names)
            let verb = members.count == 1 ? "is" : "are"
            return (nil, members, "\(ListFormatter.localizedString(byJoining: picked)) \(verb) taking this one")
        default:
            return nil
        }
    }
}

@MainActor
enum GroupReacting {
    /// The author a reacting turn answers: the latest other member's reply in the
    /// thread, when the member works in a later round of the discussion.
    static func target(of memberID: String, round: Int?, events: [GroupRoomEvent]) -> String? {
        guard let round, round > 0 else { return nil }
        for event in events.reversed() {
            if event.kind == .user { return nil }
            if case .member(let id) = event.kind, id != memberID { return id }
        }
        return nil
    }
}

@MainActor
enum GroupMentionTargets {
    /// Members a draft would reach: its @handles, everyone for `@all`, and for an
    /// unaddressed draft whoever the room's routing would wake (the lead in a lead
    /// room). Empty for an empty draft.
    static func attentive(draft: String, members: [GroupRoom.Member], driver: GroupRoomDriverInfo?) -> Set<String> {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        let handles = mentions(in: text)
        if handles.contains("all") { return Set(members.map(\.memberID)) }
        let named = members.filter { handles.contains($0.handle.lowercased()) }
        if !named.isEmpty { return Set(named.map(\.memberID)) }
        if driver?.routing == "lead", let lead = driver?.leadMemberID { return [lead] }
        return Set(members.map(\.memberID))
    }

    /// Lowercased handles after `@`, including a partial one being typed.
    static func mentions(in text: String) -> Set<String> {
        var found: Set<String> = []
        var current: String?
        var previous: Character?
        for character in text + " " {
            if var token = current {
                if character.isLetter || character.isNumber || character == "_" || character == "-" {
                    token.append(character)
                    current = token
                } else {
                    if !token.isEmpty { found.insert(token.lowercased()) }
                    current = nil
                }
            } else if character == "@", previous.map({ !($0.isLetter || $0.isNumber) }) ?? true {
                current = ""
            }
            previous = character
        }
        return found
    }
}

@MainActor
enum GroupRoomQuiet {
    /// After this long without a message or a turn, the room's faces doze.
    static let interval: TimeInterval = 15 * 60

    static func isDozing(lastActivity: Date?, working: Bool, draft: String, now: Date) -> Bool {
        guard !working, draft.isEmpty, let lastActivity else { return false }
        return now.timeIntervalSince(lastActivity) >= interval
    }
}
