import AppKit
import SwiftUI
import Testing

@testable import Herm

@MainActor
struct WorkspaceScrollPerformanceTests {
    private enum Surface: String, CaseIterable {
        case sessions, usage, settings
    }

    private struct Content: View {
        let surface: Surface
        let sessions = ScrollPerformanceFixture.standard.sessions

        private var report: TokenUsageReport {
            let models = (0..<100).map { index in
                TokenUsageReport.Model(
                    model: "fixture-model-\(index)", inputTokens: 100, outputTokens: 50,
                    estimatedCost: 0.01, sessions: 1, apiCalls: 1, tasks: [])
            }
            return TokenUsageReport(
                days: 30, inputTokens: 10_000, outputTokens: 5_000, cacheReadTokens: 0,
                reasoningTokens: 0, estimatedCost: 1, actualCost: 1, sessions: 100, apiCalls: 100,
                daily: [], models: models, tasks: [], tools: [], skills: [], skillLoads: 0, distinctSkills: 0)
        }

        var body: some View {
            DockWorkspaceShell(
                toolbarHeight: 0, rail: { Color.dockSidebar.frame(width: 52) },
                content: {
                    ScrollView {
                        switch surface {
                        case .sessions:
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(sessions) { session in
                                    SessionNavSidebarSessionRow(
                                        session: session, selectedSessionID: nil, sessionStatus: .none,
                                        style: DockThemePalette(theme: DockThemeRuntime.current), repositoryName: nil,
                                        isPinned: false, isActive: false, isDeleting: false,
                                        isUpdatingVisibility: false, isRenaming: false, onSelect: { _ in },
                                        onTogglePin: { _ in }, onRename: { _, _ in false },
                                        onToggleHidden: { _, _ in false }, onRequestDelete: { _ in })
                                }
                            }
                        case .usage:
                            UsageReportContent(report: report, isWide: false)
                        case .settings:
                            SettingsSection(title: "Preferences", subtitle: "", tint: .dockAccent) {
                                ForEach(0..<100, id: \.self) { index in
                                    SettingsPreferenceRow(title: "Preference \(index)", detail: "A fixture setting") {
                                        Text("Enabled")
                                    }
                                }
                            }
                        }
                    }
                }
            )
            .dockThemedRoot()
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HERM_SCROLL_PROFILE"] == "1"))
    func profileWorkspaceSurfaces() async throws {
        _ = NSApplication.shared
        for surface in Surface.allCases {
            for pass in ["first", "repeat"] {
                let host = NSHostingView(rootView: Content(surface: surface))
                host.sizingOptions = []
                host.frame = NSRect(x: 0, y: 0, width: 640, height: 500)
                let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
                window.contentView = host
                window.orderFrontRegardless()
                defer { window.orderOut(nil) }
                for _ in 0..<5 {
                    host.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(20))
                }
                func scrollView(in view: NSView) -> NSScrollView? {
                    if let scroll = view as? NSScrollView,
                        (scroll.documentView?.bounds.height ?? 0) > scroll.contentView.bounds.height
                    {
                        return scroll
                    }
                    return view.subviews.lazy.compactMap(scrollView).first
                }
                let scroll = try #require(scrollView(in: host))
                let document = try #require(scroll.documentView)
                let maximum = max(0, document.bounds.height - scroll.contentView.bounds.height)
                let startedCPU = mainThreadCPUMilliseconds()
                var steps: [Double] = []
                for step in 0..<120 {
                    let started = DispatchTime.now().uptimeNanoseconds
                    let progress = CGFloat(step < 60 ? step : 120 - step) * 12
                    let top = min(maximum, progress)
                    let origin = document.isFlipped ? top : maximum - top
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: origin))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    host.layoutSubtreeIfNeeded()
                    host.displayIfNeeded()
                    steps.append(Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
                    try await Task.sleep(for: .milliseconds(8))
                }
                let cpu = mainThreadCPUMilliseconds() - startedCPU
                let sorted = steps.sorted()
                print(
                    "workspace_scroll surface=\(surface.rawValue) pass=\(pass) p50_ms=\(sorted[sorted.count / 2]) p95_ms=\(sorted[Int(Double(sorted.count - 1) * 0.95)]) max_ms=\(sorted.last ?? 0) main_cpu_ms=\(cpu)"
                )
                window.orderOut(nil)
            }
        }
    }
}
