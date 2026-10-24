import AppKit
import SwiftUI
import Testing

@testable import Herm

@MainActor
struct SessionTraceRenderTests {
    @Test func renderWaterfall() async throws {
        guard let directory = ProcessInfo.processInfo.environment["HERM_TRACE_UI_DIR"] else {
            return
        }
        let root = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let saved = DockThemeRuntime.current
        defer {
            DockThemeRuntime.current = saved
            DockThemeRuntime.revision &+= 1
        }
        let start = Date(timeIntervalSince1970: 1_000)
        func call(
            _ id: String, _ title: String, _ offset: Double, _ duration: Double, _ owner: String?
        )
            -> ActiveToolCall
        {
            ActiveToolCall(
                id: id, name: title,
                input: "Inspect the existing implementation and update the pricing page.",
                context: "",
                startedAt: start.addingTimeInterval(offset),
                result: "Updated the pricing page and checked the result.", isComplete: true,
                completedAt: start.addingTimeInterval(offset + duration), agentID: owner,
                traceDuration: duration, traceTiming: .observed,
                traceOutcome: id == "retry" ? "Failed" : nil)
        }
        let calls = [
            call("read", "Read brand voice", 1, 2, "writer"),
            call("figma", "Read pricing frames", 5, 2, "writer"),
            call("retry", "Draft plan copy", 8, 4, "writer"),
            call("draft", "Draft plan copy", 13, 11, "writer"),
            call("save", "Save draft", 25, 1.2, "writer"),
            call("branch", "Create branch", 14, 1.2, "coder"),
            call("page", "Write pricing page", 16, 17, "coder"),
            call("prices", "Create prices", 34, 1.4, "coder"),
            call("tests", "Run checkout tests", 36, 4, "coder"),
        ]
        let agents = [
            HermesSubagent(
                id: "writer", name: "Writer", goal: "Draft pricing copy", status: "completed",
                model: "Sonnet",
                startedAt: start, completedAt: start.addingTimeInterval(27), durationSeconds: 27),
            HermesSubagent(
                id: "coder", name: "Coder", goal: "Build the pricing page", status: "completed",
                model: "GPT",
                startedAt: start.addingTimeInterval(14), completedAt: start.addingTimeInterval(40),
                durationSeconds: 26),
        ]
        let turns = SessionTraceProjection.make(
            turns: [
                .init(id: "fixture", title: "Build the pricing page", start: start, calls: calls)
            ],
            live: [], agents: agents, working: false, connected: true)
        for theme: DockThemeID in [.clean, .island, .glass, .mono, .eInk] {
            DockThemeRuntime.current = theme
            DockThemeRuntime.revision &+= 1
            for width in [380.0, 760.0] {
                let view = SessionTraceCanvas(
                    turns: turns, connected: true, initialSelectionID: "tool:agent:5:coder:page"
                )
                .padding(.horizontal, 12)
                .frame(width: width, height: 800)
                .background(Color.dockCanvas).dockThemedRoot()
                let host = NSHostingView(rootView: view)
                host.frame = NSRect(x: 0, y: 0, width: width, height: 800)
                let window = NSWindow(
                    contentRect: host.frame, styleMask: [.borderless], backing: .buffered,
                    defer: false)
                window.contentView = host
                window.orderFrontRegardless()
                for _ in 0..<4 {
                    host.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(80))
                }
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try #require(bitmap.representation(using: .png, properties: [:]))
                    .write(
                        to: root.appendingPathComponent("trace-\(theme.rawValue)-\(Int(width)).png")
                    )
                window.orderOut(nil)
            }
        }
    }
    @Test func renderOffscreenSteps() async throws {
        guard let directory = ProcessInfo.processInfo.environment["HERM_TRACE_UI_DIR"] else { return }
        let root = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let saved = DockThemeRuntime.current
        defer {
            DockThemeRuntime.current = saved
            DockThemeRuntime.revision &+= 1
        }
        let start = Date().addingTimeInterval(-7_800)
        let rows = [
            SessionTraceRow(
                id: "model", kind: .model, title: "Model call", start: start, duration: 15, timing: .observed),
            SessionTraceRow(
                id: "earlier", kind: .tool, title: "Run python3", start: start.addingTimeInterval(2_207),
                duration: 1, timing: .runtime, toolName: "terminal"),
            SessionTraceRow(
                id: "instant", kind: .tool, title: "Skill View", start: start.addingTimeInterval(7_680),
                duration: 0, timing: .runtime, toolName: "skill_view"),
            SessionTraceRow(
                id: "live", kind: .compaction, title: "Compacting context", start: start.addingTimeInterval(7_690),
                timing: .observed, active: true),
            SessionTraceRow(
                id: "missing-duration", kind: .tool, title: "Tool without duration",
                start: start.addingTimeInterval(7_790), timing: .unavailable),
        ]
        for theme: DockThemeID in [.clean, .island, .glass, .mono, .eInk] {
            DockThemeRuntime.current = theme
            DockThemeRuntime.revision &+= 1
            for width in [380.0, 760.0] {
                for selection: String? in [nil, "earlier"] {
                    let view = SessionTraceCanvas(
                        turns: [.init(id: "long", title: "Long request", start: start, rows: rows)],
                        connected: true, isVisible: false, initialSelectionID: selection, listMaxHeight: 240
                    )
                    .padding(.horizontal, 12).frame(width: width, height: 800)
                    .background(Color.dockCanvas).dockThemedRoot()
                    let host = NSHostingView(rootView: view)
                    host.frame = NSRect(x: 0, y: 0, width: width, height: 800)
                    let window = NSWindow(
                        contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                    window.contentView = host
                    window.orderFrontRegardless()
                    for _ in 0..<4 {
                        host.layoutSubtreeIfNeeded()
                        try await Task.sleep(for: .milliseconds(80))
                    }
                    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let state = selection == nil ? "live" : "selected"
                    try #require(bitmap.representation(using: .png, properties: [:]))
                        .write(
                            to: root.appendingPathComponent(
                                "trace-offscreen-\(theme.rawValue)-\(Int(width))-\(state).png"))
                    window.orderOut(nil)
                }
            }
        }
    }

    @Test func renderLiveGrowth() async throws {
        guard let directory = ProcessInfo.processInfo.environment["HERM_TRACE_UI_DIR"] else {
            return
        }
        let root = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let saved = DockThemeRuntime.current
        defer {
            DockThemeRuntime.current = saved
            DockThemeRuntime.revision &+= 1
        }
        DockThemeRuntime.current = .island
        DockThemeRuntime.revision &+= 1
        let start = Date().addingTimeInterval(-18)
        let call = ActiveToolCall(
            id: "live", name: "terminal", input: "swift test", context: "swift test",
            startedAt: start.addingTimeInterval(4), isComplete: false, agentID: "coder",
            traceTiming: .observed)
        let agent = HermesSubagent(
            id: "coder", name: "Coder", goal: "Run focused checks", status: "running",
            startedAt: start)
        let turns = SessionTraceProjection.make(
            turns: [.init(id: "live", title: "Run focused checks", start: start)],
            live: [call], agents: [agent], working: true, connected: true)
        let host = NSHostingView(
            rootView: SessionTraceCanvas(turns: turns, connected: true)
                .padding(.horizontal, 12).frame(width: 760, height: 640).background(
                    Color.dockCanvas
                ).dockThemedRoot())
        host.frame = NSRect(x: 0, y: 0, width: 760, height: 640)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        for frame in 0..<12 {
            try await Task.sleep(for: .milliseconds(120))
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(
                    to: root.appendingPathComponent(String(format: "trace-live-%02d.png", frame)))
        }
    }

}
