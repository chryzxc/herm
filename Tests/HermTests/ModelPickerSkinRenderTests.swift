import AppKit
import SwiftUI
import Testing

@testable import Herm

@MainActor
struct ModelPickerSkinRenderTests {
    @Test func renderPickerInEverySkin() async throws {
        guard let directory = ProcessInfo.processInfo.environment["MODEL_PICKER_SNAPSHOT_DIR"] else { return }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let savedTheme = DockThemeRuntime.current
        let savedRevision = DockThemeRuntime.revision
        defer {
            DockThemeRuntime.current = savedTheme
            DockThemeRuntime.revision = savedRevision
        }
        let model = DockModel()
        model.sessionID = "skin-fixture"
        model.sessionFastEnabled = false
        model.effortCatalog = HermesEffortCatalog(result: [
            "providers": [["slug": "openai", "models": ["gpt-6"], "capabilities": ["gpt-6": ["reasoning": true]]]]
        ])
        let options = [
            HermesModelOption(provider: "openai", model: "gpt-6"),
            HermesModelOption(provider: "openai", model: "gpt-6-mini"),
            HermesModelOption(provider: "anthropic", model: "claude-sonnet"),
        ]
        for theme in DockThemeID.allCases {
            let modes: [Bool] = theme.appearance == .system ? [false, true] : [theme.appearance == .dark]
            for dark in modes {
                DockThemeRuntime.current = theme
                DockThemeRuntime.revision &+= 1
                let picker = ModelPickerView(
                    options: options, selectedID: "openai|gpt-6", isRefreshing: false, refreshError: nil,
                    onRefresh: {}, onSelect: { _ in }, effortModel: model, effortSelection: .constant(.medium)
                )
                let content = DockMenuPanel(content: picker.pickerContent.dockPadding(.vertical, 6))
                    .background(dark ? Color.black : Color.white)
                    .dockThemedRoot()
                    .environment(\.colorScheme, dark ? .dark : .light)
                let host = NSHostingView(rootView: content)
                host.frame = CGRect(origin: .zero, size: host.fittingSize)
                let window = NSWindow(
                    contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentView = host
                window.orderFrontRegardless()
                for _ in 0..<3 {
                    host.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(50))
                }
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let data = try #require(bitmap.representation(using: .png, properties: [:]))
                try data.write(
                    to: URL(fileURLWithPath: directory).appendingPathComponent(
                        "\(theme.rawValue)-\(dark ? "dark" : "light").png"))
                window.orderOut(nil)
            }
        }
    }
}
