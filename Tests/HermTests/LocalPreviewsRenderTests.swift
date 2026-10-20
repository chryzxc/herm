import AppKit
import SwiftUI
import Testing

@testable import Herm

@MainActor
struct LocalPreviewsRenderTests {
    @Test func renderPreviewPanelStates() async throws {
        guard let directory = ProcessInfo.processInfo.environment["HERM_PREVIEWS_UI_DIR"] else { return }
        let root = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = DockThemeStore.shared
        let previous = DockThemeRuntime.current
        let appearance = NSApplication.shared.appearance
        defer {
            DockThemeRuntime.current = previous
            DockThemeRuntime.revision &+= 1
            NSApplication.shared.appearance = appearance
        }
        let servers = [
            LocalPreviewServer(pid: 42, port: 3000, processName: "node"),
            LocalPreviewServer(pid: 43, port: 8080, processName: "python3"),
        ]
        for theme in ["clean", "island", "glass", "mono", "eInk", "warmLight"] {
            DockThemeRuntime.current = try #require(DockThemeID(rawValue: theme))
            DockThemeRuntime.revision &+= 1
            NSApplication.shared.appearance = NSAppearance(
                named: ["clean", "eInk", "warmLight"].contains(theme) ? .aqua : .darkAqua)
            for state in ["populated", "empty", "checking", "failed", "stale"] {
                let view = VStack(alignment: .trailing, spacing: DockSpacing.control) {
                    Button {
                    } label: {
                        LocalPreviewsLabel()
                    }.buttonStyle(.dockCompact)
                    LocalPreviewsPanel(
                        servers: ["populated", "stale"].contains(state) ? servers : [],
                        isRefreshing: state == "checking",
                        error: ["failed", "stale"].contains(state)
                            ? "Local listener discovery is unavailable. Refresh to try again." : nil,
                        refresh: {}, open: { _ in })
                }.padding(DockSpacing.group).background(Color.dockCanvas).dockThemedRoot()
                let host = NSHostingView(rootView: view)
                host.frame = NSRect(origin: .zero, size: host.fittingSize)
                #expect(host.frame.width <= 360)
                #expect(host.frame.height >= 220 && host.frame.height <= 440)
                let window = NSWindow(
                    contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = host
                window.orderFrontRegardless()
                for _ in 0..<3 {
                    host.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(80))
                }
                let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: rep)
                try #require(rep.representation(using: .png, properties: [:])).write(
                    to: root.appendingPathComponent("previews-\(theme)-\(state).png"))
                window.orderOut(nil)
            }
        }
    }
}
