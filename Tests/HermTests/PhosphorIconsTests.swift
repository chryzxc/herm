import AppKit
import CoreGraphics
import Testing
@testable import Herm

struct PhosphorIconsTests {
    @Test func everyIconPathParsesInsideTheGrid() {
        let grid = CGRect(x: -1, y: -1, width: 258, height: 258)
        for icon in Ph.allCases {
            let bounds = icon.cgPath(.regular).boundingBoxOfPath
            #expect(!bounds.isEmpty && grid.contains(bounds), "\(icon)")
            if icon.fillPath != nil {
                let fill = icon.cgPath(.fill).boundingBoxOfPath
                #expect(!fill.isEmpty && grid.contains(fill), "\(icon) fill")
            }
        }
    }

    @Test func nativeMenuImagesCarryTheirAppearanceAwareInk() {
        #expect(!Ph.dotsThree.appKitMenuImage(size: 13).isTemplate)
    }

    @Test func nativeMenuImageInkTracksMenuTextAppearance() throws {
        let lightInk = try meanInkBrightness(in: .aqua)
        let darkInk = try meanInkBrightness(in: .darkAqua)

        #expect(lightInk < 0.5)
        #expect(darkInk > 0.5)
    }

    private func meanInkBrightness(in appearanceName: NSAppearance.Name) throws -> CGFloat {
        let appearance = try #require(NSAppearance(named: appearanceName))
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 16,
            pixelsHigh: 16,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        appearance.performAsCurrentDrawingAppearance {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            context.cgContext.clear(CGRect(x: 0, y: 0, width: 16, height: 16))
            Ph.dotsThree.appKitMenuImage().draw(in: CGRect(x: 0, y: 0, width: 16, height: 16))
            NSGraphicsContext.restoreGraphicsState()
        }

        var total: CGFloat = 0
        var count: CGFloat = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      color.alphaComponent > 0.1 else { continue }
                total += (color.redComponent + color.greenComponent + color.blueComponent) / 3
                count += 1
            }
        }
        return total / max(count, 1)
    }
}
