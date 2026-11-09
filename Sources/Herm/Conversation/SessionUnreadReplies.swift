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
        let updatedAt: Date?
        let seenAt: Date
        let cutoff: Date?
    }
    private var cached: [Key: (projection: Projection, expiresAt: Date)] = [:]
    private var pending: [Key: Task<Projection, Error>] = [:]

    init(client: HermesRPCClientProtocol) {
        self.client = client
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
            identity: ProfileScopedID(profileID: profileID, resourceID: session.id),
            updatedAt: session.lastUpdatedAt, seenAt: seenAt, cutoff: cutoff)
        if let value = cached[key], value.expiresAt > Date() { return value.projection }
        if let task = pending[key] { return try await task.value }
        let task = Task { try await self.read(session: session, profileID: profileID, after: seenAt, through: cutoff) }
        pending[key] = task
        do {
            let value = try await task.value
            pending[key] = nil
            if cached.count >= 256 { cached.removeAll() }
            cached[key] = (value, Date().addingTimeInterval(10))
            return value
        } catch {
            pending[key] = nil
            throw error
        }
    }

    private func read(session: HermesSession, profileID: String?, after seenAt: Date, through cutoff: Date?)
        async throws -> Projection
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
                return Projection(count: unread.count, firstRowID: firstRowID)
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
                Text(count > 99 ? "99+" : "\(count)")
                    .dockFont(.compactStatus, weight: .semibold)
                    .monospacedDigit()
                    .foregroundStyle(DockAccentColor.unreadBadgeText)
                    .dockPill(tint: DockAccentColor.unreadBadgeFill, solid: true, compact: true)
                    .fixedSize()
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
