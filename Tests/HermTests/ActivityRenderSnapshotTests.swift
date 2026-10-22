import AppKit
import SwiftUI
import Testing
@testable import Herm

/// Opt-in native visual fixtures, with no live Hermes connection.
@MainActor
struct ActivityRenderSnapshotTests {
    @Test func renderActivity() async throws {
        guard let path = ProcessInfo.processInfo.environment["HERM_ACTIVITY_REVIEW_DIR"] else { return }
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        let savedTheme = DockThemeRuntime.current
        let savedRevision = DockThemeRuntime.revision
        let suite = "Herm.ActivityRender.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set("day", forKey: "dock.calendar.scope")
        defer {
            DockThemeRuntime.current = savedTheme
            DockThemeRuntime.revision = savedRevision
            defaults.removePersistentDomain(forName: suite)
        }
        let control = ControlCenterModel()
        let now = Date()
        let calendar = Calendar.current
        let daily: [[String: Any]] = (0..<30).map { offset in
            let date = calendar.date(byAdding: .day, value: -offset, to: now)!
            let count = (offset % 7 + 1) * 80_000
            return ["day": date.formatted(.iso8601.year().month().day().dateSeparator(.dash)),
                    "input_tokens": count, "output_tokens": count / 8, "cache_read_tokens": count * 3,
                    "estimated_cost": Double(count) / 100_000, "sessions": 3, "api_calls": 24]
        }
        let report = ControlCenterModel.parseTokenUsage([
            "period_days": 30,
            "totals": ["total_input": 9_000_000, "total_output": 1_200_000, "total_cache_read": 27_000_000,
                       "total_reasoning": 240_000, "total_estimated_cost": 36.5, "total_sessions": 90, "total_api_calls": 720],
            "daily": daily,
            "by_model": [["model": "Example model", "input_tokens": 9_000_000, "output_tokens": 1_200_000,
                          "sessions": 90, "api_calls": 720, "estimated_cost": 36.5]],
            "tools": [["tool": "terminal", "count": 90, "percentage": 60.0], ["tool": "read_file", "count": 60, "percentage": 40.0]],
            "skills": ["summary": ["total_skill_loads": 10, "distinct_skills_used": 1],
                       "top_skills": [["skill": "Review", "total_count": 10, "percentage": 100.0]]]
        ])
        control.tokenUsage = report
        control.yearActivity = report.daily
        let commits = (0..<80).map { offset in
            WorkCommit(repo: offset % 2 == 0 ? "Herm" : "Workspace", hash: "fixture-\(offset)",
                       subject: "Improve workspace navigation", date: now.addingTimeInterval(-Double(offset) * 12_000))
        }
        control.workCalendar = WorkCalendarIndex.build(month: now, sessions: [], tasks: [], commits: commits, runs: [], usage: report.daily)
        for (theme, dark) in [(DockThemeID.clean, false), (.clean, true), (.glass, false), (.mono, true), (.eInk, false)] {
            DockThemeRuntime.current = theme
            DockThemeRuntime.revision &+= 1
            for width: CGFloat in [640, 1380] {
                for work in [true, false] {
                    let content = work ? AnyView(WorkActivityView(control: control, repoPaths: [])) : AnyView(ScrollView { UsageWorkspaceView(control: control) })
                    let view = content.defaultAppStorage(defaults).padding(20)
                        .frame(width: width, height: 1000)
                        .background(Color.dockCanvas).background(dark ? Color.black : Color.white)
                        .dockThemedRoot().environment(\.colorScheme, dark ? .dark : .light)
                    let host = NSHostingView(rootView: view)
                    host.frame = NSRect(x: 0, y: 0, width: width, height: 1000)
                    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
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
                    let name = "\(work ? "work" : "spend")-\(theme.rawValue)-\(dark ? "dark" : "light")-\(Int(width)).png"
                    try png.write(to: URL(fileURLWithPath: path).appendingPathComponent(name))
                    window.orderOut(nil)
                    #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
                }
            }
        }
    }
}
