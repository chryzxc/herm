import AppKit
import SwiftUI
import Testing

@testable import Herm

/// Opt-in native fixtures; no gateway or EventKit permission prompts.
@MainActor
struct CalendarRenderSnapshotTests {
    @Test func renderCalendar() async throws {
        guard let path = ProcessInfo.processInfo.environment["HERM_CALENDAR_REVIEW_DIR"] else { return }
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        let savedTheme = DockThemeRuntime.current
        let savedRevision = DockThemeRuntime.revision
        let suite = "Herm.CalendarRender.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            DockThemeRuntime.current = savedTheme
            DockThemeRuntime.revision = savedRevision
            defaults.removePersistentDomain(forName: suite)
        }
        defaults.set(false, forKey: "dock.calendar.system")
        let control = ControlCenterModel()
        let start = Calendar.current.startOfDay(for: Date())
        let formatter = ISO8601DateFormatter()
        control.cronJobs = (0..<5).map { index in
            CronSummary(
                id: "fixture-\(index)",
                name: [
                    "Delivery monitor", "Board triage & reminders", "Session hygiene", "Server cleanup",
                    "Clean merged worktrees",
                ][index],
                schedule: "0 9 * * *", enabled: true,
                nextRun: formatter.string(from: start.addingTimeInterval(Double(9 + index) * 3600)))
        }
        control.globalKanbanTasks = [
            KanbanTaskSummary(
                id: "fixture-task", title: "Review calendar design", status: "running", detail: nil, priority: nil,
                assignee: nil)
        ]
        for (theme, dark) in [
            (DockThemeID.clean, false), (.clean, true), (.glass, false), (.mono, true), (.eInk, false),
        ] {
            DockThemeRuntime.current = theme
            DockThemeRuntime.revision &+= 1
            for scope in ["Month", "Week", "Agenda"] {
                defaults.set(scope, forKey: "dock.calendar.view")
                for width: CGFloat in [440, 1320] {
                    let view = CalendarWorkspaceView(control: control)
                        .defaultAppStorage(defaults)
                        .padding(20)
                        .frame(width: width, height: 900)
                        .background(Color.dockCanvas)
                        .background(dark ? Color.black : Color.white)
                        .dockThemedRoot()
                        .environment(\.colorScheme, dark ? .dark : .light)
                    let host = NSHostingView(rootView: view)
                    host.frame = NSRect(x: 0, y: 0, width: width, height: 900)
                    let window = NSWindow(
                        contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
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
                    let name = "\(theme.rawValue)-\(dark ? "dark" : "light")-\(scope)-\(Int(width)).png"
                    try png.write(to: URL(fileURLWithPath: path).appendingPathComponent(name))
                    window.orderOut(nil)
                    #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
                }
            }
        }
    }
}
