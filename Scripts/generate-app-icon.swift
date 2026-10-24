// Draws Herm's app icon (the website's off-white "H" and mint brand dot on a black tile) as a 1024px PNG.
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
fill(ctx, tile, [color(0x16171A), color(0x08090A)])

// A thin highlight on the tile edge.
ctx.addPath(CGPath(roundedRect: tileRect.insetBy(dx: 1.5, dy: 1.5), cornerWidth: 184, cornerHeight: 184, transform: nil))
ctx.setStrokeColor(color(0xFFFFFF, 0.10))
ctx.setLineWidth(3)
ctx.strokePath()

// The mark: the website's chunky "H" — two rounded stems joined by a crossbar, in soft off-white.
let stemWidth: CGFloat = 150
let mark = CGMutablePath()
mark.addPath(CGPath(roundedRect: CGRect(x: 252, y: 282, width: stemWidth, height: 460), cornerWidth: 44, cornerHeight: 44, transform: nil))
mark.addPath(CGPath(roundedRect: CGRect(x: 522, y: 282, width: stemWidth, height: 460), cornerWidth: 44, cornerHeight: 44, transform: nil))
mark.addRect(CGRect(x: 252 + stemWidth - 20, y: 448, width: 522 - 252 - stemWidth + 40, height: 124))
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 30, color: color(0x000000, 0.5))
ctx.beginTransparencyLayer(auxiliaryInfo: nil)
fill(ctx, mark, [color(0xEEF1EC), color(0xC9D1CA)])
ctx.endTransparencyLayer()
ctx.restoreGState()

// The brand period from "herm." in mint, glowing like an "agent is live" status light.
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 40, color: color(0x8FD9B6, 0.8))
ctx.setFillColor(color(0x8FD9B6))
ctx.fillEllipse(in: CGRect(x: 702, y: 652, width: 90, height: 90))
ctx.restoreGState()

try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
