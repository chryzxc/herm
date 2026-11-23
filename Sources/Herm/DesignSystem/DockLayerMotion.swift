import AppKit
import SwiftUI

/// Decorative loops run by Core Animation in the render server. A working
/// indicator on the SwiftUI motion clock re-rendered the whole window 30 times
/// a second; these cost no SwiftUI render per frame. Colors resolve from the
/// environment, so skins and appearance changes still apply.
struct DockLayerMotion: NSViewRepresentable {
    enum Kind: Equatable {
        /// Three beads pass a highlight along a fixed track.
        case thinkingRelay
        /// Three transcript lines fold together as context is compacted.
        case compactLines
        case botStride
        /// Four mosaic tiles lift and brighten in clockwise order while work is pending.
        case loading
        case startupLogo
        /// A highlight travelling around a capsule without rotating its contents.
        case capsuleRim(period: Double, lineWidth: CGFloat)
        /// A filled dot dimming to 30% and back once per `period`.
        case breathe(period: Double)
        /// A band crossing left to right, `fraction` of the width within `clamp`.
        /// Paused, it rests 30% in. `solid` draws a flat segment instead of a soft gradient.
        case sweep(period: Double, fraction: CGFloat, clamp: ClosedRange<CGFloat>, solid: Bool = false)
        /// An edge line glowing inward; the glow swells and ebbs once per `period`. Paused, it holds full strength.
        case tide(period: Double, depth: CGFloat)
    }

    let kind: Kind
    let color: Color
    var glow: Color?
    /// Edge color for the tide, or the graphite casing of the startup logo.
    var rim: Color?
    var paused = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dockHostVisible) private var hostVisible

    @Environment(\.dockHostResizing) private var hostResizing

    static func dismantleNSView(_ view: DockLayerMotionView, coordinator: ()) {
        for layer in view.layer?.sublayers ?? [] { layer.removeAllAnimations() }
    }

    func makeNSView(context: Context) -> DockLayerMotionView { DockLayerMotionView() }

    func updateNSView(_ view: DockLayerMotionView, context: Context) {
        view.spec = .init(
            kind: kind, color: color.resolve(in: context.environment).cgColor,
            glow: glow?.resolve(in: context.environment).cgColor,
            rim: rim?.resolve(in: context.environment).cgColor,
            paused: paused || !hostVisible || hostResizing || !DockMotion.isEnabled(reduceMotion: reduceMotion))
    }
}

final class DockLayerMotionView: NSView {
    struct Spec: Equatable {
        var kind: DockLayerMotion.Kind
        var color: CGColor
        var glow: CGColor?
        var rim: CGColor?
        var paused: Bool
    }

    var spec: Spec? {
        didSet { if spec != oldValue { rebuild() } }
    }
    private var builtSize = CGSize.zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Decorative: clicks reach the row underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        if bounds.size != builtSize { rebuild() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { rebuild() }
    }

    private func rebuild() {
        guard let spec, let host = layer else { return }
        builtSize = bounds.size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        for sublayer in host.sublayers ?? [] { sublayer.removeFromSuperlayer() }
        guard bounds.width > 0, bounds.height > 0 else { return }
        let color = spec.color

        switch spec.kind {
        case .thinkingRelay:
            let diameter = min(bounds.height, bounds.width / 3)
            let travel = (bounds.width - diameter) / 2
            let first = CGRect(x: 0, y: bounds.midY - diameter / 2, width: diameter, height: diameter)
            let marks = CGMutablePath()
            for index in 0..<3 {
                marks.addEllipse(in: first.offsetBy(dx: CGFloat(index) * travel, dy: 0))
            }
            let track = CAShapeLayer()
            track.path = marks
            track.fillColor = color
            track.opacity = spec.paused ? 1 : 0.35
            host.addSublayer(track)
            if !spec.paused {
                let bead = CAShapeLayer()
                bead.fillColor = color
                let frames = [
                    first,
                    first.insetBy(dx: -travel / 2, dy: 0).offsetBy(dx: travel / 2, dy: 0),
                    first.offsetBy(dx: travel, dy: 0),
                    first.insetBy(dx: -travel / 2, dy: 0).offsetBy(dx: travel * 1.5, dy: 0),
                    first.offsetBy(dx: 2 * travel, dy: 0),
                ]
                let paths = frames.map {
                    CGPath(roundedRect: $0, cornerWidth: diameter / 2, cornerHeight: diameter / 2, transform: nil)
                }
                bead.path = paths[0]
                host.addSublayer(bead)
                let pass = CAKeyframeAnimation(keyPath: "path")
                pass.keyTimes = [0, 0.2, 0.4, 0.6, 0.8, 1]
                pass.values = paths + [paths[4]]
                pass.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: 5)
                pass.duration = 1.25
                pass.autoreverses = true
                pass.repeatCount = .infinity
                bead.add(pass, forKey: "relay")
            }

        case .compactLines:
            for (index, width) in [0.625, 0.875, 0.5].enumerated() {
                let line = CALayer()
                line.bounds.size = CGSize(width: bounds.width * CGFloat(width), height: 2)
                let start = bounds.midY + CGFloat(1 - index) * bounds.height * 0.28
                line.position = CGPoint(x: bounds.midX, y: start)
                line.cornerRadius = 1
                line.backgroundColor = color
                line.opacity = index == 1 ? 1 : 0.7
                host.addSublayer(line)
                if !spec.paused && index != 1 {
                    loop(
                        line, "position.y", from: start, to: bounds.midY, duration: 0.7,
                        autoreverses: true, timing: .easeInEaseOut)
                }
            }

        case .botStride:
            guard !spec.paused else { return }
            let width = bounds.width
            let radius = width * 0.055
            let up: CGFloat = isFlipped ? -1 : 1
            for index in 0..<3 {
                let tile = CAShapeLayer()
                tile.bounds = CGRect(x: 0, y: 0, width: radius * 2, height: radius * 2)
                let path = CGMutablePath()
                path.move(to: CGPoint(x: 0, y: radius))
                path.addLine(to: CGPoint(x: radius, y: radius * 1.48))
                path.addLine(to: CGPoint(x: radius * 2, y: radius))
                path.addLine(to: CGPoint(x: radius, y: radius * 0.52))
                path.closeSubpath()
                tile.path = path
                tile.fillColor = color
                let rest = (isFlipped ? bounds.maxY : bounds.minY) + up * width * 0.06
                tile.position = CGPoint(x: width * (0.25 + CGFloat(index) * 0.25), y: rest)
                tile.opacity = 0
                host.addSublayer(tile)

                let stride = BotWorkingPose.strideDuration / BotWorkingPose.stridePeriod
                let start = Double(index) * 0.22 * stride
                let end = start + 0.56 * stride
                let times = [0, start, (start + end) / 2, end, 1].map { NSNumber(value: $0) }
                for (key, values) in [
                    ("opacity", [0, 0, 0.85, 0, 0]),
                    ("position.y", [rest, rest, rest + up * width * 0.045, rest, rest]),
                    ("transform.scale", [1, 1, 1 + 0.045 / 0.055, 1, 1]),
                ] {
                    let motion = CAKeyframeAnimation(keyPath: key)
                    motion.values = values
                    motion.keyTimes = times
                    motion.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: 4)
                    motion.duration = BotWorkingPose.stridePeriod
                    motion.repeatCount = .infinity
                    tile.add(motion, forKey: key)
                }
            }

        case .startupLogo:
            DockStartupLogo.install(
                in: host, flipped: isFlipped, ivory: color, mint: spec.glow ?? color,
                graphite: spec.rim ?? color, paused: spec.paused)

        case .loading:
            let side = min(bounds.width, bounds.height)
            let up = isFlipped ? -side : side
            let corners: [(CGFloat, CGFloat)] = [(-1, 1), (1, 1), (1, -1), (-1, -1)]
            let period = 1.6
            for (index, corner) in corners.enumerated() {
                let tile = CALayer()
                tile.bounds.size = CGSize(width: side * 0.31, height: side * 0.31)
                tile.position = CGPoint(x: bounds.midX + corner.0 * side * 0.20, y: bounds.midY + corner.1 * up * 0.20)
                tile.cornerRadius = side * 0.04
                tile.backgroundColor = color
                host.addSublayer(tile)
                guard !spec.paused else { continue }

                let rest = tile.position.y
                let lift = CAKeyframeAnimation(keyPath: "position.y")
                lift.values = [rest + up * 0.10, rest, rest, rest + up * 0.10]
                let highlight = CAKeyframeAnimation(keyPath: "opacity")
                highlight.values = [1, 0.45, 0.45, 1]
                for animation in [lift, highlight] {
                    animation.keyTimes = [0, 0.25, 0.75, 1]
                    animation.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: 3)
                    animation.duration = period
                    animation.repeatCount = .infinity
                    animation.timeOffset = period * Double((4 - index) % 4) / 4
                    tile.add(animation, forKey: animation.keyPath)
                }
            }

        case .capsuleRim(let period, let lineWidth):
            let rect = bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
            let radius = min(rect.width, rect.height) / 2
            let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
            let perimeter = 2 * (rect.width + rect.height - 4 * radius) + 2 * .pi * radius
            let track = ring(path, lineWidth: lineWidth, color: color.copy(alpha: color.alpha * 0.2) ?? color)
            let highlight = ring(path, lineWidth: lineWidth, color: color)
            if let glow = spec.glow {
                highlight.shadowColor = glow
                highlight.shadowOpacity = 0.6
                highlight.shadowRadius = 2
                highlight.shadowOffset = .zero
            }
            highlight.lineDashPattern = [NSNumber(value: perimeter * 0.22), NSNumber(value: perimeter * 0.78)]
            host.addSublayer(track)
            host.addSublayer(highlight)
            if !spec.paused {
                loop(highlight, "lineDashPhase", from: 0, to: -perimeter, duration: period)
            }

        case .breathe(let period):
            let dot = CAShapeLayer()
            dot.frame = bounds
            dot.path = CGPath(ellipseIn: bounds, transform: nil)
            dot.fillColor = color
            if let glow = spec.glow {
                dot.shadowColor = glow
                dot.shadowOpacity = 1
                dot.shadowRadius = 3
                dot.shadowOffset = .zero
                dot.shadowPath = dot.path
            }
            host.addSublayer(dot)
            if !spec.paused {
                loop(dot, "opacity", from: 1, to: 0.3, duration: period / 2, autoreverses: true, timing: .easeInEaseOut)
            }

        case .sweep(let period, let fraction, let clamp, let solid):
            let width = min(max(bounds.width * fraction, clamp.lowerBound), clamp.upperBound)
            let band = CAGradientLayer()
            band.bounds = CGRect(x: 0, y: 0, width: width, height: bounds.height)
            band.position = CGPoint(x: bounds.width * 0.3 + width / 2, y: bounds.midY)
            band.startPoint = CGPoint(x: 0, y: 0.5)
            band.endPoint = CGPoint(x: 1, y: 0.5)
            let clear = color.copy(alpha: 0) ?? color
            band.colors = solid ? [color, color] : [clear, color, clear]
            band.cornerRadius = solid ? bounds.height / 2 : 0
            host.addSublayer(band)
            if !spec.paused {
                loop(band, "position.x", from: -width / 2, to: bounds.width + width / 2, duration: period)
            }

        case .tide(let period, let depth):
            // Gradients fading inward from each side; a blurred shadow of a thin line diffused to nothing.
            let edge = CALayer()
            edge.frame = bounds
            let glow = spec.glow ?? color
            let clear = glow.copy(alpha: 0) ?? glow
            let sides: [(CGRect, CGPoint, CGPoint)] = [
                (CGRect(x: 0, y: 0, width: bounds.width, height: depth), CGPoint(x: 0.5, y: 0), CGPoint(x: 0.5, y: 1)),
                (
                    CGRect(x: 0, y: bounds.height - depth, width: bounds.width, height: depth),
                    CGPoint(x: 0.5, y: 1), CGPoint(x: 0.5, y: 0)
                ),
                (CGRect(x: 0, y: 0, width: depth, height: bounds.height), CGPoint(x: 0, y: 0.5), CGPoint(x: 1, y: 0.5)),
                (
                    CGRect(x: bounds.width - depth, y: 0, width: depth, height: bounds.height),
                    CGPoint(x: 1, y: 0.5), CGPoint(x: 0, y: 0.5)
                ),
            ]
            for (frame, start, end) in sides {
                let side = CAGradientLayer()
                side.frame = frame
                side.colors = [glow, clear]
                side.startPoint = start
                side.endPoint = end
                edge.addSublayer(side)
            }
            host.addSublayer(edge)
            // The line holds steady over the breathing glow; only the glow depends on the page's colors.
            if let rim = spec.rim {
                let rimPath = CGPath(rect: bounds.insetBy(dx: 3, dy: 3), transform: nil)
                let hairline = ring(rimPath, lineWidth: 1, color: rim)
                hairline.lineCap = .butt
                host.addSublayer(hairline)
            }
            let linePath = CGPath(rect: bounds.insetBy(dx: 1.25, dy: 1.25), transform: nil)
            let line = ring(linePath, lineWidth: 2.5, color: color)
            line.lineCap = .butt
            host.addSublayer(line)
            if !spec.paused {
                loop(
                    edge, "opacity", from: 1, to: 0.35, duration: period / 2, autoreverses: true,
                    timing: .easeInEaseOut)
            }
        }
    }

    /// Each piece arrives in order, holds its reading position, then resets together.
    private func ring(_ path: CGPath, lineWidth: CGFloat, color: CGColor) -> CAShapeLayer {
        let ring = CAShapeLayer()
        ring.frame = bounds
        ring.path = path
        ring.fillColor = nil
        ring.strokeColor = color
        ring.lineWidth = lineWidth
        ring.lineCap = .round
        return ring
    }

    /// Phase comes from the media clock, so every copy of an indicator moves in step.
    private func loop(
        _ layer: CALayer, _ keyPath: String, from: Double, to: Double, duration: Double,
        autoreverses: Bool = false, timing: CAMediaTimingFunctionName = .linear
    ) {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.autoreverses = autoreverses
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: timing)
        animation.isRemovedOnCompletion = false
        let cycle = autoreverses ? duration * 2 : duration
        animation.timeOffset = CACurrentMediaTime().truncatingRemainder(dividingBy: cycle)
        layer.add(animation, forKey: keyPath)
    }
}
