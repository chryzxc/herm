import AppKit
import SwiftUI
import Testing

@testable import Herm

@MainActor
struct DeliverySkinReproductionTests {
    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua, .vibrantDark])
    func lightSkinSpecimenKeepsItsPaperInDarkHosts(appearance: NSAppearance.Name) async throws {
        _ = NSApplication.shared
        let content = DockSkinSpecimen(theme: .notebook).frame(width: 224)
            .environment(\.colorScheme, appearance == .aqua ? .light : .dark)
        let host = NSHostingView(rootView: content)
        host.frame = NSRect(x: 0, y: 0, width: 224, height: 148)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        for _ in 0..<3 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
        }
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let color = try #require(
            bitmap.colorAt(x: bitmap.pixelsWide - 16, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        #expect(color.redComponent > 0.6, "Notebook paper must remain recognizable under \(appearance.rawValue)")
        #expect(color.greenComponent > 0.6)
    }
}
