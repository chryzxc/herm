import AppKit
import SwiftUI
import Testing

@testable import Herm

@MainActor
struct SessionSimulatorVisualTests {
    @Test func renderDirectTabReference() throws {
        guard let framePath = ProcessInfo.processInfo.environment["HERM_SIMULATOR_PREVIEW_IMAGE"] else { return }
        let frame: Data
        if framePath == "fixture" {
            let context = try #require(
                CGContext(
                    data: nil, width: 390, height: 844, bitsPerComponent: 8,
                    bytesPerRow: 1560, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(NSColor.windowBackgroundColor.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 390, height: 844))
            let image = try #require(context.makeImage())
            frame = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        } else {
            frame = try Data(contentsOf: URL(fileURLWithPath: framePath))
        }
        let directory = URL(fileURLWithPath: "/tmp/herm-direct-preview")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let previous = DockThemeRuntime.current
        defer { DockThemeRuntime.current = previous }
        DockThemeRuntime.current = .clean
        let dark = ProcessInfo.processInfo.environment["HERM_SIMULATOR_PREVIEW_DARK"] == "1"
        for platform in SessionSimulatorPlatform.allCases {
            for width: CGFloat in [320, 600] {
                for state in ["connected", "preview", "empty", "choose", "stopped", "setup", "error"] {
                    let connected = state == "connected" || state == "preview"
                    let capture = SessionSimulatorCapture()
                    let name = platform == .ios ? "iPhone 17 Pro" : "Pixel 10 Pro XL"
                    let inventory =
                        connected ? "{\"devices\":[{\"id\":\"test\",\"name\":\"\(name)\"}]}" : "{\"devices\":[]}"
                    capture.receive(kind: 74, data: Data(inventory.utf8))
                    if state == "choose" || state == "stopped" {
                        capture.selectDevice(state == "stopped" ? "test" : "")
                        capture.receive(
                            kind: 74,
                            data: Data(
                                "{\"devices\":[{\"id\":\"test\",\"name\":\"\(name)\",\"running\":false},{\"id\":\"second\",\"name\":\"Tablet\",\"running\":true}]}"
                                    .utf8))
                    } else if state == "setup" {
                        capture.receive(
                            kind: 74,
                            data: Data(
                                "{\"devices\":[],\"setup\":\"Install the required SDK tools, then refresh the device list.\"}"
                                    .utf8))
                    } else if state == "error" {
                        capture.receive(
                            kind: 74,
                            data: Data(
                                "{\"error\":\"The device connection ended. Retry when the device is responsive.\"}".utf8
                            ))
                    }
                    if connected { capture.receive(kind: 73, data: frame) }
                    if state == "preview" { capture.setPreviewing(true) }
                    let root = SessionSimulatorView(
                        platform: platform, sessionKey: "visual-fixture", isActive: false, capture: capture
                    )
                    .presentation
                    .frame(width: width, height: 720)
                    .environment(\.colorScheme, dark ? .dark : .light)
                    let host = NSHostingView(rootView: root)
                    host.frame = CGRect(x: 0, y: 0, width: width, height: 720)
                    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    let window = NSWindow(
                        contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.contentView = host
                    window.display()
                    window.layoutIfNeeded()
                    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
                    host.layoutSubtreeIfNeeded()
                    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let data = try #require(bitmap.representation(using: .png, properties: [:]))
                    try data.write(
                        to: directory.appendingPathComponent(
                            "\(platform.rawValue)-\(Int(width))-\(state == "connected" ? "true" : state == "empty" ? "false" : state)-\(dark ? "dark" : "light").png"
                        ))
                    #expect(host.fittingSize.width <= width + 1)
                    window.close()
                }
            }
        }
    }
}
