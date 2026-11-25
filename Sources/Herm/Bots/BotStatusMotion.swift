import AppKit
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
    static let blockedShakePeriod: TimeInterval = 2
    static let blockedShakeDuration: TimeInterval = 0.5

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
            let beat = max(0, t).truncatingRemainder(dividingBy: Self.blockedShakePeriod)
            let phase = min(beat / Self.blockedShakeDuration, 1)
            let shake = sin(phase * 4 * .pi) * sin(phase * .pi) * (1 - phase) * 8
            return BotWorkingPose(rotation: shake)
        case .finished, .resting:
            return .rest
        }
    }
}

/// Composites the notch's whole-face motion with no SwiftUI layout tick for each pose.
struct BotNotchFaceMotion: NSViewRepresentable {
    let face: BotFaceMark
    let cue: Int

    func makeNSView(context: Context) -> Host { Host(size: face.size) }

    func updateNSView(_ view: Host, context: Context) {
        let environment = context.environment
        view.face.rootView = AnyView(face.environment(\.self, environment))
        let motion = BotStatusMotion(mood: face.mood ?? .idle)
        let enabled =
            environment.dockHostVisible && !environment.dockHostResizing
            && DockMotion.isEnabled(reduceMotion: environment.accessibilityReduceMotion)
        view.apply(enabled ? motion : .resting, cue: cue)
    }

    static func dismantleNSView(_ view: Host, coordinator: ()) { view.apply(.resting, cue: 0) }

    final class Host: NSView {
        let face = NSHostingView(rootView: AnyView(EmptyView()))
        private let size: CGFloat
        private var motion = BotStatusMotion.resting
        private var cue = 0
        private var activitySignature: [String]?
        private var activityVariation = 0
        private static let animationKey = "bot.statusMotion"
        private static let reactionKey = "bot.activityReaction"

        init(size: CGFloat) {
            self.size = size
            let canvas = size * 1.4
            super.init(frame: NSRect(x: 0, y: 0, width: canvas, height: canvas))
            wantsLayer = true
            clipsToBounds = false
            face.frame = bounds
            face.autoresizingMask = [.width, .height]
            face.sizingOptions = []
            face.wantsLayer = true
            addSubview(face)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func apply(_ motion: BotStatusMotion, cue: Int) {
            let newResult = motion == .finished && cue > self.cue
            self.cue = cue
            guard motion != self.motion || newResult, let layer = face.layer else { return }
            self.motion = motion
            layer.removeAnimation(forKey: Self.animationKey)
            layer.removeAnimation(forKey: Self.reactionKey)
            if let animation = Self.loop(motion, size: size, cue: cue, layer: layer) {
                layer.add(animation, forKey: Self.animationKey)
            }
        }

        func applyWorking(enabled: Bool, signature: [String]) {
            let changed = activitySignature.map { $0 != signature } ?? false
            activitySignature = signature
            let wasMoving = motion == .working
            apply(enabled ? .working : .resting, cue: 0)
            guard enabled, wasMoving, changed, let layer = face.layer,
                let stride = Self.loop(.working, size: size, cue: 0, layer: layer)
            else { return }

            activityVariation = (activityVariation + 1) % 3
            let reaction = CAKeyframeAnimation(keyPath: "transform")
            let duration = BotWorkingPose.reactionDuration
            let steps = Int((duration * 30).rounded())
            let start = layer.presentation()?.transform ?? layer.transform
            reaction.values =
                [NSValue(caTransform3D: start)]
                + (1...steps).map { step in
                    let time = duration * Double(step) / Double(steps)
                    let pose = BotWorkingPose.reaction(at: time, variation: activityVariation)
                    return Self.transform(pose, size: size, layer: layer)
                }
            reaction.duration = duration
            stride.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + duration
            layer.add(stride, forKey: Self.animationKey)
            layer.add(reaction, forKey: Self.reactionKey)
        }

        static func loop(_ motion: BotStatusMotion, size: CGFloat, cue: Int, layer: CALayer) -> CAKeyframeAnimation? {
            let (period, movingDuration): (TimeInterval, TimeInterval)
            switch motion {
            case .working: (period, movingDuration) = (BotWorkingPose.stridePeriod, BotWorkingPose.strideDuration)
            case .blocked:
                (period, movingDuration) = (BotStatusMotion.blockedShakePeriod, BotStatusMotion.blockedShakeDuration)
            case .finished:
                (period, movingDuration) = (BotStatusMotion.finishedNudgePeriod, BotWorkingPose.reactionDuration)
            case .resting: return nil
            }
            let steps = Int((movingDuration * 30).rounded())
            let times = (0...steps).map { movingDuration * Double($0) / Double(steps) } + [period]
            let animation = CAKeyframeAnimation(keyPath: "transform")
            animation.keyTimes = times.map { NSNumber(value: $0 / period) }
            animation.values = times.map { time in
                let pose = time < movingDuration ? motion.pose(at: time, variation: cue, live: true) : .rest
                return transform(pose, size: size, layer: layer)
            }
            animation.duration = period
            animation.repeatCount = .infinity
            return animation
        }

        private static func transform(_ pose: BotWorkingPose, size: CGFloat, layer: CALayer) -> NSValue {
            let direction: CGFloat = layer.superlayer?.isGeometryFlipped == true ? -1 : 1
            let center = CGPoint(
                x: (0.5 - layer.anchorPoint.x) * layer.bounds.width,
                y: (0.5 - layer.anchorPoint.y) * layer.bounds.height)
            let transform = CGAffineTransform(
                translationX: center.x + size * pose.reach,
                y: center.y + direction * size * 0.2 * pose.lift
            )
            .rotated(by: -direction * pose.rotation * .pi / 180)
            .scaledBy(x: pose.scaleX, y: pose.scaleY)
            .translatedBy(x: -center.x, y: -center.y)
            return NSValue(caTransform3D: CATransform3DMakeAffineTransform(transform))
        }
    }
}

struct BotWorkingAvatarLayer: NSViewRepresentable {
    let avatar: BotAvatarView
    let size: CGFloat
    let signature: [String]
    let engaged: Bool

    func makeNSView(context: Context) -> BotNotchFaceMotion.Host { .init(size: size) }

    func updateNSView(_ view: BotNotchFaceMotion.Host, context: Context) {
        let environment = context.environment
        view.face.rootView = AnyView(
            avatar
                .environment(\.dockBotIndicatorFrame, nil)
                .environment(\.dockBotIndicatorLive, false)
                .environment(\.self, environment))
        let enabled =
            engaged && environment.dockHostVisible && !environment.dockHostResizing
            && DockMotion.isEnabled(reduceMotion: environment.accessibilityReduceMotion)
        view.applyWorking(enabled: enabled, signature: signature)
    }

    static func dismantleNSView(_ view: BotNotchFaceMotion.Host, coordinator: ()) { view.apply(.resting, cue: 0) }
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
    func botStatusMotion(_ motion: BotStatusMotion, size: CGFloat, live: Bool = false) -> some View {
        modifier(BotStatusMotionModifier(motion: motion, size: size, live: live))
    }
}

private struct BotStatusMotionModifier: ViewModifier {
    let motion: BotStatusMotion
    let size: CGFloat
    let live: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dockHostVisible) private var hostVisible
    @Environment(\.dockHostResizing) private var hostResizing
    @State private var hopAt: Date?

    private var moves: Bool {
        hostVisible && !hostResizing && DockMotion.isEnabled(reduceMotion: reduceMotion)
    }

    func body(content: Content) -> some View {
        Group {
            if motion.loops(live: live) {
                BotStatusArtwork(content: content, size: size, motion: moves ? motion : .resting)
                    .frame(width: size, height: size)
                    .id(size)
            } else if let hopAt, moves {
                TimelineView(.dockMotion(rate: 30)) { context in
                    BotWorkingPose.reaction(at: context.date.timeIntervalSince(hopAt), variation: 0)
                        .applied(to: content, size: size)
                }
            } else {
                content
            }
        }
        .onChange(of: motion) { old, new in
            if new == .finished, old != .finished, !live { hop() }
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

/// Only the face's own expression clock remains in SwiftUI. The surrounding reach and shake are composited.
private struct BotStatusArtwork<Artwork: View>: NSViewRepresentable {
    let content: Artwork
    let size: CGFloat
    let motion: BotStatusMotion

    func makeNSView(context: Context) -> BotNotchFaceMotion.Host { .init(size: size) }

    func updateNSView(_ view: BotNotchFaceMotion.Host, context: Context) {
        view.face.rootView = AnyView(content.environment(\.self, context.environment))
        view.apply(motion, cue: 0)
    }

    static func dismantleNSView(_ view: BotNotchFaceMotion.Host, coordinator: ()) { view.apply(.resting, cue: 0) }
}
