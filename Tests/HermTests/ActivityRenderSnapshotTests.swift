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
                    "model": "Example model", "input_tokens": 6_000_000, "output_tokens": 800_000,
                    "sessions": 60, "api_calls": 480, "estimated_cost": 25.0,
                ],
                [
                    "model": "Secondary model", "input_tokens": 3_000_000, "output_tokens": 400_000,
                    "sessions": 30, "api_calls": 240, "estimated_cost": 11.5,
                ],
                [
                    "model": "Background model", "input_tokens": 250_000, "output_tokens": 50_000,
                    "sessions": 0, "api_calls": 24, "estimated_cost": 1.75,
                ],
            ],
            "by_task": [
                [
                    "task": "compression", "input_tokens": 250_000, "output_tokens": 50_000,
                    "api_calls": 24, "estimated_cost": 1.75,
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
        let selectedPages = ProcessInfo.processInfo.environment["HERM_ACTIVITY_REVIEW_PAGES"]?.split(separator: ",")
            .map(String.init)
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
                for page in ["day", "week", "month", "spend", "details"] {
                    if let selectedPages, !selectedPages.contains(page) { continue }
                    let work = page != "spend"
                    let height: CGFloat = work ? 1000 : (width < 900 ? 1700 : 1250)
                    defaults.set(work ? page : "day", forKey: "dock.calendar.scope")
                    let details = control.workCalendar!.range(
                        from: calendar.startOfDay(for: now), to: now)
                    let content =
                        page == "details"
                        ? AnyView(
                            VStack(spacing: 16) {
                                WorkActivityBreakdown(activity: details)
                                WorkActivityUsageView(activity: details).dockCard(padding: 14)
                            }.frame(maxHeight: .infinity, alignment: .top))
                        : work
                            ? AnyView(WorkActivityView(control: control, repoPaths: []))
                            : AnyView(ScrollView { UsageWorkspaceView(control: control, availableWidth: width - 40) })
                    let view = content.defaultAppStorage(defaults).padding(20)
                        .frame(width: width, height: height)
                        .background(Color.dockCanvas).background(dark ? Color.black : Color.white)
                        .dockThemedRoot().environment(\.colorScheme, dark ? .dark : .light)
                    let host = NSHostingView(rootView: view)
                    host.frame = NSRect(x: 0, y: 0, width: width, height: height)
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
                    if !work, ProcessInfo.processInfo.environment["HERM_ACTIVITY_SCROLL_REVIEW"] == "1" {
                        await reviewScrolling(host, control: control, label: "\(theme.rawValue)-\(width)")
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

    @Test func renderProviderRanking() async throws {
        guard let path = ProcessInfo.processInfo.environment["HERM_ACTIVITY_REVIEW_DIR"] else { return }
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        let report = ControlCenterModel.parseTokenUsage(
            ["period_days": 30, "totals": ["total_estimated_cost": 9, "total_sessions": 20]],
            models: [
                "period_days": 30,
                "models": [
                    [
                        "model": "example", "provider": "anthropic", "input_tokens": 6_000,
                        "output_tokens": 600, "estimated_cost": 6,
                    ],
                    [
                        "model": "example", "provider": "openrouter", "input_tokens": 2_000,
                        "output_tokens": 200, "estimated_cost": 2,
                    ],
                    [
                        "model": "example", "provider": "", "input_tokens": 1_000,
                        "output_tokens": 100, "estimated_cost": 1,
                    ],
                    [
                        "model": "included", "provider": "openai-codex", "input_tokens": 5_000,
                        "output_tokens": 500, "estimated_cost": 0,
                    ],
                ],
            ])
        let content = UsageSpendSummary(report: report, grouping: .constant(.providers))
            .padding(18).frame(width: 340, height: 460, alignment: .topLeading)
            .background(Color.dockCanvas).background(Color.white)
            .dockThemedRoot().environment(\.colorScheme, .light)
        let host = NSHostingView(rootView: content)
        host.frame = NSRect(x: 0, y: 0, width: 340, height: 460)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: path).appendingPathComponent("provider-ranking.png"))
    }

    private func reviewScrolling(_ host: NSView, control: ControlCenterModel, label: String) async {
        func scrollView(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
        }
        guard let scroll = scrollView(in: host), let document = scroll.documentView else { return }
        let distance = max(0, document.bounds.height - scroll.contentView.bounds.height)
        var samples: [Double] = []
        for step in 0..<30 {
            let start = CFAbsoluteTimeGetCurrent()
            control.isRefreshing.toggle()  // Unrelated publications must not rebuild the analytics report.
            let fraction = Double(step < 15 ? step : 29 - step) / 14
            scroll.contentView.scroll(to: NSPoint(x: 0, y: distance * fraction))
            scroll.reflectScrolledClipView(scroll.contentView)
            await Task.yield()
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            samples.append((CFAbsoluteTimeGetCurrent() - start) * 1_000)
        }
        let sorted = samples.sorted()
        print("Activity scroll fixture \(label): p95 \(sorted[28]) ms; max \(sorted[29]) ms")
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        host.layoutSubtreeIfNeeded()
    }
}
