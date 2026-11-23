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
    static let statusSlotWidth = DockSidebarListMetrics.statusSlotWidth
    private let description = "Failed turn. Open conversation for details."

    var body: some View {
        DockIcon(.warning, size: DockSidebarListMetrics.statusMark - 2, color: .dockDestructive)
            .frame(width: DockSidebarListMetrics.statusMark, height: DockSidebarListMetrics.statusMark)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(description)
            .reportSessionStatusLabel(description)
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
                    DockActivityIndicator(state: state, role: .status, unreadDot: true)
                        .reportSessionStatusLabel(state.label)
                } else {
                    Circle().fill(attention.color).frame(width: 6, height: 6)
                }
            }
        }
    }
}

// Native render tests observe the labels from the mounted SwiftUI views without
// depending on whether AppKit exposes an accessibility tree for the test process.
#if DEBUG
    struct SessionStatusLabels: PreferenceKey {
        static let defaultValue: [String] = []
        static func reduce(value: inout [String], nextValue: () -> [String]) {
            value.append(contentsOf: nextValue())
        }
    }
#endif

extension View {
    @ViewBuilder func reportSessionStatusLabel(_ label: String) -> some View {
        #if DEBUG
            preference(key: SessionStatusLabels.self, value: [label])
        #else
            self
        #endif
    }
}
