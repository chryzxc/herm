import SwiftUI

/// Reads Hermes history without resuming or mutating the session. Counts are
/// disposable projections; only the existing seen timestamp is persisted.
@MainActor
final class SessionUnreadReplies {
    struct Projection: Equatable {
        let count: Int
        let firstRowID: Int?
    }

    struct BotCounts: Equatable {
        var counts: [String: Int] = [:]
        var incomplete: Bool
    }

    private let client: HermesRPCClientProtocol
    private struct Key: Hashable {
        let identity: ProfileScopedID
        let seenAt: Date
        let cutoff: Date?
    }
    /// The newest stored row a projection was read through, including its
    /// serialized fields. While the newest row is unchanged, the history behind
    /// the projection has neither grown nor had its tail rewritten in place.
    private struct Tail: Equatable {
        let rowID: Int
        let timestamp: Double
        let fingerprint: Data
    }
    private struct Entry {
        let projection: Projection
        let tail: Tail?
        let updatedAt: Date?
        let expiresAt: Date
        /// When the projection was last built from a full read.
        let readAt: Date
    }
    private struct Read {
        let projection: Projection
        let tail: Tail?
    }
    /// Badges re-ask every 15 seconds and running sessions bump `updatedAt`
    /// constantly, so an expired or outdated entry is first revalidated with a
    /// one-row probe instead of re-reading and re-parsing the whole history.
    private static let freshFor: TimeInterval = 10
    /// The probe only sees the newest row. Hermes can still rewrite older rows
    /// in place (transcript repair, pruning), so a projection is rebuilt from a
    /// full read at least this often.
    private static let maximumReuse: TimeInterval = 300
    private var cached: [Key: Entry] = [:]
    /// In-flight reads also key on the caller's `updatedAt`, so a caller holding
    /// a newer session snapshot never joins a read started for an older one.
    private struct PendingKey: Hashable {
        let key: Key
        let updatedAt: Date?
    }
    private var pending: [PendingKey: Task<Projection, Error>] = [:]

    private let now: () -> Date

    init(client: HermesRPCClientProtocol, now: @escaping () -> Date = Date.init) {
        self.client = client
        self.now = now
    }

    func botCounts(
        sessions: [HermesSession], scopeProfileID: String?, seenStore: SidebarSessionSeenStore, incomplete: Bool
    ) async throws -> BotCounts {
        var result = BotCounts(incomplete: incomplete)
        var visited: Set<ProfileScopedID> = []
        for session in sessions where !session.isHidden {
            try Task.checkCancellation()
            guard let profileID = session.profileID ?? scopeProfileID else {
                result.incomplete = true
                continue
            }
            let identity = ProfileScopedID(profileID: profileID, resourceID: session.id)
            guard visited.insert(identity).inserted else { continue }
            guard seenStore.isBaselined(profileID: profileID) else { continue }
            let seenAt = seenStore.seenAt(profileID: profileID, sessionID: session.id) ?? .distantPast
            guard let updatedAt = session.updatedAt else {
                result.incomplete = true
                continue
            }
            guard updatedAt > seenAt else { continue }
            do {
                let unread = try await project(session: session, profileID: profileID, after: seenAt)
                if unread.count > 0 { result.counts[profileID, default: 0] += 1 }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                result.incomplete = true
            }
        }
        return result
    }

    func count(session: HermesSession, profileID: String?, after seenAt: Date) async throws -> Int {
        try await project(session: session, profileID: profileID, after: seenAt).count
    }

    func project(session: HermesSession, profileID: String?, after seenAt: Date, through cutoff: Date? = nil)
        async throws -> Projection
    {
        let key = Key(
            identity: ProfileScopedID(profileID: profileID, resourceID: session.id), seenAt: seenAt, cutoff: cutoff)
        let updatedAt = session.lastUpdatedAt
        let entry = cached[key]
        if let entry, entry.updatedAt == updatedAt, entry.expiresAt > now() { return entry.projection }
        let pendingKey = PendingKey(key: key, updatedAt: updatedAt)
        if let task = pending[pendingKey] { return try await task.value }
        let task = Task { () throws -> Projection in
            if let entry, let tail = entry.tail, self.now().timeIntervalSince(entry.readAt) < Self.maximumReuse,
                try await self.newestRow(session: session, profileID: profileID) == tail
            {
                self.store(
                    Entry(
                        projection: entry.projection, tail: tail, updatedAt: updatedAt,
                        expiresAt: self.now().addingTimeInterval(Self.freshFor), readAt: entry.readAt), for: key)
                return entry.projection
            }
            let read = try await self.read(session: session, profileID: profileID, after: seenAt, through: cutoff)
            self.store(
                Entry(
                    projection: read.projection, tail: read.tail, updatedAt: updatedAt,
                    expiresAt: self.now().addingTimeInterval(Self.freshFor), readAt: self.now()), for: key)
            return read.projection
        }
        pending[pendingKey] = task
        defer { pending[pendingKey] = nil }
        return try await task.value
    }

    private func store(_ entry: Entry, for key: Key) {
        if cached[key] == nil, cached.count >= 256 { cached.removeAll() }
        cached[key] = entry
    }

    private func newestRow(session: HermesSession, profileID: String?) async throws -> Tail? {
        guard
            let path = TranscriptHistoryPaging.pagePath(
                sessionID: session.id, profileID: profileID, limit: 1, offset: 0),
            let page = TranscriptHistoryPaging.page(from: try await client.fetchHTTP(path))
        else { throw HermesGateway.GatewayError.malformedResponse }
        return page.rows.last.flatMap(Self.tail(of:))
    }

    private static func tail(of row: [String: Any]) -> Tail? {
        guard let id = (row["id"] as? NSNumber)?.intValue,
            let timestamp = (row["timestamp"] as? NSNumber)?.doubleValue,
            JSONSerialization.isValidJSONObject(row),
            let fingerprint = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
        else { return nil }
        return Tail(rowID: id, timestamp: timestamp, fingerprint: fingerprint)
    }

    private func read(session: HermesSession, profileID: String?, after seenAt: Date, through cutoff: Date?)
        async throws -> Read
    {
        var cursor = TranscriptHistoryCursor(storageSessionID: session.id, profileID: profileID)
        var rows: [[String: Any]] = []
        let limit = TranscriptHistoryPaging.maximumPageRowLimit
        for _ in 0..<TranscriptHistoryPaging.maximumPagesPerLoad {
            try Task.checkCancellation()
            guard
                let path = TranscriptHistoryPaging.pagePath(
                    sessionID: session.id, profileID: profileID, limit: limit, offset: cursor.nextOffset),
                let page = TranscriptHistoryPaging.page(from: try await client.fetchHTTP(path))
            else { throw HermesGateway.GatewayError.malformedResponse }
            rows = TranscriptHistoryPaging.advance(&cursor, with: page, limit: limit) + rows
            let reachedSeen = page.rows.allSatisfy { row in
                (row["timestamp"] as? NSNumber).map { $0.doubleValue <= seenAt.timeIntervalSince1970 } ?? false
            }
            if !cursor.hasMore || reachedSeen {
                // Missing timestamps must not turn into Date() in the parser.
                guard rows.allSatisfy({ $0["timestamp"] is NSNumber }) else {
                    throw HermesGateway.GatewayError.malformedResponse
                }
                let projected = await DockModel.projectStoredRowsOffMain(rows)
                let (transcript, _) = await DockModel.parseMessagesOffMain(
                    projected, defaultBotProfileID: nil, defaultBotDisplayName: nil)
                try Task.checkCancellation()
                let unread = ConversationUnreadMessagePolicy.project(
                    transcript.messages, after: seenAt, through: cutoff)
                let firstRowID = transcript.rowIDs.filter { $0.value == unread.firstMessageID }.keys.min()
                return Read(
                    projection: Projection(count: unread.count, firstRowID: firstRowID),
                    tail: rows.last.flatMap(Self.tail(of:)))
            }
        }
        // A partial history read cannot claim an exact unread count.
        throw HermesGateway.GatewayError.malformedResponse
    }
}

struct SessionUnreadReplyContext {
    let replies: SessionUnreadReplies
    let profileID: String?
}

private struct SessionUnreadRepliesKey: EnvironmentKey {
    static let defaultValue: SessionUnreadReplyContext? = nil
}

extension EnvironmentValues {
    var sessionUnreadReplies: SessionUnreadReplyContext? {
        get { self[SessionUnreadRepliesKey.self] }
        set { self[SessionUnreadRepliesKey.self] = newValue }
    }
}

/// Red count pill shared by session rows and the chats rail button.
struct UnreadCountPill: View {
    let label: String

    var body: some View {
        Text(label)
            .dockFont(.compactStatus, weight: .semibold)
            .monospacedDigit()
            .foregroundStyle(DockAccentColor.unreadBadgeText)
            .dockPill(tint: DockAccentColor.unreadBadgeFill, solid: true, compact: true)
            .fixedSize()
    }
}

struct SessionUnreadReplyBadge: View {
    let session: HermesSession
    var showUnavailable = true
    @Environment(\.sessionUnreadReplies) private var replies
    @ObservedObject private var seenStore = SidebarSessionSeenStore.shared
    @State private var result: CountState?
    @State private var lastRead: Read?

    private enum CountState {
        case loaded(Int)
        case unavailable
    }

    private struct Read: Hashable {
        let identity: ProfileScopedID
        let updatedAt: Date?
        let seenAt: Date?
        let baselined: Bool
        let refresh: Int
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { timeline in
            badge(now: timeline.date)
        }
    }

    private func badge(now: Date) -> some View {
        let profileID = session.profileID ?? replies?.profileID
        let read = Read(
            identity: ProfileScopedID(profileID: profileID, resourceID: session.id),
            updatedAt: session.lastUpdatedAt,
            seenAt: seenStore.seenAt(profileID: profileID, sessionID: session.id),
            baselined: seenStore.isBaselined(profileID: profileID),
            refresh: Int(now.timeIntervalSince1970 / 15))
        return Group {
            switch result {
            case .loaded(let count) where count > 0:
                UnreadCountPill(label: count > 99 ? "99+" : "\(count)")
                    .accessibilityLabel("\(count) unread AI \(count == 1 ? "response" : "responses")")
            case .unavailable where showUnavailable:
                Text("?")
                    .dockFont(.compactStatus, weight: .semibold)
                    .foregroundStyle(Color.dockPrimaryText)
                    .dockPill(tint: .dockSecondaryText, compact: true)
                    .fixedSize()
                    .accessibilityLabel("Unread response count unavailable")
                    .help("Could not read the unread AI response count")
            default:
                EmptyView()
            }
        }
        .task(id: read) {
            if lastRead?.identity != read.identity || lastRead?.seenAt != read.seenAt
                || lastRead?.baselined != read.baselined
            {
                result = nil
            }
            lastRead = read
            guard let replies, read.seenAt != nil || read.baselined else { return }
            do {
                let count = try await replies.replies.count(
                    session: session, profileID: read.identity.profileID, after: read.seenAt ?? .distantPast)
                try Task.checkCancellation()
                result = .loaded(count)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                result = .unavailable
            }
        }
    }
}

/// The sidebar row's status slot: a spinner or attention glyph while a turn needs
/// watching, otherwise the unread reply count. Split tabs reuse it so both agree.
struct SidebarSessionStatusIndicator: View {
    let session: HermesSession
    let status: SidebarSessionStatus

    var body: some View {
        if status == .unreadComplete || status == .none {
            SessionUnreadReplyBadge(session: session, showUnavailable: status == .unreadComplete)
        } else if let state = status.activityState {
            DockActivityIndicator(state: state, size: 12, unreadDot: true)
        }
    }
}
