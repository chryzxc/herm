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

    /// Bold glyph drawn in the state's color on its tinted disc. SF Symbols,
    /// because Phosphor's filled set boxes these glyphs in a square.
    var symbol: String {
        switch self {
        case .approval: "exclamationmark"
        case .clarification: "questionmark"
        case .failed: "xmark"
        case .running, .done: "checkmark"
        }
    }

    var color: Color {
        switch self {
        case .approval: .dockWarning
        case .clarification, .running: DockStatusTone.working.color
        case .failed: .dockDestructive
        case .done: .dockSuccess
        }
    }
}

/// Spinner for running, a filled glyph for everything else. Fixed footprint so
/// titles stay aligned whether or not a state is showing. Sizes live in `Role`,
/// never at the call site, so a state reads the same everywhere it appears.
struct DockActivityIndicator: View {
    /// Where the mark sits. Each role owns its size and treatment.
    enum Role {
        /// Spinner in a dense rail or tab strip.
        case compact
        /// Beside a title or label.
        case inline
        /// Pinned to an avatar's corner; carries a canvas ring to separate it.
        case badge
        /// Stands in for a row's avatar in the leading column.
        case row

        var size: CGFloat {
            switch self {
            case .compact: 10
            case .inline: 14
            case .badge: 15
            case .row: 20
            }
        }
    }

    let state: DockActivityState
    var role: Role = .inline
    /// Overrides the state's color (e.g. on an accent-filled surface).
    var tint: Color?
    /// Only a session that finished work with news you haven't seen shows a dot instead of the check.
    var unreadDot = false
    var animates = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var size: CGFloat { role.size }

    var body: some View {
        Group {
            if state == .done, unreadDot {
                Circle().fill(tint ?? state.color).frame(width: size * 0.6, height: size * 0.6)
            } else if state.icon != nil {
                // Tinted disc, hairline ring, bold glyph in the state's color:
                // the glyph names the state, the hue only reinforces it.
                let color = tint ?? state.color
                ZStack {
                    Circle().fill(Color.dockOpaqueCanvas)
                    Circle().fill(color.opacity(0.22))
                    Circle().strokeBorder(color.opacity(0.6), lineWidth: 1)
                    Image(systemName: state.symbol)
                        .font(.system(size: size * 0.5, weight: .heavy))
                        .foregroundStyle(color)
                }
            } else {
                spinner(tint ?? state.color)
            }
        }
        .frame(width: size, height: size)
        .background {
            if role == .badge { Circle().fill(Color.dockOpaqueCanvas).dockPadding(-1.5) }
        }
        .help(state.label)
        .accessibilityLabel(state.label)
    }

    /// Drawn arc rather than ProgressView, which ignores tint and washes out on avatars.
    @ViewBuilder private func spinner(_ color: Color) -> some View {
        if reduceMotion || !animates {
            spinnerArc(color, turn: 0)
        } else {
            // Core Animation turns the arc: it keeps spinning inside collapsed task
            // disclosures and costs no window render per frame, however many rows spin.
            DockLayerMotion(kind: .spin(period: 0.9, lineWidth: max(1.8, size * 0.16)), color: color)
        }
    }

    private func spinnerArc(_ color: Color, turn: Double) -> some View {
        let line = max(1.8, size * 0.16)
        return Circle().stroke(color.opacity(0.25), lineWidth: line)
            .overlay {
                Circle().trim(from: 0, to: 0.7).stroke(color, style: StrokeStyle(lineWidth: line, lineCap: .round))
                    .rotationEffect(.degrees(turn * 360))
            }
            .dockPadding(line / 2)
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
            return resolvedAttentionState
        case .working: return .running
        case .finished: return .done
        case .pending: return nil
        }
    }
}
