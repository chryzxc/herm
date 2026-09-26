import AppKit
import SwiftUI

/// The app's icon view. Phosphor (`PhosphorIcons.swift`) is the only icon
/// family; views never instantiate SF Symbols or other icon sets.
///
/// Without `size`, the icon sizes like an SF Symbol: one em of the inherited
/// `.font`, so `.font(.system(size: 13))` sizes it the way it sized symbols.
struct DockIcon: View {
    enum Weight { case regular, fill }

    /// Phosphor glyphs sit inside padding on their grid. This scale gives them
    /// roughly the optical size an SF Symbol had at the same font size.
    static let fontScale: CGFloat = 1.15

    let icon: Ph
    var size: CGFloat?
    var weight: Weight
    var color: Color?

    init(_ icon: Ph, size: CGFloat? = nil, weight: Weight = .regular, color: Color? = nil) {
        self.icon = icon
        self.size = size
        self.weight = weight
        self.color = color
    }

    var body: some View {
        if let color {
            glyph.foregroundStyle(color)
        } else {
            glyph
        }
    }

    @ViewBuilder private var glyph: some View {
        let shape = PhosphorShape(icon: icon, weight: weight)
        if let size {
            shape.frame(width: size, height: size).accessibilityHidden(true)
        } else {
            Text(verbatim: "\u{2003}")
                .hidden()
                .overlay { shape.scaleEffect(Self.fontScale) }
                .accessibilityHidden(true)
        }
    }
}

/// Icon-and-text control content with a fixed 16pt icon.
struct DockIconLabel: View {
    let title: String
    let icon: Ph
    var iconColor: Color = .dockMetadataText

    init(_ title: String, icon: Ph, iconColor: Color = .dockMetadataText) {
        self.title = title
        self.icon = icon
        self.iconColor = iconColor
    }

    var body: some View {
        HStack(spacing: 6) {
            DockIcon(icon, size: 16, color: iconColor)
            Text(title)
        }
    }
}

extension Ph {
    func cgPath(_ weight: DockIcon.Weight = .regular) -> CGPath {
        PhosphorPathParser.parse(weight == .fill ? fillPath ?? regularPath : regularPath)
    }

    /// Fixed-size template image for menus and `Label`s, where SwiftUI only
    /// renders `Image` icons.
    func image(size: CGFloat = 16, weight: DockIcon.Weight = .regular) -> Image {
        let path = cgPath(weight)
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.scaleBy(x: rect.width / 256, y: rect.height / 256)
            context.addPath(path)
            context.setFillColor(NSColor.black.cgColor)
            context.fillPath()
            return true
        }
        image.isTemplate = true
        return Image(nsImage: image).renderingMode(.template)
    }
}

struct PhosphorShape: Shape {
    let icon: Ph
    var weight: DockIcon.Weight = .regular

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 256
        let transform = CGAffineTransform(translationX: rect.midX - 128 * scale, y: rect.midY - 128 * scale)
            .scaledBy(x: scale, y: scale)
        return Path(icon.cgPath(weight)).applying(transform)
    }
}

extension Label where Title == Text, Icon == Image {
    init(_ title: some StringProtocol, icon: Ph) {
        self.init { Text(title) } icon: { icon.image() }
    }
}

extension Button where Label == SwiftUI.Label<Text, Image> {
    init(_ title: some StringProtocol, icon: Ph, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.init(role: role, action: action) { SwiftUI.Label(title, icon: icon) }
    }
}

extension Menu where Label == SwiftUI.Label<Text, Image> {
    init(_ title: some StringProtocol, icon: Ph, @ViewBuilder content: () -> Content) {
        self.init(content: content) { SwiftUI.Label(title, icon: icon) }
    }
}

/// Parses the SVG path subset Phosphor uses (all commands, absolute and
/// relative) into a `CGPath` on the icon's 256x256 grid.
enum PhosphorPathParser {
    static func parse(_ data: String) -> CGPath {
        let path = CGMutablePath()
        var tokens = Tokens(bytes: Array(data.utf8))
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        var lastCubicControl: CGPoint?
        var lastQuadControl: CGPoint?
        var command: UInt8 = 0

        while tokens.hasMore {
            if let next = tokens.command() {
                command = next
            } else if command == 0 || command | 0x20 == UInt8(ascii: "z") {
                break
            }
            let relative = command >= UInt8(ascii: "a")
            let origin = relative ? current : .zero
            func point() -> CGPoint? {
                guard let x = tokens.number(), let y = tokens.number() else { return nil }
                return CGPoint(x: origin.x + x, y: origin.y + y)
            }
            var cubicControl: CGPoint?
            var quadControl: CGPoint?

            switch command | 0x20 {
            case UInt8(ascii: "m"):
                guard let p = point() else { return path }
                path.move(to: p)
                current = p
                subpathStart = p
                command = relative ? UInt8(ascii: "l") : UInt8(ascii: "L")
            case UInt8(ascii: "l"):
                guard let p = point() else { return path }
                path.addLine(to: p)
                current = p
            case UInt8(ascii: "h"):
                guard let x = tokens.number() else { return path }
                current = CGPoint(x: origin.x + x, y: current.y)
                path.addLine(to: current)
            case UInt8(ascii: "v"):
                guard let y = tokens.number() else { return path }
                current = CGPoint(x: current.x, y: origin.y + y)
                path.addLine(to: current)
            case UInt8(ascii: "c"):
                guard let c1 = point(), let c2 = point(), let p = point() else { return path }
                path.addCurve(to: p, control1: c1, control2: c2)
                cubicControl = c2
                current = p
            case UInt8(ascii: "s"):
                guard let c2 = point(), let p = point() else { return path }
                let c1 = lastCubicControl.map { reflect($0, around: current) } ?? current
                path.addCurve(to: p, control1: c1, control2: c2)
                cubicControl = c2
                current = p
            case UInt8(ascii: "q"):
                guard let c = point(), let p = point() else { return path }
                path.addQuadCurve(to: p, control: c)
                quadControl = c
                current = p
            case UInt8(ascii: "t"):
                guard let p = point() else { return path }
                let c = lastQuadControl.map { reflect($0, around: current) } ?? current
                path.addQuadCurve(to: p, control: c)
                quadControl = c
                current = p
            case UInt8(ascii: "a"):
                guard let rx = tokens.number(), let ry = tokens.number(), let rotation = tokens.number(),
                      let largeArc = tokens.number(), let sweep = tokens.number(), let p = point() else { return path }
                addArc(to: path, from: current, to: p, radii: CGSize(width: rx, height: ry),
                       rotation: rotation, largeArc: largeArc != 0, sweep: sweep != 0)
                current = p
            case UInt8(ascii: "z"):
                path.closeSubpath()
                current = subpathStart
            default:
                return path
            }
            lastCubicControl = cubicControl
            lastQuadControl = quadControl
        }
        return path
    }

    private static func reflect(_ point: CGPoint, around center: CGPoint) -> CGPoint {
        CGPoint(x: 2 * center.x - point.x, y: 2 * center.y - point.y)
    }

    /// SVG endpoint arc to cubic Béziers (SVG spec, appendix F.6).
    private static func addArc(to path: CGMutablePath, from start: CGPoint, to end: CGPoint, radii: CGSize,
                               rotation: CGFloat, largeArc: Bool, sweep: Bool) {
        guard start != end else { return }
        var rx = abs(radii.width)
        var ry = abs(radii.height)
        guard rx > 0, ry > 0 else {
            path.addLine(to: end)
            return
        }
        let phi = rotation * .pi / 180
        let cosPhi = cos(phi)
        let sinPhi = sin(phi)
        let dx = (start.x - end.x) / 2
        let dy = (start.y - end.y) / 2
        let x1 = cosPhi * dx + sinPhi * dy
        let y1 = -sinPhi * dx + cosPhi * dy
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 {
            rx *= lambda.squareRoot()
            ry *= lambda.squareRoot()
        }
        let numerator = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let denominator = rx * rx * y1 * y1 + ry * ry * x1 * x1
        var coefficient = max(0, numerator / denominator).squareRoot()
        if largeArc == sweep { coefficient = -coefficient }
        let cx1 = coefficient * rx * y1 / ry
        let cy1 = -coefficient * ry * x1 / rx
        let center = CGPoint(x: cosPhi * cx1 - sinPhi * cy1 + (start.x + end.x) / 2,
                             y: sinPhi * cx1 + cosPhi * cy1 + (start.y + end.y) / 2)

        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            atan2(ux * vy - uy * vx, ux * vx + uy * vy)
        }
        let startAngle = angle(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry)
        var sweepAngle = angle((x1 - cx1) / rx, (y1 - cy1) / ry, (-x1 - cx1) / rx, (-y1 - cy1) / ry)
        if !sweep, sweepAngle > 0 { sweepAngle -= 2 * .pi }
        if sweep, sweepAngle < 0 { sweepAngle += 2 * .pi }

        func onEllipse(_ u: CGFloat, _ v: CGFloat) -> CGPoint {
            CGPoint(x: center.x + rx * u * cosPhi - ry * v * sinPhi,
                    y: center.y + rx * u * sinPhi + ry * v * cosPhi)
        }
        let segments = max(1, Int((abs(sweepAngle) / (.pi / 2)).rounded(.up)))
        let delta = sweepAngle / CGFloat(segments)
        let k = 4 / 3 * tan(delta / 4)
        var theta = startAngle
        for segment in 0..<segments {
            let next = theta + delta
            let control1 = onEllipse(cos(theta) - k * sin(theta), sin(theta) + k * cos(theta))
            let control2 = onEllipse(cos(next) + k * sin(next), sin(next) - k * cos(next))
            let point = segment == segments - 1 ? end : onEllipse(cos(next), sin(next))
            path.addCurve(to: point, control1: control1, control2: control2)
            theta = next
        }
    }

    private struct Tokens {
        let bytes: [UInt8]
        var index = 0

        var hasMore: Bool {
            mutating get {
                skipSeparators()
                return index < bytes.count
            }
        }

        mutating func skipSeparators() {
            while index < bytes.count, bytes[index] == UInt8(ascii: ",") || bytes[index] == UInt8(ascii: " ")
                || bytes[index] == UInt8(ascii: "\n") || bytes[index] == UInt8(ascii: "\t") {
                index += 1
            }
        }

        mutating func command() -> UInt8? {
            skipSeparators()
            guard index < bytes.count else { return nil }
            let byte = bytes[index]
            let isLetter = (byte | 0x20) >= UInt8(ascii: "a") && (byte | 0x20) <= UInt8(ascii: "z") && byte | 0x20 != UInt8(ascii: "e")
            guard isLetter else { return nil }
            index += 1
            return byte
        }

        mutating func number() -> CGFloat? {
            skipSeparators()
            let start = index
            if index < bytes.count, bytes[index] == UInt8(ascii: "-") || bytes[index] == UInt8(ascii: "+") { index += 1 }
            var sawDigit = false
            var sawDot = false
            while index < bytes.count {
                let byte = bytes[index]
                if byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") {
                    sawDigit = true
                } else if byte == UInt8(ascii: "."), !sawDot {
                    sawDot = true
                } else if byte | 0x20 == UInt8(ascii: "e"), sawDigit {
                    index += 1
                    if index < bytes.count, bytes[index] == UInt8(ascii: "-") || bytes[index] == UInt8(ascii: "+") { index += 1 }
                    sawDot = true
                    continue
                } else {
                    break
                }
                index += 1
            }
            guard sawDigit, let value = Double(String(decoding: bytes[start..<index], as: UTF8.self)) else {
                index = start
                return nil
            }
            return CGFloat(value)
        }
    }
}
