import Foundation

/// One hosted Group Chat room (`groups.*`). Hermes owns the room log, mention
/// routing, rounds, and member turns; Herm only creates rooms, appends user
/// messages, and replays the log.
struct GroupRoom: Identifiable, Equatable, Sendable {
    struct Member: Equatable, Sendable {
        let memberID: String
        let profile: String
        let handle: String
        let displayName: String
        /// A RoomLink member running on another machine's gateway.
        var isRemote = false
    }

    let id: String
    let name: String
    let members: [Member]
    let updatedAt: Date
    var latestSeq = 0

    init(id: String, name: String, members: [Member], updatedAt: Date) {
        self.id = id
        self.name = name
        self.members = members
        self.updatedAt = updatedAt
    }

    init?(_ raw: [String: Any]) {
        guard let id = raw["room_id"] as? String, !id.isEmpty, raw["disbanded_at"] as? Double == nil else { return nil }
        self.id = id
        name = (raw["name"] as? String) ?? id
        members = (raw["members"] as? [[String: Any]] ?? []).compactMap { row in
            guard let profile = row["profile"] as? String else { return nil }
            let handle = (row["handle"] as? String) ?? profile
            let display = (row["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? handle
            let isRemote = (row["target"] as? [String: Any])?["kind"] as? String == "peer"
            return Member(
                memberID: (row["member_id"] as? String) ?? profile, profile: profile, handle: handle,
                displayName: display, isRemote: isRemote)
        }
        updatedAt = Date(timeIntervalSince1970: (raw["updated_at"] as? Double) ?? 0)
        latestSeq = raw["latest_seq"] as? Int ?? 0
    }

    func member(_ id: String?) -> Member? { members.first { $0.memberID == id } }
}

/// The room-log rows Herm renders. Other event kinds (settle receipts,
/// authority bookkeeping) only advance the cursor.
struct GroupRoomEvent: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case user
        case member(memberID: String)
        case started(memberID: String)
        case failed(memberID: String?)
        case notice
    }

    let id: String
    let seq: Int
    let kind: Kind
    let text: String
    let createdAt: Date
    /// nil for room-wide events (rename, stop), which show in every thread.
    let threadID: String?

    init(id: String, seq: Int, kind: Kind, text: String, createdAt: Date = .now, threadID: String? = nil) {
        self.id = id
        self.seq = seq
        self.kind = kind
        self.text = text
        self.createdAt = createdAt
        self.threadID = threadID
    }

    init?(_ raw: [String: Any]) {
        guard let seq = raw["seq"] as? Int, let kindName = raw["kind"] as? String else { return nil }
        let payload = raw["payload"] as? [String: Any] ?? [:]
        let memberID = payload["member_id"] as? String
        id = (raw["event_id"] as? String) ?? "\(seq)"
        self.seq = seq
        createdAt = (raw["created_at"] as? Double).map(Date.init(timeIntervalSince1970:)) ?? .now
        threadID = payload["thread_id"] as? String
        switch kindName {
        case "message.user":
            kind = .user
            text = payload["text"] as? String ?? ""
        case "message.member":
            guard let memberID else { return nil }
            kind = .member(memberID: memberID)
            text = payload["text"] as? String ?? ""
        case "turn.started":
            guard let memberID else { return nil }
            kind = .started(memberID: memberID)
            text = ""
        case "turn.failed", "member.unavailable":
            kind = .failed(memberID: memberID)
            text = (payload["error"] as? String) ?? (payload["reason"] as? String) ?? "Member is unavailable."
        case "room.renamed":
            kind = .notice
            text = "Renamed to \(payload["name"] as? String ?? "a new name")"
        case "room.stop_requested":
            kind = .notice
            text = "Stopped"
        default:
            return nil
        }
    }
}

/// A command approval a room member is waiting on (`groups.state`
/// `driver_status.pending_actions`, kind `approval`).
struct GroupRoomApproval: Equatable, Sendable {
    let memberID: String
    let taskID: String
    let executionGeneration: Int
    let requestID: String
    let summary: String

    init?(_ raw: [String: Any]) {
        guard raw["kind"] as? String == "approval",
            let memberID = raw["member_id"] as? String,
            let taskID = raw["task_id"] as? String,
            let requestID = raw["request_id"] as? String
        else { return nil }
        self.memberID = memberID
        self.taskID = taskID
        executionGeneration = raw["execution_generation"] as? Int ?? 0
        self.requestID = requestID
        let approval = raw["approval"] as? [String: Any] ?? [:]
        summary =
            (approval["command"] as? String) ?? (approval["description"] as? String) ?? "A command needs approval."
    }
}

/// One member turn as recorded in the member's hidden room session
/// (`Group: <room_id>`, source `bot_room`): the tools it ran and its reply.
/// Hermes doesn't put tool activity in the room log, so this is the only
/// place a client can read it.
struct GroupMemberTurn: Equatable {
    var reply: String?
    var tools: [ActiveToolCall] = []

    /// Each user row is the driver's prompt for a new turn.
    @MainActor static func turns(from rows: [[String: Any]]) -> [GroupMemberTurn] {
        var turns: [GroupMemberTurn] = []
        for row in rows {
            switch row["role"] as? String {
            case "user":
                turns.append(GroupMemberTurn())
            case "assistant" where !turns.isEmpty:
                let tools = DockModel.historyToolCalls(in: row, timestamp: Date())
                turns[turns.count - 1].tools += tools
                if tools.isEmpty, let text = row["content"] as? String,
                    !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                {
                    turns[turns.count - 1].reply = text
                }
            default:
                break
            }
        }
        return turns
    }

    /// The room may carry a trimmed copy of the reply, so match on the opening.
    func matches(_ roomText: String) -> Bool {
        guard let reply else { return false }
        let key = { (s: String) in String(s.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)) }
        return key(reply) == key(roomText)
    }
}

/// RoomLink setup codes, passed between two machines by copy/paste. The home
/// picks the room and member ids first because Hermes scopes the target's
/// grant to them; the target answers with the grant and its catalog.
struct RemoteMemberRequest: Codable, Equatable {
    let roomID: String
    let homeInstallID: String
    let memberID: String
    let handle: String
}

struct RemoteMemberInvite: Codable, Equatable {
    let memberID: String
    let handle: String
    let targetProfile: String
    let displayName: String
    let grant: String
    let endpointURL: String
    /// The target's `catalog` verbatim; `groups.peer.register` compares it exactly.
    let catalogJSON: String

    var catalog: [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(catalogJSON.utf8))) as? [String: Any] ?? [:]
    }

    /// The roster row Hermes expects for a peer member.
    var rosterRow: [String: Any] {
        [
            "member_id": memberID, "profile": targetProfile, "handle": handle, "display_name": displayName,
            "target": [
                "kind": "peer", "peer_id": memberID, "profile": targetProfile,
                "installation_id": catalog["installation_id"] as? String ?? "",
                "capability_digest": catalog["catalog_digest"] as? String ?? "",
            ],
        ]
    }
}

enum RoomLinkCode {
    private static let prefix = "herm-roomlink:"

    static func encode<T: Encodable>(_ value: T) -> String {
        prefix + ((try? JSONEncoder().encode(value))?.base64EncodedString() ?? "")
    }

    static func decode<T: Decodable>(_ type: T.Type, from code: String) -> T? {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(prefix), let data = Data(base64Encoded: String(trimmed.dropFirst(prefix.count))) else {
            return nil
        }
        return try? JSONDecoder().decode(type, from: data)
    }
}

struct GroupLastMessage: Equatable {
    let text: String
    let date: Date
}

@MainActor
final class GroupChatStore: ObservableObject {
    /// Hermes' roster rule: 2–6 local profiles per room.
    static let memberLimits = 2...6
    /// v1 uses one thread per room; Hermes requires an explicit thread id.
    static let mainThreadID = "main"

    @Published private(set) var isAvailable = false
    @Published private(set) var rooms: [GroupRoom] = []
    @Published private(set) var events: [String: [GroupRoomEvent]] = [:]
    @Published private(set) var pendingRooms: Set<String> = []
    @Published private(set) var workingRooms: Set<String> = []
    @Published private(set) var approvals: [String: [GroupRoomApproval]] = [:]
    @Published private(set) var retries: [String: [String]] = [:]
    @Published private(set) var blockedRooms: Set<String> = []
    /// room → member → turns read from the member's hidden session.
    @Published private(set) var memberTurns: [String: [String: [GroupMemberTurn]]] = [:]
    /// First seq loaded per room; above zero means older history is unloaded.
    @Published private(set) var earliestLoadedSeq: [String: Int] = [:]
    /// Last log seq the user has seen per room; persisted for unread dots.
    @Published private(set) var seenSeq: [String: Int]
    /// Newest message per room for the sidebar row, and the seq it was read at.
    @Published private(set) var lastMessages: [String: GroupLastMessage] = [:]
    private var previewSeq: [String: Int] = [:]
    /// This gateway's install identity and whether RoomLink peers are usable.
    @Published private(set) var installID: String?
    @Published private(set) var isRoomLinkEnabled = false
    @Published var errorMessage: String?
    private let defaults: UserDefaults
    private static let seenKey = "groupChat.seenSeq"
    /// Opening a room loads this many log rows; older ones load on demand.
    static let historyWindow = 400
    private var cursors: [String: Int] = [:]
    private var memberSessionIDs: [String: String] = [:]
    private var client: HermesRPCClientProtocol?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        seenSeq = defaults.dictionary(forKey: Self.seenKey) as? [String: Int] ?? [:]
    }

    func isUnread(_ room: GroupRoom) -> Bool { room.latestSeq > (seenSeq[room.id] ?? room.latestSeq) }

    func markSeen(_ roomID: String, through seq: Int) {
        guard seq > (seenSeq[roomID] ?? -1) else { return }
        seenSeq[roomID] = seq
        defaults.set(seenSeq, forKey: Self.seenKey)
    }

    func bind(to client: HermesRPCClientProtocol) {
        self.client = client
        Task { await refreshRooms() }
    }

    /// `groups.capabilities` is the feature gate: a gateway without a room
    /// driver cannot run member turns, so the surface stays hidden.
    func refreshRooms() async {
        guard let client else { return }
        if !isAvailable {
            guard let caps = try? await client.request(HermesFeatureIDs.ID.groupsCapabilities.rawValue, params: [:]),
                caps["driver"] as? Bool == true
            else { return }
            isAvailable = true
            installID = caps["authority_gateway_id"] as? String
            isRoomLinkEnabled = (caps["room_link"] as? [String: Any])?["enabled"] as? Bool == true
        }
        guard let result = try? await client.request(HermesFeatureIDs.ID.groupsList.rawValue, params: [:]) else {
            return
        }
        let listed = (result["rooms"] as? [[String: Any]] ?? []).compactMap(GroupRoom.init)
        // A room first seen here starts read; only later activity marks it unread.
        for room in listed where seenSeq[room.id] == nil { markSeen(room.id, through: room.latestSeq) }
        if listed != rooms { rooms = listed }
        for room in listed where room.latestSeq != previewSeq[room.id] {
            previewSeq[room.id] = room.latestSeq
            // The last message sits within the trailing bookkeeping events of its turn.
            guard
                let page = try? await client.request(
                    HermesFeatureIDs.ID.groupsLog.rawValue,
                    params: [
                        "room_id": room.id, "since_seq": max(0, room.latestSeq - 12), "limit": 12,
                    ])
            else { continue }
            updateLastMessage(room.id, from: (page["events"] as? [[String: Any]] ?? []).compactMap(GroupRoomEvent.init))
        }
    }

    /// Sidebar preview: "You: …" or "Forge: …" from the newest message event.
    private func updateLastMessage(_ roomID: String, from events: [GroupRoomEvent]) {
        guard
            let event = events.last(where: {
                switch $0.kind {
                case .user, .member: true
                default: false
                }
            })
        else { return }
        var author = "You"
        if case .member(let id) = event.kind {
            author = rooms.first { $0.id == roomID }?.member(id)?.displayName ?? id
        }
        let line = event.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        lastMessages[roomID] = GroupLastMessage(text: "\(author): \(line)", date: event.createdAt)
    }

    static func members(for bots: [BotSummary]) -> [[String: Any]] {
        bots.map { bot in
            // Hermes addresses the primary profile as @hermes.
            [
                "member_id": bot.id, "profile": bot.id, "handle": bot.id == "default" ? "hermes" : bot.id,
                "display_name": bot.name,
            ]
        }
    }

    /// Returns the new room id, or nil with `errorMessage` set.
    /// Remote members are registered right after the room exists, since
    /// `groups.peer.register` needs the room on this gateway.
    func create(
        name: String, bots: [BotSummary], remote: [RemoteMemberInvite] = [],
        roomID: String = UUID().uuidString.lowercased()
    ) async -> String? {
        guard let client, Self.memberLimits.contains(bots.count + remote.count) else { return nil }
        do {
            let result = try await client.request(
                HermesFeatureIDs.ID.groupsCreate.rawValue,
                params: [
                    "room_id": roomID, "name": name, "members": Self.members(for: bots) + remote.map(\.rosterRow),
                ])
            if let room = (result["room"] as? [String: Any]).flatMap(GroupRoom.init) {
                rooms.insert(room, at: 0)
            }
            for invite in remote {
                _ = try await client.request(
                    HermesFeatureIDs.ID.groupsPeerRegister.rawValue,
                    params: [
                        "room_id": roomID, "member_id": invite.memberID, "target_url": invite.endpointURL,
                        "target_profile": invite.targetProfile, "grant": invite.grant, "catalog": invite.catalog,
                    ])
            }
            errorMessage = nil
            return roomID
        } catch {
            errorMessage = "Couldn't create the group: \(error.localizedDescription)"
            return nil
        }
    }

    func send(_ text: String, to roomID: String, thread: String = mainThreadID) async {
        guard pendingRooms.insert(roomID).inserted else { return }
        defer { pendingRooms.remove(roomID) }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let client, !trimmed.isEmpty else { return }
        do {
            _ = try await client.request(
                HermesFeatureIDs.ID.groupsSend.rawValue,
                params: [
                    "room_id": roomID, "event_id": UUID().uuidString.lowercased(),
                    "payload": ["text": GenerativeUIIntegration.preparePrompt(trimmed), "thread_id": thread],
                ])
            workingRooms.insert(roomID)
            errorMessage = nil
            await poll(roomID)
        } catch {
            errorMessage = "Couldn't send: \(error.localizedDescription)"
        }
    }

    /// Hermes has no room push events; replay the log after the last cursor
    /// and read live driver status.
    func poll(_ roomID: String) async {
        guard let client else { return }
        var appended: [GroupRoomEvent] = []
        if cursors[roomID] == nil {
            // Long rooms: start near the end instead of replaying every event.
            let latest =
                (try? await client.request(
                    HermesFeatureIDs.ID.groupsLog.rawValue,
                    params: [
                        "room_id": roomID, "since_seq": 0, "limit": 1,
                    ]))?["latest_seq"] as? Int ?? 0
            let start = max(0, latest - Self.historyWindow)
            cursors[roomID] = start
            earliestLoadedSeq[roomID] = start
        }
        var cursor = cursors[roomID] ?? 0
        while true {
            guard
                let page = try? await client.request(
                    HermesFeatureIDs.ID.groupsLog.rawValue,
                    params: [
                        "room_id": roomID, "since_seq": cursor, "limit": 500,
                    ])
            else { break }
            appended += (page["events"] as? [[String: Any]] ?? []).compactMap(GroupRoomEvent.init)
            cursor = max(cursor, page["cursor"] as? Int ?? cursor)
            guard page["has_more"] as? Bool == true else { break }
        }
        cursors[roomID] = cursor
        if !appended.isEmpty { events[roomID, default: []] += appended }
        markSeen(roomID, through: cursor)
        updateLastMessage(roomID, from: appended)

        guard
            let state = try? await client.request(HermesFeatureIDs.ID.groupsState.rawValue, params: ["room_id": roomID])
        else { return }
        let status = state["driver_status"] as? [String: Any]
        let working = status?["working"] as? Bool == true
        if working != workingRooms.contains(roomID) {
            if working { workingRooms.insert(roomID) } else { workingRooms.remove(roomID) }
        }
        let actions = status?["pending_actions"] as? [[String: Any]] ?? []
        let pending = actions.compactMap(GroupRoomApproval.init)
        if approvals[roomID] ?? [] != pending { approvals[roomID] = pending }
        let retryIDs = actions.filter { $0["kind"] as? String == "retry" }.compactMap { $0["task_id"] as? String }
        if retries[roomID] ?? [] != retryIDs { retries[roomID] = retryIDs }
        let blocked = status?["blocked"] as? Bool == true
        if blocked != blockedRooms.contains(roomID) {
            if blocked { blockedRooms.insert(roomID) } else { blockedRooms.remove(roomID) }
        }
        if let room = (state["room"] as? [String: Any]).flatMap(GroupRoom.init),
            let index = rooms.firstIndex(where: { $0.id == roomID }), rooms[index] != room
        {
            rooms[index] = room
        }

        // Re-read activity for members mid-turn or with a new reply.
        var active = Set(
            appended.compactMap { event -> String? in
                if case .member(let id) = event.kind { return id }
                if case .started(let id) = event.kind { return id }
                return nil
            })
        if working { active.formUnion(openTurnMembers(in: roomID)) }
        if memberTurns[roomID] == nil, let room = rooms.first(where: { $0.id == roomID }) {
            active.formUnion(room.members.map(\.memberID))
        }
        for memberID in active { await refreshActivity(memberID, in: roomID) }
    }

    private func openTurnMembers(in roomID: String) -> Set<String> {
        var open: Set<String> = []
        for event in events[roomID] ?? [] {
            switch event.kind {
            case .started(let id): open.insert(id)
            case .member(let id): open.remove(id)
            case .failed(let id): if let id { open.remove(id) }
            default: break
            }
        }
        return open
    }

    private func refreshActivity(_ memberID: String, in roomID: String) async {
        guard let client, let member = rooms.first(where: { $0.id == roomID })?.member(memberID) else { return }
        let key = "\(roomID)/\(memberID)"
        if memberSessionIDs[key] == nil {
            let listed = try? await client.request(
                HermesFeatureIDs.ID.sessionList.rawValue,
                params: [
                    "title": "Group: \(roomID)", "profile": member.profile,
                ])
            let row = (listed?["sessions"] as? [[String: Any]])?.first
            memberSessionIDs[key] = (row?["resolved_id"] as? String) ?? (row?["id"] as? String)
        }
        guard let sessionID = memberSessionIDs[key],
            let rows = try? await HermesControlRPC(client: client)
                .sessionMessages(sessionID: sessionID, profileID: member.profile, latest: true)["data"]
                as? [[String: Any]]
        else { return }
        let turns = GroupMemberTurn.turns(from: rows)
        if memberTurns[roomID]?[memberID] != turns { memberTurns[roomID, default: [:]][memberID] = turns }
    }

    /// Tool activity behind a member's posted reply, if its session recorded any.
    func tools(for event: GroupRoomEvent, in roomID: String) -> [ActiveToolCall] {
        guard case .member(let memberID) = event.kind else { return [] }
        return memberTurns[roomID]?[memberID]?.last { $0.matches(event.text) }?.tools ?? []
    }

    /// Tools a member's still-running turn has recorded so far.
    func liveTools(for memberID: String, in roomID: String) -> [ActiveToolCall] {
        guard let last = memberTurns[roomID]?[memberID]?.last, last.reply == nil else { return [] }
        return last.tools
    }

    /// Prepends the window of log rows before the earliest loaded one.
    func loadEarlier(_ roomID: String) async {
        guard let client, let end = earliestLoadedSeq[roomID], end > 0 else { return }
        let start = max(0, end - Self.historyWindow)
        var older: [GroupRoomEvent] = []
        var cursor = start
        while cursor < end {
            guard
                let page = try? await client.request(
                    HermesFeatureIDs.ID.groupsLog.rawValue,
                    params: [
                        "room_id": roomID, "since_seq": cursor, "limit": min(500, end - cursor),
                    ])
            else { return }
            older += (page["events"] as? [[String: Any]] ?? []).compactMap(GroupRoomEvent.init).filter { $0.seq <= end }
            let next = page["cursor"] as? Int ?? cursor
            guard next > cursor, page["has_more"] as? Bool == true else { break }
            cursor = next
        }
        events[roomID] = older + (events[roomID] ?? [])
        earliestLoadedSeq[roomID] = start
    }

    /// Target side: mint a grant for one of this machine's bots, scoped to the
    /// home's room and member, and answer with an invite code.
    func invite(_ request: RemoteMemberRequest, bot: BotSummary) async -> String? {
        guard let client else { return nil }
        do {
            let result = try await client.request(
                HermesFeatureIDs.ID.groupsPeerInvite.rawValue,
                params: [
                    "profile": bot.id, "room_id": request.roomID, "home_install_id": request.homeInstallID,
                    "authority_gateway_id": request.homeInstallID, "authority_epoch": 1,
                    "member_id": request.memberID, "ttl_seconds": 86_400,
                ])
            let endpoint = result["endpoint"] as? [String: Any] ?? [:]
            guard endpoint["available"] as? Bool == true, let url = endpoint["url"] as? String,
                let grant = result["grant"] as? String,
                let catalog = result["catalog"],
                let catalogData = try? JSONSerialization.data(withJSONObject: catalog)
            else {
                errorMessage =
                    "This machine has no reachable RoomLink endpoint (\(endpoint["reason"] as? String ?? "unavailable"))."
                return nil
            }
            errorMessage = nil
            return RoomLinkCode.encode(
                RemoteMemberInvite(
                    memberID: request.memberID, handle: request.handle,
                    targetProfile: result["target_profile"] as? String ?? bot.id, displayName: bot.name,
                    grant: grant, endpointURL: url, catalogJSON: String(decoding: catalogData, as: UTF8.self)))
        } catch {
            errorMessage = "Couldn't create the invite: \(error.localizedDescription)"
            return nil
        }
    }

    func retry(_ taskID: String, in roomID: String) async {
        guard pendingRooms.insert(roomID).inserted else { return }
        defer { pendingRooms.remove(roomID) }
        do {
            _ = try await client?.request(
                HermesFeatureIDs.ID.groupsRetry.rawValue, params: ["room_id": roomID, "task_id": taskID])
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't retry: \(error.localizedDescription)"
        }
        await poll(roomID)
    }

    func stop(_ roomID: String) async {
        guard pendingRooms.insert(roomID).inserted else { return }
        defer { pendingRooms.remove(roomID) }
        _ = try? await client?.request(HermesFeatureIDs.ID.groupsStop.rawValue, params: ["room_id": roomID])
        await poll(roomID)
    }

    func rename(_ roomID: String, to name: String) async {
        guard pendingRooms.insert(roomID).inserted else { return }
        defer { pendingRooms.remove(roomID) }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        _ = try? await client?.request(
            HermesFeatureIDs.ID.groupsRename.rawValue,
            params: [
                "room_id": roomID, "event_id": UUID().uuidString.lowercased(), "name": trimmed,
            ])
        await refreshRooms()
    }

    func disband(_ roomID: String) async {
        guard pendingRooms.insert(roomID).inserted else { return }
        defer { pendingRooms.remove(roomID) }
        do {
            _ = try await client?.request(HermesFeatureIDs.ID.groupsDisband.rawValue, params: ["room_id": roomID])
            rooms.removeAll { $0.id == roomID }
            events[roomID] = nil
            cursors[roomID] = nil
        } catch {
            errorMessage = "Couldn't disband the group: \(error.localizedDescription)"
        }
    }

    /// Room members may only offer `once` or `deny` (Hermes' room driver).
    func respond(to approval: GroupRoomApproval, in roomID: String, approve: Bool) async {
        guard pendingRooms.insert(roomID).inserted else { return }
        defer { pendingRooms.remove(roomID) }
        _ = try? await client?.request(
            HermesFeatureIDs.ID.groupsApprove.rawValue,
            params: [
                "room_id": roomID, "member_id": approval.memberID, "task_id": approval.taskID,
                "execution_generation": approval.executionGeneration, "request_id": approval.requestID,
                "choice": approve ? "once" : "deny",
            ])
        await poll(roomID)
    }
}
