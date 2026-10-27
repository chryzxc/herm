import SwiftUI

/// The presentation clock shared by every decorative leaf in an indicator block.
struct DockBotIndicatorFrame {
    let date: Date
    let moves: Bool

    func face(id: String, busy: Bool, animated: Bool = true) -> BotFacePose {
        guard moves && busy && animated else { return .rest }
        let phase = Double(BotAvatarPresentation.seed(for: id) % 1000) / 100
        return .at(date.timeIntervalSinceReferenceDate + phase, busy: busy)
    }

    /// Quantize the cosmetic sweep without slowing authoritative elapsed labels.
    var sweep: Double {
        guard moves else { return 0 }
        let tick = floor(date.timeIntervalSinceReferenceDate * 10) / 10
        return DockMotionSchedule.loop(Date(timeIntervalSinceReferenceDate: tick), period: 1.8)
    }
}

private struct DockBotIndicatorFrameKey: EnvironmentKey {
    static let defaultValue: DockBotIndicatorFrame? = nil
}

private struct DockBotIndicatorLiveKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var dockBotIndicatorFrame: DockBotIndicatorFrame? {
        get { self[DockBotIndicatorFrameKey.self] }
        set { self[DockBotIndicatorFrameKey.self] = newValue }
    }

    /// Set once by a live activity block; its avatars tick their own leaf clock.
    var dockBotIndicatorLive: Bool {
        get { self[DockBotIndicatorLiveKey.self] }
        set { self[DockBotIndicatorLiveKey.self] = newValue }
    }
}

/// An external frame bypasses the timeline entirely; standalone avatars retain a clock.
struct DockBotFrameClock<Content: View>: View {
    @Environment(\.dockBotIndicatorFrame) private var externalFrame
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var focus = HermFocus.shared
    @ViewBuilder let content: (DockBotIndicatorFrame) -> Content

    var body: some View {
        if let externalFrame {
            content(externalFrame)
        } else {
            let moves = !reduceMotion && DockThemeStyle.current.animates && focus.engaged
            TimelineView(.dockMotion(rate: 15, paused: !moves)) { context in
                let frame = DockBotIndicatorFrame(date: context.date, moves: moves)
                content(frame).environment(\.dockBotIndicatorFrame, frame)
            }
        }
    }
}

/// Membership geometry is independent of the frame date and constructed before ticking.
struct DockBotFrameReader<Content: View>: View {
    @Environment(\.dockBotIndicatorFrame) private var frame
    @ViewBuilder let content: (DockBotIndicatorFrame) -> Content

    var body: some View {
        content(frame ?? DockBotIndicatorFrame(date: .distantPast, moves: false))
    }
}

/// Membership geometry is independent of the frame date and constructed before ticking.
struct DockBotHuddleLayout {
    let centers: [CGFloat]
    let rotation: [Int]
    let inset: CGFloat
    let height: CGFloat = 56
    let leadSize: CGFloat
    let partnerSize: CGFloat

    init(partnerCount: Int, leadDone: Bool, leadSize: CGFloat = 40, partnerSize: CGFloat = 26) {
        self.leadSize = leadSize
        self.partnerSize = partnerSize
        inset = (height - leadSize) / 2
        let first: CGFloat = (56 - leadSize) / 2 + leadSize + 8 + partnerSize / 2
        let stride: CGFloat = partnerSize + 8
        let partners = (0..<partnerCount).map { first + CGFloat($0) * stride }
        centers = [height / 2] + partners
        rotation = leadDone ? Array(1..<(partnerCount + 1)) : Array(0..<(partnerCount + 1))
    }

    /// Seconds each Bot holds the thought bubble.
    static let turnLength = 2.6

    func turn(at frame: DockBotIndicatorFrame) -> (active: Int, next: Int, phase: Double) {
        // A lone working partner still thinks; a lead alone shows its own activity instead.
        guard frame.moves, !rotation.isEmpty, centers.count > 1 else { return (-1, -1, 0) }
        let clock = max(0, frame.date.timeIntervalSinceReferenceDate) / Self.turnLength
        let step = Int(clock)
        return (rotation[step % rotation.count], rotation[(step + 1) % rotation.count], clock - Double(step))
    }
}
