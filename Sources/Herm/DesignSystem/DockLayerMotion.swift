import AppKit
import SwiftUI

/// Decorative loops run by Core Animation in the render server. A working
/// indicator on the SwiftUI motion clock re-rendered the whole window 30 times
/// a second; these cost no SwiftUI render per frame. Colors resolve from the
/// environment, so skins and appearance changes still apply.
struct DockLayerMotion: NSViewRepresentable {
    enum Kind: Equatable {
        /// A 70% arc turning clockwise over a faint ring.
        case spin(period: Double, lineWidth: CGFloat)
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
    /// Tide only: a hairline inside the edge line, so it separates from whatever is underneath.
    var rim: Color?
    var paused = false

    func makeNSView(context: Context) -> DockLayerMotionView { DockLayerMotionView() }

    func updateNSView(_ view: DockLayerMotionView, context: Context) {
        view.spec = .init(
            kind: kind, color: color.resolve(in: context.environment).cgColor,
            glow: glow?.resolve(in: context.environment).cgColor,
            rim: rim?.resolve(in: context.environment).cgColor, paused: paused)
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
        case .spin(let period, let lineWidth):
            let path = CGPath(ellipseIn: bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2), transform: nil)
            let track = ring(path, lineWidth: lineWidth, color: color.copy(alpha: color.alpha * 0.25) ?? color)
            let arc = ring(path, lineWidth: lineWidth, color: color)
            arc.strokeEnd = 0.7
            host.addSublayer(track)
            host.addSublayer(arc)
            // Negative turns clockwise in AppKit's y-up layer space.
            if !spec.paused { loop(arc, "transform.rotation.z", from: 0, to: -2 * Double.pi, duration: period) }

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
