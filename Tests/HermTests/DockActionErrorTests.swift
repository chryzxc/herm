import AppKit
import SwiftUI
import Testing

@testable import Herm

@MainActor
struct DockActionErrorTests {
    @Test func closeButtonWorksWithoutMakingThePopupKey() async throws {
        _ = NSApplication.shared
        let parent = DockPanel(
            contentRect: NSRect(x: 100, y: 100, width: 600, height: 300),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        parent.sharingType = .none
        parent.makeKeyAndOrderFront(nil)
        defer { parent.close() }
        let center = DockActionErrorCenter()
        let presenter = DockActionErrorPresenter(center: center)
        center.report("Could not pin session", message: "not_found")
        let popup = try #require(parent.childWindows?.first)
        #expect(abs(popup.frame.maxX - (parent.frame.maxX - 20)) < 1)
        #expect(abs(popup.frame.minY - (parent.frame.minY + 20)) < 1)
        #expect(popup.sharingType == .none)
        #expect(!popup.canBecomeMain)
        defer { withExtendedLifetime(presenter) {} }
        let host = try #require(popup.contentView)
        #expect(host.acceptsFirstMouse(for: nil))
        #expect(popup.canBecomeKey)
        for _ in 0..<3 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
        }
        // Inside the close button's frame, outside the small X's painted pixels.
        let point = NSPoint(x: host.bounds.maxX - 36, y: host.bounds.maxY - 20)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(
                NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: popup.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            NSApp.sendEvent(event)
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(center.current == nil)
        #expect(!popup.isVisible)
        #expect(parent.isKeyWindow)
    }

    @Test func errorsAreSanitizedAndRemainUntilTheirOwnDismissal() throws {
        let center = DockActionErrorCenter()
        center.report("Save failed", message: "token=private-value\nhttps://example.com/private\nTry again.")
        let first = try #require(center.current)
        #expect(!first.message.contains("private-value"))
        #expect(!first.message.contains("example.com"))
        #expect(first.message.contains("Try again."))
        center.report("Pin failed", message: "")
        let second = try #require(center.current)
        #expect(second.message == "The action could not be completed. Try again.")
        center.dismiss(first.id)
        #expect(center.current == second)
        center.dismiss(second.id)
        #expect(center.current == nil)
    }

    @Test func cancellationDoesNotCreateAFailurePopup() {
        let center = DockActionErrorCenter()
        center.report("Cancelled", error: CancellationError())
        center.report("Cancelled", error: URLError(.cancelled))
        #expect(center.current == nil)
    }

    @Test func unavailableControlActionReportsFailure() async {
        let center = DockActionErrorCenter.shared
        if let current = center.current { center.dismiss(current.id) }
        let control = ControlCenterModel()
        #expect(await control.compressActiveSession() == false)
        #expect(center.current?.title == "Could not compress session")
        #expect(control.lastError?.contains("unavailable") == true)
        if let current = center.current { center.dismiss(current.id) }
    }

    @Test func renderErrorPopups() async throws {
        guard let directory = ProcessInfo.processInfo.environment["ACTION_ERROR_SNAPSHOT_DIR"] else { return }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let savedTheme = DockThemeRuntime.current
        defer { DockThemeRuntime.current = savedTheme }
        for (theme, dark) in [
            (DockThemeID.clean, false), (.clean, true), (.glass, false), (.glass, true), (.mono, true), (.eInk, false),
        ] {
            DockThemeRuntime.current = theme
            let root = DockActionErrorPopup(
                error: DockActionError(
                    title: "Could not pin session", message: "The session changed. Refresh and try again."),
                dismiss: {}
            ).frame(width: 360).padding(12).background(Color.dockCanvas)
                .environment(\.colorScheme, dark ? .dark : .light)
            let host = NSHostingView(rootView: root)
            host.frame = CGRect(origin: .zero, size: host.fittingSize)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
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
            try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(theme.rawValue)-\(dark).png"))
            window.orderOut(nil)
        }
    }
}
