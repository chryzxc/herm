import AppKit
import SwiftUI
import Testing

@testable import Herm

@MainActor
struct DockActionErrorTests {
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
