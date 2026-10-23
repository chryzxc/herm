import AppKit
import SwiftUI
import Testing

@testable import Herm

@MainActor
struct SessionBrowserRenderTests {
    @Test func renderStablePageStates() async throws {
        guard let directory = ProcessInfo.processInfo.environment["HERM_BROWSER_UI_DIR"] else {
            return
        }
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
        for theme: DockThemeID in [.clean, .island, .glass, .mono, .eInk] {
            DockThemeRuntime.current = theme
            DockThemeRuntime.revision &+= 1
            NSApplication.shared.appearance = NSAppearance(
                named: [.clean, .eInk].contains(theme) ? .aqua : .darkAqua)
            for width in [300.0, 760.0] {
                let workspace = SessionBrowserWorkspace(
                    key: .init(profileID: nil, sessionID: "browser-states"))
                let browser = workspace.addTab()
                let content = SessionBrowserView(
                    model: DockModel(initialSessionID: "browser-states"), workspace: workspace,
                    browser: browser
                )
                .frame(width: width, height: 420).dockThemedRoot()
                let host = NSHostingView(rootView: content)
                host.frame = NSRect(x: 0, y: 0, width: width, height: 420)
                let window = NSWindow(
                    contentRect: host.frame, styleMask: [.borderless], backing: .buffered,
                    defer: false)
                window.contentView = host
                window.orderFrontRegardless()
                try await Task.sleep(for: .milliseconds(100))
                host.layoutSubtreeIfNeeded()
                let pageFrame = browser.web.convert(browser.web.bounds, to: host)
                for state in ["empty", "loading", "failed"] {
                    if state == "loading" {
                        browser.webView(browser.web, didStartProvisionalNavigation: nil)
                    }
                    if state == "failed" {
                        browser.webView(
                            browser.web, didFailProvisionalNavigation: nil,
                            withError: NSError(
                                domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost))
                    }
                    try await Task.sleep(for: .milliseconds(100))
                    host.layoutSubtreeIfNeeded()
                    #expect(browser.web.convert(browser.web.bounds, to: host) == pageFrame)
                    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    try #require(bitmap.representation(using: .png, properties: [:])).write(
                        to: root.appendingPathComponent(
                            "browser-page-\(theme.rawValue)-\(Int(width))-\(state).png"))
                }
                window.orderOut(nil)
            }
        }
    }

    @Test func renderAdaptiveToolbar() async throws {
        guard let directory = ProcessInfo.processInfo.environment["HERM_BROWSER_UI_DIR"] else {
            return
        }
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
        let workspace = SessionBrowserWorkspace(key: .init(profileID: nil, sessionID: "browser-ui"))
        let browser = workspace.addTab()
        browser.address = "http://localhost:5173/preview/responsive-layout"
        let model = DockModel(initialSessionID: "browser-ui")
        for theme: DockThemeID in [.clean, .island, .glass, .mono, .eInk] {
            DockThemeRuntime.current = theme
            DockThemeRuntime.revision &+= 1
            NSApplication.shared.appearance = NSAppearance(
                named: [.clean, .eInk].contains(theme) ? .aqua : .darkAqua)
            for width in [280.0, 320.0, 390.0, 540.0, 760.0] {
                for loading in [false, true] {
                    if loading { browser.webView(browser.web, didStartProvisionalNavigation: nil) }
                    let toolbar = SessionBrowserView(
                        model: model, workspace: workspace, browser: browser
                    ).toolbar
                    let content = toolbar.padding(8).frame(width: width).background(
                        Color.dockCanvas
                    )
                    .dockThemedRoot()
                    let host = NSHostingView(rootView: content)
                    host.frame = NSRect(x: 0, y: 0, width: width, height: host.fittingSize.height)
                    #expect(host.frame.height <= 90)
                    let window = NSWindow(
                        contentRect: host.frame, styleMask: [.borderless], backing: .buffered,
                        defer: false)
                    window.contentView = host
                    window.orderFrontRegardless()
                    for _ in 0..<3 {
                        host.layoutSubtreeIfNeeded()
                        try await Task.sleep(for: .milliseconds(60))
                    }
                    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    try #require(bitmap.representation(using: .png, properties: [:])).write(
                        to: root.appendingPathComponent(
                            "browser-\(theme.rawValue)-\(Int(width))-\(loading ? "loading" : "loaded").png"
                        ))
                    window.orderOut(nil)
                    browser.stopLoading()
                    browser.address = "http://localhost:5173/preview/responsive-layout"
                }
            }
        }
    }
}
