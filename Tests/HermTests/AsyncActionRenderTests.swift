import AppKit
import SwiftUI
import Testing

@testable import Herm

@Suite @MainActor
struct AsyncActionRenderTests {
    @Test func renderPendingActionsAcrossThemes() async throws {
        guard let directory = ProcessInfo.processInfo.environment["HERM_ASYNC_SNAPSHOT_DIR"] else { return }
        let root = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = DockThemeStore.shared
        let savedTheme = DockThemeRuntime.current
        let savedAppearance = NSApplication.shared.appearance
        defer {
            DockThemeRuntime.current = savedTheme
            DockThemeRuntime.revision &+= 1
            NSApplication.shared.appearance = savedAppearance
        }
        let activity = DockAsyncAction()
        let (stream, release) = AsyncStream<Void>.makeStream()
        let task = activity.perform { for await _ in stream { break } }
        for raw in ["clean", "island", "glass", "mono", "eInk"] {
            DockThemeRuntime.current = try #require(DockThemeID(rawValue: raw))
            DockThemeRuntime.revision &+= 1
            NSApplication.shared.appearance = NSAppearance(named: ["clean", "eInk"].contains(raw) ? .aqua : .darkAqua)
            let content = VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    DockAsyncButton("Submit") {}.buttonStyle(.dockPrimary)
                    DockAsyncButton(activity: activity, action: {}) { Text("Submit") }.buttonStyle(.dockPrimary)
                    DockAsyncButton("Refresh") {}.buttonStyle(.dockSecondary).disabled(true)
                }
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Opening pull request owner/repo#42…").dockFont(.body)
                }
                .padding(10)
                .dockFloatingSurface(
                    RoundedRectangle(cornerRadius: DockLayout.controlRadius), tint: .dockSurface2,
                    stroke: .dockBorderLight)
            }
            .padding(20).frame(width: 520).background(Color.dockCanvas).dockThemedRoot()
            let host = NSHostingView(rootView: content)
            host.frame = NSRect(x: 0, y: 0, width: 520, height: host.fittingSize.height)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSApplication.shared.appearance
            window.contentView = host
            window.orderFrontRegardless()
            for _ in 0..<5 {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(100))
            }
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            window.orderOut(nil)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: root.appendingPathComponent("async-\(raw).png"))
        }
        release.finish()
        await task?.value
    }
}
