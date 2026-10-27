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
    }

    let kind: Kind
    let color: Color
    var glow: Color?
    var paused = false

    func makeNSView(context: Context) -> DockLayerMotionView { DockLayerMotionView() }

    func updateNSView(_ view: DockLayerMotionView, context: Context) {
        view.spec = .init(
            kind: kind, color: color.resolve(in: context.environment).cgColor,
            glow: glow?.resolve(in: context.environment).cgColor, paused: paused)
    }
}

final class DockLayerMotionView: NSView {
    struct Spec: Equatable {
        var kind: DockLayerMotion.Kind
        var color: CGColor
        var glow: CGColor?
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
