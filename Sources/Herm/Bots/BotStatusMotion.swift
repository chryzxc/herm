import SwiftUI

/// The one status choreography every Bot surface shares, so a Bot doing the
/// same thing moves the same way in the notch, the chat, the quick preview and
/// the sidebar. Working runs the chat's reach-tilt-hop loop, waiting on you
/// shakes at the top of every 2s beat, and finishing hops once.
enum BotStatusMotion: Equatable {
    case working, blocked, finished, resting

    init(mood: BotMood) {
        switch mood {
        case .thinking, .tool, .replying, .handoff, .subagent, .compressing: self = .working
        case .approval, .clarify: self = .blocked
        case .done: self = .finished
        default: self = .resting
        }
    }

    /// Moves on the clock; finished moves only during its hop, except on a
    /// status carrier (`live`), where an unopened result keeps nudging.
    func loops(live: Bool = false) -> Bool { self == .working || self == .blocked || (live && self == .finished) }

    /// How often a live finished Bot re-hops while its result waits unopened.
    static let finishedNudgePeriod: TimeInterval = 6

    /// The pose `t` seconds into this state. A finished hop in flight wins.
    func pose(at t: TimeInterval, hopAge: TimeInterval? = nil, variation: Int = 0, live: Bool = false)
        -> BotWorkingPose
    {
        if let hopAge, hopAge >= 0, hopAge < BotWorkingPose.reactionDuration {
            return .reaction(at: hopAge, variation: variation)
        }
        if live, self == .finished {
            let cycle = max(0, t).truncatingRemainder(dividingBy: Self.finishedNudgePeriod)
            return cycle < BotWorkingPose.reactionDuration ? .reaction(at: cycle, variation: variation) : .rest
        }
        switch self {
        case .working:
            return .at(t)
        case .blocked:
            // A quick head shake at the top of each 2s beat, then still.
            let beat = max(0, t).truncatingRemainder(dividingBy: 2) / 2
            let phase = min(beat / 0.25, 1)
            let shake = sin(phase * 4 * .pi) * sin(phase * .pi) * (1 - phase) * 8
            return BotWorkingPose(rotation: shake)
        case .finished, .resting:
            return .rest
        }
    }
}

extension BotWorkingPose {
    /// The single mapping from a pose to the avatar's transform.
    func applied<Content: View>(to content: Content, size: CGFloat) -> some View {
        content
            .scaleEffect(x: scaleX, y: scaleY)
            .rotationEffect(.degrees(rotation))
            .offset(x: size * reach, y: -size * 0.2 * lift)
    }
}

extension View {
    /// Plays the shared status choreography. `live` keeps a status carrier
    /// (the notch) moving while Herm is in the background; `cue` replays the
    /// finished hop when another result lands without the state changing.
    func botStatusMotion(_ motion: BotStatusMotion, size: CGFloat, live: Bool = false, cue: Int = 0) -> some View {
        modifier(BotStatusMotionModifier(motion: motion, size: size, live: live, cue: cue))
    }
}

private struct BotStatusMotionModifier: ViewModifier {
    let motion: BotStatusMotion
    let size: CGFloat
    let live: Bool
    let cue: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dockHostVisible) private var hostVisible
    @Environment(\.dockHostResizing) private var hostResizing
    @ObservedObject private var focus = HermFocus.shared
    @State private var startedAt = Date()
    @State private var hopAt: Date?

    private var moves: Bool {
        hostVisible && !hostResizing && DockMotion.isEnabled(reduceMotion: reduceMotion) && (live || focus.engaged)
    }

    func body(content: Content) -> some View {
        let running = moves && (motion.loops(live: live) || hopAt != nil)
        TimelineView(.dockMotion(rate: 30, paused: !running, pausesOnScroll: !live)) { context in
            let pose =
                running
                ? motion.pose(
                    at: context.date.timeIntervalSince(startedAt),
                    hopAge: hopAt.map { context.date.timeIntervalSince($0) }, variation: cue, live: live)
                : .rest
            pose.applied(to: content, size: size)
        }
        .onChange(of: motion) { old, new in
            startedAt = Date()
            if new == .finished, old != .finished { hop() }
        }
        .onChange(of: cue) { old, new in
            if motion == .finished, new > old { hop() }
        }
        .onChange(of: moves) { _, moving in
            // Never replay a stale hop when motion resumes.
            if !moving { hopAt = nil }
        }
    }

    private func hop() {
        guard moves else { return }
        let now = Date()
        hopAt = now
        DispatchQueue.main.asyncAfter(deadline: .now() + BotWorkingPose.reactionDuration) {
            if hopAt == now { hopAt = nil }
        }
    }
}
