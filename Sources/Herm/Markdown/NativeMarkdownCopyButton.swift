import AppKit
import SwiftUI

/// The code block copy control, drawn with layers instead of hosting
/// `DockCopyButton`. A hosted SwiftUI view re-renders whenever its position in
/// the window changes, so one per code block made every transcript scroll tick
/// run a SwiftUI update per block. This matches `DockCopyButton`'s `.icon`
/// presentation: the copy glyph shrinks away while the check draws on, then
/// both return after the confirmation interval.
@MainActor
final class NativeMarkdownCopyButton: NSButton {
    static let confirmationInterval: TimeInterval = 1.5
    private static let accessibilityTitle = "Copy code"

    private let glyphLayer = CAShapeLayer()
    private let checkStrokeLayer = CAShapeLayer()
    private let checkFillLayer = CAShapeLayer()
    private var iconSize: CGFloat = 13
    private var iconColor = NSColor(Color.dockSecondaryText)
    private var confirmationColor = NSColor(Color.dockSuccess)
    private(set) var isShowingConfirmation = false
    var onCopy: (() -> Void)?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = ""
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .noImage
        setButtonType(.momentaryChange)
        wantsLayer = true
        target = self
        action = #selector(performCopy)
        toolTip = Self.accessibilityTitle
        setAccessibilityLabel(Self.accessibilityTitle)
        // The real scale arrives with the window; asking `NSScreen` here
        // costs a window server round trip per code block mount.
        for shape in [glyphLayer, checkStrokeLayer, checkFillLayer] {
            shape.contentsScale = 2
            layer?.addSublayer(shape)
        }
        checkStrokeLayer.fillColor = nil
        checkStrokeLayer.lineCap = .round
        checkStrokeLayer.lineJoin = .round
        checkStrokeLayer.strokeEnd = 0
        checkFillLayer.opacity = 0
        applyColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(iconSize: CGFloat, color: NSColor, confirmationColor: NSColor) {
        self.iconSize = iconSize
        iconColor = color
        self.confirmationColor = confirmationColor
        applyColors()
        needsLayout = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        applyBackingScale()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyBackingScale()
    }

    private func applyBackingScale() {
        guard let scale = window?.backingScaleFactor, scale != glyphLayer.contentsScale else { return }
        for shape in [glyphLayer, checkStrokeLayer, checkFillLayer] { shape.contentsScale = scale }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let rect = CGRect(
            x: floor((bounds.width - iconSize) / 2), y: floor((bounds.height - iconSize) / 2),
            width: iconSize, height: iconSize)
        for shape in [glyphLayer, checkStrokeLayer, checkFillLayer] {
            shape.frame = rect
            shape.bounds = CGRect(origin: .zero, size: rect.size)
        }
        glyphLayer.path = Self.path(.copy, size: iconSize)
        checkStrokeLayer.path = Self.path(.check, size: iconSize)
        checkFillLayer.path = checkStrokeLayer.path
        checkStrokeLayer.lineWidth = max(0.6, iconSize / 18)
        CATransaction.commit()
    }

    /// Glyph path in a flipped `size` square, scaled like `PhosphorShape`.
    static func path(_ icon: Ph, size: CGFloat) -> CGPath {
        var transform = CGAffineTransform(scaleX: size / 256, y: size / 256)
        return icon.cgPath().copy(using: &transform) ?? icon.cgPath()
    }

    @objc private func performCopy() {
        onCopy?()
        setConfirmation(true)
    }

    /// Shows or clears the copied check. The owner clears it after
    /// `confirmationInterval` so it can track the active interaction.
    func setConfirmation(_ shown: Bool) {
        guard shown != isShowingConfirmation else { return }
        isShowingConfirmation = shown
        toolTip = shown ? "Copied" : Self.accessibilityTitle
        setAccessibilityValue(shown ? "Copied" : "")
        let animates = DockMotion.isEnabled(
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        // The glyph shrinks toward the top trailing corner as it fades.
        var glyphTransform = CATransform3DIdentity
        if shown {
            glyphTransform = CATransform3DTranslate(glyphTransform, 3, -3, 0)
            glyphTransform = CATransform3DTranslate(glyphTransform, iconSize / 2, iconSize / 2, 0)
            glyphTransform = CATransform3DScale(glyphTransform, 0.8, 0.8, 1)
            glyphTransform = CATransform3DTranslate(glyphTransform, -iconSize / 2, -iconSize / 2, 0)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let glyphOpacity: Float = shown ? 0 : 1
        let strokeEnd: CGFloat = shown ? 1 : 0
        let fillOpacity: Float = shown ? 1 : 0
        if animates {
            animate(glyphLayer, "opacity", to: glyphOpacity, duration: 0.18, timing: .easeInEaseOut)
            animate(glyphLayer, "transform", to: glyphTransform, duration: 0.18, timing: .easeInEaseOut)
            animate(checkStrokeLayer, "strokeEnd", to: strokeEnd, duration: 0.32, timing: .easeOut)
            animate(
                checkFillLayer, "opacity", to: fillOpacity, duration: 0.16, timing: .easeIn, delay: shown ? 0.2 : 0)
        }
        glyphLayer.opacity = glyphOpacity
        glyphLayer.transform = glyphTransform
        checkStrokeLayer.strokeEnd = strokeEnd
        checkFillLayer.opacity = fillOpacity
        CATransaction.commit()
    }

    private func animate(
        _ target: CALayer, _ keyPath: String, to value: Any, duration: CFTimeInterval,
        timing: CAMediaTimingFunctionName, delay: CFTimeInterval = 0
    ) {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = target.presentation()?.value(forKeyPath: keyPath) ?? target.value(forKeyPath: keyPath)
        animation.toValue = value
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: timing)
        if delay > 0 {
            animation.beginTime = CACurrentMediaTime() + delay
            animation.fillMode = .backwards
        }
        target.add(animation, forKey: keyPath)
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            glyphLayer.fillColor = iconColor.cgColor
            checkStrokeLayer.strokeColor = confirmationColor.cgColor
            checkFillLayer.fillColor = confirmationColor.cgColor
            CATransaction.commit()
        }
    }
}
