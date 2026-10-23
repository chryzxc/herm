import AppKit
import SwiftUI
import Testing
@testable import Herm

@MainActor
struct PullRequestMergeButtonTests {
    @Test func selectionSurvivesRefreshAndFallsBackOnlyToAllowedMethods() {
        #expect(GitHubMergeMethod.squash.available(in: [.merge, .squash]) == .squash)
        #expect(GitHubMergeMethod.merge.available(in: [.rebase, .squash]) == .rebase)
        #expect(GitHubMergeMethod.rebase.available(in: []) == nil)
    }

    @Test(arguments: [false, true])
    func dropdownDoesNotInvokeTheMergeAction(mainEnabled: Bool) async throws {
        var calls = 0
        let host = NSHostingView(rootView: PullRequestMergeButton(method: .constant(.merge),
            methods: GitHubMergeMethod.allCases, enabled: mainEnabled) { calls += 1 })
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        let visibleBefore = NSApplication.shared.windows.filter(\.isVisible).count
        for x in [30.0, host.bounds.width - 14] {
            let point = host.convert(NSPoint(x: x, y: host.bounds.midY), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
                window.sendEvent(event)
            }
            try await Task.sleep(for: .milliseconds(100))
            #expect(calls == (mainEnabled ? 1 : 0))
        }
        #expect(NSApplication.shared.windows.filter(\.isVisible).count > visibleBefore)
    }

    @Test func renderMergeControlsAcrossSkins() async throws {
        guard let directory = ProcessInfo.processInfo.environment["HERM_MERGE_UI_DIR"] else { return }
        let root = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let saved = DockThemeRuntime.current
        let revision = DockThemeRuntime.revision
        defer { DockThemeRuntime.current = saved; DockThemeRuntime.revision = revision }
        for theme in DockThemeID.allCases {
            let modes = theme.appearance == .system ? [false, true] : [theme.appearance == .dark]
            for dark in modes {
                DockThemeRuntime.current = theme
                DockThemeRuntime.revision &+= 1
                let view = VStack(alignment: .leading, spacing: 12) {
                    ForEach(GitHubMergeMethod.allCases) { method in
                        PullRequestMergeButton(method: .constant(method), methods: GitHubMergeMethod.allCases, action: {})
                    }
                    PullRequestMergeButton(method: .constant(.squash), methods: [.squash], isBusy: true,
                        enabled: false, selectionEnabled: false, action: {})
                }
                .padding(20).frame(width: 320)
                .background(Color.dockOpaqueCanvas).dockThemedRoot()
                .environment(\.colorScheme, dark ? .dark : .light)
                let host = NSHostingView(rootView: view)
                host.frame = CGRect(origin: .zero, size: host.fittingSize)
                let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentView = host
                window.orderFrontRegardless()
                defer { window.orderOut(nil) }
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(150))
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try #require(bitmap.representation(using: .png, properties: [:]))
                    .write(to: root.appendingPathComponent("\(theme.rawValue)-\(dark ? "dark" : "light").png"))
            }
        }
    }
}
