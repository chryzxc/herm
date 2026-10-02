// Draws Herm's app icon (a gradient "h" under a notch on a black tile) as a 1024px PNG.
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

/// Fills `path` with a vertical gradient spanning `box` (y grows downward in this canvas).
func fill(_ ctx: CGContext, _ path: CGPath, _ colors: [CGColor], over box: CGRect? = nil) {
    let box = box ?? path.boundingBoxOfPath
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.drawLinearGradient(gradient(colors), start: CGPoint(x: box.midX, y: box.minY), end: CGPoint(x: box.midX, y: box.maxY), options: [])
    ctx.restoreGState()
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
ctx.setFillColor(color(0x141416))
ctx.fillPath()
ctx.restoreGState()
fill(ctx, tile, [color(0x202024), color(0x0A0A0B)])

// Soft glow behind the letter and a thin highlight on the tile edge.
ctx.saveGState()
ctx.addPath(tile)
ctx.clip()
ctx.drawRadialGradient(gradient([color(0x2FC1E8, 0.18), color(0x2FC1E8, 0)]),
                       startCenter: CGPoint(x: 512, y: 540), startRadius: 0,
                       endCenter: CGPoint(x: 512, y: 540), endRadius: 400, options: [])
ctx.restoreGState()
ctx.addPath(CGPath(roundedRect: tileRect.insetBy(dx: 1.5, dy: 1.5), cornerWidth: 184, cornerHeight: 184, transform: nil))
ctx.setStrokeColor(color(0xFFFFFF, 0.12))
ctx.setLineWidth(3)
ctx.strokePath()

// The mark: a lowercase "h" — a stem plus an arch, filled with one shared gradient.
let stroke: CGFloat = 132
let stem = CGMutablePath()
stem.move(to: CGPoint(x: 400, y: 300))
stem.addLine(to: CGPoint(x: 400, y: 724))
let arch = CGMutablePath()
arch.move(to: CGPoint(x: 400, y: 600))
arch.addCurve(to: CGPoint(x: 624, y: 560), control1: CGPoint(x: 400, y: 430), control2: CGPoint(x: 624, y: 400))
arch.addLine(to: CGPoint(x: 624, y: 724))
let letterBox = CGRect(x: 334, y: 234, width: 356, height: 556)
let letterColors = [color(0x7CF2C9), color(0x2FC1E8), color(0x6C63FF)]
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 30, color: color(0x000000, 0.5))
ctx.beginTransparencyLayer(auxiliaryInfo: nil)
for part in [stem, arch] {
    fill(ctx, part.copy(strokingWithWidth: stroke, lineCap: .round, lineJoin: .round, miterLimit: 10), letterColors, over: letterBox)
}
ctx.endTransparencyLayer()
ctx.restoreGState()

// The MacBook notch bitten out of the top edge, with a green status light.
let notchRect = CGRect(x: 402, y: 100, width: 220, height: 64)
let notch = CGMutablePath()
notch.move(to: CGPoint(x: notchRect.minX, y: notchRect.minY))
notch.addLine(to: CGPoint(x: notchRect.maxX, y: notchRect.minY))
notch.addArc(tangent1End: CGPoint(x: notchRect.maxX, y: notchRect.maxY), tangent2End: CGPoint(x: notchRect.minX, y: notchRect.maxY), radius: 30)
notch.addArc(tangent1End: CGPoint(x: notchRect.minX, y: notchRect.maxY), tangent2End: CGPoint(x: notchRect.minX, y: notchRect.minY), radius: 30)
notch.closeSubpath()
ctx.addPath(notch)
ctx.setFillColor(color(0x000000))
ctx.fillPath()

ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 18, color: color(0x7CF2C9))
ctx.setFillColor(color(0x7CF2C9))
ctx.fillEllipse(in: CGRect(x: 584, y: 122, width: 18, height: 18))
ctx.restoreGState()

try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
