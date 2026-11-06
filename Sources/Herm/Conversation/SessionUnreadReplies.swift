import SwiftUI

/// Reads Hermes history without resuming or mutating the session. Counts are
/// disposable projections; only the existing seen timestamp is persisted.
@MainActor
final class SessionUnreadReplies {
    private let client: HermesRPCClientProtocol

    init(client: HermesRPCClientProtocol) {
        self.client = client
    }

    func count(session: HermesSession, profileID: String?, after seenAt: Date) async throws -> Int {
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
                return ConversationUnreadMessagePolicy.assistantResponseCount(transcript.messages, after: seenAt)
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
    @Environment(\.sessionUnreadReplies) private var replies
    @ObservedObject private var seenStore = SidebarSessionSeenStore.shared
    @State private var result: CountState?

    private enum CountState {
        case loaded(Int)
        case unavailable
    }

    private struct Read: Hashable {
        let identity: ProfileScopedID
        let updatedAt: Date?
        let seenAt: Date?
    }

    var body: some View {
        let read = Read(
            identity: ProfileScopedID(profileID: session.profileID ?? replies?.profileID, resourceID: session.id),
            updatedAt: session.lastUpdatedAt,
            seenAt: seenStore.seenAt(profileID: session.profileID ?? replies?.profileID, sessionID: session.id))
        Group {
            switch result {
            case .loaded(let count) where count > 0:
                Text(count > 99 ? "99+" : "\(count)")
                    .monospacedDigit()
                    .accessibilityLabel("\(count) unread AI \(count == 1 ? "response" : "responses")")
            case .unavailable:
                Text("?")
                    .accessibilityLabel("Unread response count unavailable")
                    .help("Could not read the unread AI response count")
            default:
                EmptyView()
            }
        }
        .dockFont(.metadata, weight: .semibold)
        .foregroundStyle(Color.dockPrimaryText)
        .dockPill(tint: .dockSecondaryText)
        .fixedSize()
        .task(id: read) {
            result = nil
            guard let replies else { return }
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
