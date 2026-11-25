import AppKit
import SwiftUI
import Testing

@testable import Herm

@MainActor
struct SoftwareUpdateControlsTests {
    @Test func quickUpdatesShowTheAgentVersionsAndUpdateAction() async throws {
        let application = NSApplication.shared
        let accessibility = application.value(forKey: "accessibilityEnhancedUserInterface")
        application.setValue(true, forKey: "accessibilityEnhancedUserInterface")
        defer { application.setValue(accessibility, forKey: "accessibilityEnhancedUserInterface") }

        let agent = HermesUpdateService(
            readVersion: { (true, "Hermes Agent v0.20.0") },
            readRelease: {
                .success(
                    HermesLatestRelease(
                        tag: "v0.21.0", marketing: "0.21.0", name: nil, publishedAt: nil, pageURL: nil))
            },
            launchUpdate: { _ in Issue.record("Showing the controls must not launch an update.") }
        )
        let host = NSHostingView(
            rootView: SoftwareUpdateControls(appUpdater: HermAppUpdater(), agentUpdateService: agent, compact: true)
                .dockPresentationSurface())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 360),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }

        var labels: [String] = []
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            labels = accessibilityText(in: host)
            if labels.contains("v0.21.0") { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(agent.phase == .updateAvailable)
        let appTitle = try #require(labels.firstIndex(of: "Herm"))
        let agentTitle = try #require(labels.firstIndex(of: "Hermes Agent"))
        #expect(appTitle < agentTitle)
        #expect(labels.contains("v0.20.0"))
        #expect(labels.contains("v0.21.0"))
        #expect(labels.contains("Update Hermes Agent"))
    }

    private func accessibilityText(in element: AnyObject) -> [String] {
        let value: String? =
            if element.accessibilityRole?() == .staticText, let object = element as? NSObject {
                object.perform(NSSelectorFromString("accessibilityValue"))?.takeUnretainedValue() as? String
            } else {
                nil
            }
        let labels = [element.accessibilityLabel?(), element.accessibilityTitle?(), value].compactMap { $0 }
        return labels + (element.accessibilityChildren?() ?? []).flatMap { accessibilityText(in: $0 as AnyObject) }
    }
}
