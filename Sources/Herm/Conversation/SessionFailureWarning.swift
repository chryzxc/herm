import SwiftUI

enum SessionFailureWarningPolicy {
    static func hasUnseenFailure(in rows: [[String: Any]], after seenAt: Date, through cutoff: Date?) -> Bool {
        rows.contains { row in
            guard row["display_kind"] as? String == "failed_turn",
                let stamp = (row["timestamp"] as? NSNumber)?.doubleValue
            else { return false }
            return stamp > seenAt.timeIntervalSince1970
                && (cutoff.map { stamp <= $0.timeIntervalSince1970 } ?? true)
        }
    }
}

struct SessionFailureWarning: View {
    static let statusSlotWidth: CGFloat = 48
    private let description = "Failed turn. Open conversation for details."

    var body: some View {
        DockIcon(.warning, size: 12, color: .dockWarning)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(description)
            .help(description)
    }
}

struct SessionRowActivityIndicators: View {
    let session: HermesSession
    let attention: SessionAttentionDot?
    var seenStore = SidebarSessionSeenStore.shared

    var body: some View {
        HStack(spacing: 6) {
            if session.isWorking {
                SessionActivityGlyph(isWorking: true, hasUnreadUpdate: false, session: session)
            } else {
                SessionUnreadReplyBadge(session: session, hasKnownFailure: attention == .failure, seenStore: seenStore)
            }
            if let attention, attention != .success, attention != .failure {
                if let state = attention.activityState {
                    DockActivityIndicator(state: state, unreadDot: true)
                } else {
                    Circle().fill(attention.color).frame(width: 6, height: 6)
                }
            }
        }
    }
}
