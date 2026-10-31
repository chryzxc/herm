import AppKit
import SwiftUI
import Testing

@testable import Herm

@MainActor
struct AutomationRenderSnapshotTests {
    @Test func renderAutomation() async throws {
        guard let path = ProcessInfo.processInfo.environment["HERM_AUTOMATION_REVIEW_DIR"] else {
            return
        }
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        let savedTheme = DockThemeRuntime.current
        let savedRevision = DockThemeRuntime.revision
        let suite = "Herm.AutomationRender.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            DockThemeRuntime.current = savedTheme
            DockThemeRuntime.revision = savedRevision
            defaults.removePersistentDomain(forName: suite)
        }
        let control = ControlCenterModel(capabilities: [
            CapabilityState(
                id: "rpc-scheduling", title: "Cron", detail: "Available", isAvailable: true,
                recovery: nil)
        ])
        let date = ISO8601DateFormatter()
        let now = Date()
        control.cronJobs = (0..<8).map { index in
            CronSummary(
                id: "fixture-\(index)",
                name: [
                    "Weekly repository review and delivery summary", "Board triage & reminders",
                    "Session hygiene", "Server cleanup", "Clean merged worktrees",
                    "Daily technology news",
                    "Dependency review", "Release notes",
                ][index],
                schedule: "every 1440m", enabled: index != 3,
                nextRun: date.string(from: now.addingTimeInterval(3600)),
                prompt: "Review the repository and summarize changes requiring attention.")
        }
        control.cronRuns = (0..<12).map { index -> CronRunSummary in
            let status: String = index == 2 ? "failed" : "finished"
            let claimedAt = date.string(from: now.addingTimeInterval(-Double(index + 1) * 86400))
            let error: String? = index == 2 ? "The delivery target was unavailable." : nil
            return CronRunSummary(
                id: "run-\(index)", status: status, jobID: "fixture-0",
                source: "cron_output",
                claimedAt: claimedAt,
                error: error,
                outputPreview:
                    "Cron job: Weekly repository review and delivery summary\nRun mode: script\n\nWEEKLY REVIEW\nReviewed the current changes. Build completed successfully. Two changes need human review.\n\nNext steps\nReview the pending changes before the next release."
            )
        }
        for (theme, dark) in [
            (DockThemeID.clean, false), (.clean, true), (.glass, false), (.glass, true), (.mono, true),
            (.eInk, false),
        ] {
            DockThemeRuntime.current = theme
            DockThemeRuntime.revision &+= 1
            for width: CGFloat in [440, 1100, 1500] {
                let view = AutomationWorkspaceView(control: control)
                    .defaultAppStorage(defaults)
                    .frame(width: width, height: 900)
                    .background(Color.dockCanvas)
                    .background(dark ? Color.black : Color.white)
                    .dockThemedRoot()
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .environment(\.dockWorkspaceScale, DockWorkspaceScale.window)
                let host = NSHostingView(rootView: view)
                host.frame = NSRect(x: 0, y: 0, width: width, height: 900)
                let window = NSWindow(
                    contentRect: host.frame, styleMask: [.borderless], backing: .buffered,
                    defer: false)
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentView = host
                window.orderFrontRegardless()
                for _ in 0..<3 {
                    host.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(80))
                }
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                try png.write(
                    to: URL(fileURLWithPath: path).appendingPathComponent(
                        "\(theme.rawValue)-\(dark ? "dark" : "light")-\(Int(width)).png"))
                window.orderOut(nil)
                #expect(bitmap.pixelsWide > 0)
            }
        }
    }
}
