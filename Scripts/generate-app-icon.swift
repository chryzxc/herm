// Draws Herm's app icon (a winged notch on an indigo tile) as a 1024px PNG.
// Usage: swift Scripts/generate-app-icon.swift <output.png>
import AppKit

let size: CGFloat = 1024
let output = CommandLine.arguments.dropFirst().first ?? "icon.png"

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func gradient(_ colors: [CGColor]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)!
}

/// Fills `path` with a vertical gradient (y grows downward in this canvas).
func fill(_ ctx: CGContext, _ path: CGPath, _ colors: [CGColor]) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let box = path.boundingBoxOfPath
    ctx.drawLinearGradient(gradient(colors), start: CGPoint(x: box.midX, y: box.minY), end: CGPoint(x: box.midX, y: box.maxY), options: [])
    ctx.restoreGState()
}

/// A wing feather: rounded base at `base`, a curved leading edge sweeping to a pointed `tip`.
func feather(base: CGPoint, tip: CGPoint, width: CGFloat) -> CGPath {
    let dx = tip.x - base.x, dy = tip.y - base.y
    let length = hypot(dx, dy), angle = atan2(dy, dx), r = width / 2
    let path = CGMutablePath()
    path.move(to: CGPoint(x: 0, y: r))
    path.addArc(center: .zero, radius: r, startAngle: .pi / 2, endAngle: 3 * .pi / 2, clockwise: false)
    path.addQuadCurve(to: CGPoint(x: length, y: 0), control: CGPoint(x: length * 0.55, y: -r * 0.95))
    path.addQuadCurve(to: CGPoint(x: 0, y: r), control: CGPoint(x: length * 0.5, y: r * 1.5))
    path.closeSubpath()
    var transform = CGAffineTransform(translationX: base.x, y: base.y).rotated(by: angle).scaledBy(x: 1, y: -1)
    return path.copy(using: &transform)!
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
// Flip so the drawing code uses top-left origin coordinates.
ctx.translateBy(x: 0, y: size)
ctx.scaleBy(x: 1, y: -1)

// Tile on Apple's macOS icon grid: 824pt body, 100pt margins.
let tileRect = CGRect(x: 100, y: 100, width: 824, height: 824)
let tile = CGPath(roundedRect: tileRect, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 12), blur: 28, color: color(0x000000, 0.35))
ctx.addPath(tile)
ctx.setFillColor(color(0x15123A))
ctx.fillPath()
ctx.restoreGState()
fill(ctx, tile, [color(0x2E2A7A), color(0x16134A), color(0x0B0A22)])

// Soft glow behind the mark and a thin top highlight on the tile edge.
ctx.saveGState()
ctx.addPath(tile)
ctx.clip()
ctx.drawRadialGradient(gradient([color(0x6C63FF, 0.35), color(0x6C63FF, 0)]),
                       startCenter: CGPoint(x: 512, y: 480), startRadius: 0,
                       endCenter: CGPoint(x: 512, y: 480), endRadius: 420, options: [])
ctx.restoreGState()
ctx.addPath(CGPath(roundedRect: tileRect.insetBy(dx: 1.5, dy: 1.5), cornerWidth: 184, cornerHeight: 184, transform: nil))
ctx.setStrokeColor(color(0xFFFFFF, 0.12))
ctx.setLineWidth(3)
ctx.strokePath()

// The mark: the MacBook notch worn like Hermes' winged helmet — gold wings spread from
// both sides of a black notch with a glowing status light inside.
let notchRect = CGRect(x: 322, y: 430, width: 380, height: 170)
let notch = CGMutablePath()
notch.move(to: CGPoint(x: notchRect.minX, y: notchRect.minY))
notch.addLine(to: CGPoint(x: notchRect.maxX, y: notchRect.minY))
notch.addArc(tangent1End: CGPoint(x: notchRect.maxX, y: notchRect.maxY), tangent2End: CGPoint(x: notchRect.minX, y: notchRect.maxY), radius: 78)
notch.addArc(tangent1End: CGPoint(x: notchRect.minX, y: notchRect.maxY), tangent2End: CGPoint(x: notchRect.minX, y: notchRect.minY), radius: 78)
notch.closeSubpath()

// Left wing (feather bases tucked under the notch), mirrored for the right.
let leftWing = CGMutablePath()
leftWing.addPath(feather(base: CGPoint(x: 380, y: 470), tip: CGPoint(x: 150, y: 300), width: 96))
leftWing.addPath(feather(base: CGPoint(x: 380, y: 520), tip: CGPoint(x: 168, y: 424), width: 86))
leftWing.addPath(feather(base: CGPoint(x: 385, y: 565), tip: CGPoint(x: 212, y: 532), width: 74))
let wing = CGMutablePath()
wing.addPath(leftWing)
wing.addPath(leftWing, transform: CGAffineTransform(translationX: size, y: 0).scaledBy(x: -1, y: 1))

// Centre the mark on the tile, and draw the display edge the notch hangs from.
ctx.translateBy(x: 0, y: 70)
ctx.saveGState()
ctx.clip(to: CGRect(x: 100, y: notchRect.minY - 2, width: 824, height: 4))
ctx.drawLinearGradient(gradient([color(0xFFFFFF, 0), color(0xFFFFFF, 0.3), color(0xFFFFFF, 0)]),
                       start: CGPoint(x: 100, y: 0), end: CGPoint(x: 924, y: 0), options: [])
ctx.restoreGState()

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 24, color: color(0x000000, 0.45))
ctx.beginTransparencyLayer(auxiliaryInfo: nil)
fill(ctx, wing, [color(0xFFD978), color(0xF5A83B), color(0xE07A2E)])
fill(ctx, notch, [color(0x0A0A14), color(0x000000)])
ctx.endTransparencyLayer()
ctx.restoreGState()

// Thin rim so the notch reads against the dark tile.
ctx.addPath(notch)
ctx.setStrokeColor(color(0xFFFFFF, 0.18))
ctx.setLineWidth(4)
ctx.strokePath()

// Status light: a glowing pill inside the notch.
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 30, color: color(0x8C84FF, 0.9))
fill(ctx, CGPath(roundedRect: CGRect(x: 452, y: 498, width: 120, height: 34), cornerWidth: 17, cornerHeight: 17, transform: nil),
     [color(0xFFFFFF), color(0xC9C5FF)])
ctx.restoreGState()

try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
