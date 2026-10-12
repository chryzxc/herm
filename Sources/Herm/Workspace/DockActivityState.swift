import SwiftUI

/// The one vocabulary for "what is this thing doing right now", shared by the
/// session rail, bot switcher, notch, kanban and banners so a state always
/// looks the same. Ordered by priority: a row showing several states uses the
/// lowest raw value.
enum DockActivityState: Int, Comparable, CaseIterable, Sendable {
    case approval, clarification, failed, running, done

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    var label: String {
        switch self {
        case .approval: "Needs your approval"
        case .clarification: "Needs your answer"
        case .failed: "Failed"
        case .running: "Running"
        case .done: "Done"
        }
    }

    /// nil means a spinner (running).
    var icon: Ph? {
        switch self {
        case .approval: .warningCircle
        case .clarification: .question
        case .failed: .xCircle
        case .running: nil
        case .done: .checkCircle
        }
    }

    var color: Color {
        switch self {
        case .approval: .dockWarning
        case .clarification, .running: .dockAccent
        case .failed: .dockDestructive
        case .done: .dockSuccess
        }
    }
}

/// Spinner for running, a filled glyph for everything else. Fixed footprint so
/// titles stay aligned whether or not a state is showing.
struct DockActivityIndicator: View {
    let state: DockActivityState
    var size: CGFloat = 12
    /// Overrides the state's color (e.g. on an accent-filled surface).
    var tint: Color?
    /// Chat rows mark finished-with-news as an unread dot instead of a check.
    var unreadDot = false

    var body: some View {
        Group {
            if state == .done, unreadDot {
                Circle().fill(tint ?? state.color).frame(width: size * 0.6, height: size * 0.6)
            } else if let icon = state.icon {
                // Opaque backing: the filled glyph's cut-out would otherwise show whatever sits behind it.
                DockIcon(icon, size: size, weight: .fill, color: tint ?? state.color)
                    .background(Circle().fill(Color.dockCanvas).padding(size * 0.12))
            } else {
                ProgressView().controlSize(.small).scaleEffect(size / 20).tint(tint ?? state.color)
            }
        }
        .frame(width: size, height: size)
        .help(state.label)
        .accessibilityLabel(state.label)
    }
}

extension SessionAttentionDot {
    /// nil: a generic activity dot that carries no state of its own.
    var activityState: DockActivityState? {
        switch self {
        case .warning: .approval
        case .clarification: .clarification
        case .failure: .failed
        case .success: .done
        case .activity: nil
        }
    }
}

extension SidebarSessionStatus {
    var activityState: DockActivityState? {
        switch self {
        case .working: .running
        case .needsApproval: .approval
        case .needsClarification: .clarification
        case .failed: .failed
        case .unreadComplete: .done
        case .none: nil
        }
    }
}

extension EdgeNotchTask {
    /// nil keeps the neutral tone dot (queued or review work, stale status).
    var activityState: DockActivityState? {
        guard isStatusCurrent || phase == .finished else { return nil }
        if isFailure { return .failed }
        switch phase {
        case .attention:
            // ponytail: HermesStatus titles say which kind of ask this is; an explicit kind field if more asks appear.
            return deliveryQuestion != nil || statusLabel.localizedCaseInsensitiveContains("clarif") ? .clarification : .approval
        case .working: return .running
        case .finished: return .done
        case .pending: return nil
        }
    }
}
