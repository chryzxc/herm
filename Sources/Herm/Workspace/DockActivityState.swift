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

    /// Glyph knocked out of the solid disc.
    var mark: Ph {
        switch self {
        case .approval: .exclamationMark
        case .clarification: .question
        case .failed: .x
        case .running, .done: .check
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
    /// Only a session that finished work with news you haven't seen shows a dot instead of the check.
    var unreadDot = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if state == .done, unreadDot {
                Circle().fill(tint ?? state.color).frame(width: size * 0.6, height: size * 0.6)
            } else if state.icon != nil {
                // Solid disc with a knocked-out glyph so nothing behind it shows through.
                Circle().fill(tint ?? state.color).padding(size * 0.06)
                    .overlay { DockIcon(state.mark, size: size * 0.65, weight: .fill, color: .dockCanvas) }
            } else {
                spinner(tint ?? state.color)
            }
        }
        .frame(width: size, height: size)
        .help(state.label)
        .accessibilityLabel(state.label)
    }

    /// Drawn arc rather than ProgressView, which ignores tint and washes out on avatars.
    private func spinner(_ color: Color) -> some View {
        let line = max(1.8, size * 0.16)
        return TimelineView(.animation(paused: reduceMotion)) { timeline in
            let turn = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) / 0.9
            Circle().stroke(color.opacity(0.25), lineWidth: line)
                .overlay {
                    Circle().trim(from: 0, to: 0.7).stroke(color, style: StrokeStyle(lineWidth: line, lineCap: .round))
                        .rotationEffect(.degrees(turn * 360))
                }
                .padding(line / 2)
        }
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
