import AppKit
import SwiftUI
import Testing

@testable import Herm

@Suite @MainActor
struct BotRosterVisualTests {
    @Test func renderRosterAcrossThemesAndWidths() async throws {
        guard let directory = ProcessInfo.processInfo.environment["BOT_ROSTER_SNAPSHOT_DIR"] else { return }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        _ = NSApplication.shared
        _ = DockThemeStore.shared
        let savedTheme = DockThemeRuntime.current
        let savedAppearance = NSApplication.shared.appearance
        defer {
            DockThemeRuntime.current = savedTheme
            DockThemeRuntime.revision &+= 1
            NSApplication.shared.appearance = savedAppearance
        }
        for (theme, dark) in [(DockThemeID.storm, true), (.clean, false), (.mono, true), (.glass, false)] {
            DockThemeRuntime.current = theme
            DockThemeRuntime.revision &+= 1
            NSApplication.shared.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let root = HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 12) {
                    card(selected: false)
                    card(selected: true)
                }.frame(width: 300)
                VStack(spacing: 12) {
                    card(selected: false)
                    card(selected: true)
                }.frame(width: 470)
            }
            .padding(20).frame(width: 826, height: 460, alignment: .topLeading)
            .background(DockWindowBackground()).dockThemedRoot()
            .environment(\.colorScheme, dark ? .dark : .light)
            let host = NSHostingView(rootView: root)
            host.frame = NSRect(x: 0, y: 0, width: 826, height: 460)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = host
            window.orderFrontRegardless()
            defer { window.orderOut(nil) }
            for _ in 0..<3 {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(50))
            }
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("bots-\(theme.rawValue).png"))
        }
    }

    private func card(selected: Bool) -> some View {
        MissionControlBotRow(
            bot: BotSummary(
                id: selected ? "nexus" : "cypher", name: selected ? "Nexus" : "Cypher",
                title: selected ? "Coordinator" : "Security Reviewer", description: nil,
                model: "gpt-6.1-sol", isActive: false, chat: nil, avatarURL: nil,
                preview: "Reviewed the authentication boundary and prepared the follow-up changes.",
                lastActive: Date(timeIntervalSinceNow: -3600), isHidden: false, hasAvatar: false,
                isDefault: selected),
            runtime: BotRuntimeConfig(reasoningEffort: "medium"),
            isSelected: selected, onSelect: {})
    }
}
