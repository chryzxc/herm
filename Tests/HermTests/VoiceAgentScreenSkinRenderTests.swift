import AppKit
import SwiftUI
import Testing

@testable import Herm

/// Renders the voice agent screen in every skin when VOICE_SCREEN_SNAPSHOT_DIR is set.
@MainActor
struct VoiceAgentScreenSkinRenderTests {
    @Test func renderAgentScreenInEverySkin() async throws {
        guard let directory = ProcessInfo.processInfo.environment["VOICE_SCREEN_SNAPSHOT_DIR"] else { return }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let savedTheme = DockThemeRuntime.current
        let savedRevision = DockThemeRuntime.revision
        defer {
            DockThemeRuntime.current = savedTheme
            DockThemeRuntime.revision = savedRevision
        }
        let model = DockModel()
        let now = Date()
        model.activeToolCalls = [
            ActiveToolCall(
                id: "s", name: "search_files", input: "", context: "", startedAt: now.addingTimeInterval(-5),
                result: #"{"files": ["/Users/me/Projects/herm/README.md", "/Users/me/Projects/notes/todo.md"]}"#,
                isComplete: true, args: ["pattern": "*.md", "path": "~/Projects"]),
            ActiveToolCall(
                id: "p", name: "patch", input: "", context: "", startedAt: now, result: nil, isComplete: false,
                diffPreview: "--- a/README.md\n+++ b/README.md\n- Old line\n+ New line\n  Kept line",
                args: ["path": "/Users/me/Projects/herm/README.md"]),
        ]
        for theme in DockThemeID.allCases {
            let modes: [Bool?] = (theme.appearance == .system ? [false, true] : [theme.appearance == .dark]) + [nil]
            for mode in modes {
                // nil renders inside the always-black notch.
                let dark = mode ?? true
                DockThemeRuntime.current = theme
                DockThemeRuntime.revision &+= 1
                let content = VoiceAgentScreen(model: model).frame(width: 420).padding(24)
                    .background(Color.dockOpaqueCanvas)
                    .dockThemedRoot(surface: mode == nil ? .cameraNotch : .app)
                    .environment(\.colorScheme, dark ? .dark : .light)
                let host = NSHostingView(rootView: content)
                host.frame = CGRect(origin: .zero, size: host.fittingSize)
                let window = NSWindow(
                    contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance =
                    mode == nil ? DockThemeStore.notchAppearance : NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentView = host
                window.orderFrontRegardless()
                for _ in 0..<20 {
                    host.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(60))
                }
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let data = try #require(bitmap.representation(using: .png, properties: [:]))
                try data.write(
                    to: URL(fileURLWithPath: directory).appendingPathComponent(
                        "\(theme.rawValue)-\(mode == nil ? "notch" : dark ? "dark" : "light").png"))
                window.orderOut(nil)
            }
        }
    }
}
