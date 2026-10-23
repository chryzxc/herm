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
            return [
                "day": date.formatted(.iso8601.year().month().day().dateSeparator(.dash)),
                "input_tokens": count, "output_tokens": count / 8, "cache_read_tokens": count * 3,
                "estimated_cost": Double(count) / 100_000, "sessions": 3, "api_calls": 24,
            ]
        }
        let report = ControlCenterModel.parseTokenUsage([
            "period_days": 30,
            "totals": [
                "total_input": 9_000_000, "total_output": 1_200_000, "total_cache_read": 27_000_000,
                "total_reasoning": 240_000, "total_estimated_cost": 36.5, "total_sessions": 90, "total_api_calls": 720,
            ],
            "daily": daily,
            "by_model": [
                [
                    "model": "Example model", "input_tokens": 9_000_000, "output_tokens": 1_200_000,
                    "sessions": 90, "api_calls": 720, "estimated_cost": 36.5,
                ]
            ],
            "tools": [
                ["tool": "terminal", "count": 90, "percentage": 60.0],
                ["tool": "read_file", "count": 60, "percentage": 40.0],
            ],
            "skills": [
                "summary": ["total_skill_loads": 10, "distinct_skills_used": 1],
                "top_skills": [["skill": "Review", "total_count": 10, "percentage": 100.0]],
            ],
        ])
        control.tokenUsage = report
        control.yearActivity = report.daily
        let commits = (0..<80).map { offset in
            WorkCommit(
                repo: offset % 2 == 0 ? "Herm" : "Workspace", hash: "fixture-\(offset)",
                subject: "Improve workspace navigation", date: now.addingTimeInterval(-Double(offset) * 12_000))
        }
        let pullRequests = (0..<4).map { offset in
            WorkPullRequest(
                repo: offset % 2 == 0 ? "Herm" : "Workspace", number: offset + 1,
                title: "Improve workspace navigation", url: nil,
                mergedAt: now.addingTimeInterval(-Double(offset) * 24_000))
        }
        let sessions = (0..<3).map { offset in
            SessionSummary(
                id: "fixture-session-\(offset)", title: "Review workspace navigation", state: "idle", preview: nil,
                updatedAt: now.addingTimeInterval(-Double(offset) * 36_000))
        }
        let tasks = (0..<2).map { offset in
            KanbanTaskSummary(
                id: "fixture-task-\(offset)", title: "Ship workspace navigation", status: "done", detail: nil,
                priority: nil, assignee: nil, completedAt: now.addingTimeInterval(-Double(offset) * 36_000))
        }
        let runs = (0..<2).map { offset in
            CronRunSummary(
                id: "fixture-run-\(offset)", status: offset == 0 ? "failed" : "completed", jobID: "fixture-job",
                source: "cron", claimedAt: now.addingTimeInterval(-Double(offset) * 36_000).ISO8601Format(), error: nil)
        }
        control.workCalendar = WorkCalendarIndex.build(
            month: now, sessions: sessions, tasks: tasks, commits: commits,
            pullRequests: pullRequests, runs: runs, usage: report.daily)
        let selectedThemes = ProcessInfo.processInfo.environment["HERM_ACTIVITY_REVIEW_THEMES"]?.split(separator: ",")
            .map(String.init)
        let themes = DockThemeID.allCases.filter { selectedThemes?.contains($0.rawValue) ?? true }
        #expect(!themes.isEmpty)
        let appearances = themes.flatMap { theme -> [(DockThemeID, Bool)] in
            let modes: [Bool] =
                switch theme.appearance {
                case .light: [false]
                case .dark: [true]
                case .system: [false, true]
                }
            return modes.map { (theme, $0) }
        }
        for (theme, dark) in appearances {
            DockThemeRuntime.current = theme
            DockThemeRuntime.revision &+= 1
            for width: CGFloat in [640, 1380] {
                for page in ["day", "week", "month", "spend"] {
                    let work = page != "spend"
                    defaults.set(work ? page : "day", forKey: "dock.calendar.scope")
                    let content =
                        work
                        ? AnyView(WorkActivityView(control: control, repoPaths: []))
                        : AnyView(ScrollView { UsageWorkspaceView(control: control) })
                    let view = content.defaultAppStorage(defaults).padding(20)
                        .frame(width: width, height: 1000)
                        .background(Color.dockCanvas).background(dark ? Color.black : Color.white)
                        .dockThemedRoot().environment(\.colorScheme, dark ? .dark : .light)
                    let host = NSHostingView(rootView: view)
                    host.frame = NSRect(x: 0, y: 0, width: width, height: 1000)
                    let window = NSWindow(
                        contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
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
                    let name =
                        "\(work ? "work-\(page)" : "spend")-\(theme.rawValue)-\(dark ? "dark" : "light")-\(Int(width)).png"
                    try png.write(to: URL(fileURLWithPath: path).appendingPathComponent(name))
                    window.close()
                    #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
                }
            }
        }
    }
}
