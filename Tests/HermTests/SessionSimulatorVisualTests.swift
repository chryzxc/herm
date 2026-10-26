import AppKit
import SwiftUI
import Testing

@testable import Herm

@MainActor
struct SessionSimulatorVisualTests {
    @Test func renderDirectTabReference() throws {
        guard let framePath = ProcessInfo.processInfo.environment["HERM_SIMULATOR_PREVIEW_IMAGE"] else { return }
        let frame = try Data(contentsOf: URL(fileURLWithPath: framePath))
        let directory = URL(fileURLWithPath: "/tmp/herm-direct-preview")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let previous = DockThemeRuntime.current
        defer { DockThemeRuntime.current = previous }
        DockThemeRuntime.current = .clean
        let dark = ProcessInfo.processInfo.environment["HERM_SIMULATOR_PREVIEW_DARK"] == "1"
        for width: CGFloat in [320, 600] {
            for connected in [true, false] {
                let capture = SessionSimulatorCapture()
                capture.receive(kind: 74, data: Data(#"{"devices":[{"id":"test","name":"Pixel 10 Pro XL"}]}"#.utf8))
                if connected { capture.receive(kind: 73, data: frame) }
                let root = SessionSimulatorView(
                    platform: .android, sessionKey: "visual-fixture", isActive: false, capture: capture
                )
                .presentation
                .frame(width: width, height: 720)
                .environment(\.colorScheme, dark ? .dark : .light)
                let host = NSHostingView(rootView: root)
                host.frame = CGRect(x: 0, y: 0, width: width, height: 720)
                host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                host.layoutSubtreeIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let data = try #require(bitmap.representation(using: .png, properties: [:]))
                try data.write(
                    to: directory.appendingPathComponent("\(Int(width))-\(connected)-\(dark ? "dark" : "light").png"))
                #expect(host.fittingSize.width <= width + 1)
            }
        }
    }
}
