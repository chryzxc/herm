import AppKit
import SwiftUI
import Testing

@testable import Herm

private actor PullRequestDetailRenderTransport: GitHubIssueTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let path = request.url!.path
        let payload: Any
        if path.hasSuffix("/pulls/93") || path.hasSuffix("/issues/93") {
            payload = [
                "number": 93, "node_id": "PR_fixture", "title": "Add bounded synthetic measurement tooling",
                "state": "open", "draft": true, "user": ["login": "author"],
                "html_url": "https://github.com/owner/repo/pull/93",
                "created_at": "2026-10-22T00:00:00Z", "updated_at": "2026-10-23T00:00:00Z",
                "head": ["ref": "perf/release-baselines", "sha": "abc"], "base": ["ref": "main", "sha": "def"],
                "changed_files": 2, "additions": 55, "deletions": 7, "comments": 1,
                "labels": [], "assignees": [],
                "body": """
                ## Summary
                Add bounded measurement tooling for the release performance baseline.

                ## Changes
                - Capture synchronous Markdown preparation and diff parsing.
                - Export samples and explicit unavailable-measurement reasons.
                - Bound command execution and preserve existing output.

                ## Behavior
                Measurements run only when explicitly requested. Production behavior is unchanged.

                ## Tests
                - Focused measurement fixtures pass.
                - Invalid output paths preserve existing data.
                """,
            ] as [String: Any]
        } else if path == "/graphql" {
            payload = ["data": ["node": ["projectItems": ["nodes": [], "pageInfo": ["hasNextPage": false]]]]]
        } else if path == "/repos/owner/repo" {
            payload = ["permissions": ["push": false, "triage": false]]
        } else { payload = [] as [String] }
        return (try JSONSerialization.data(withJSONObject: payload),
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@MainActor
struct PullRequestDetailRenderTests {
    @Test func renderWideAndNarrowDetailsAcrossThemes() async throws {
        guard let directory = ProcessInfo.processInfo.environment["HERM_PR_DETAIL_UI_DIR"] else { return }
        let root = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let savedTheme = DockThemeRuntime.current
        let savedAppearance = NSApplication.shared.appearance
        defer {
            DockThemeRuntime.current = savedTheme
            DockThemeRuntime.revision &+= 1
            NSApplication.shared.appearance = savedAppearance
        }
        let suite = "PullRequestDetailUI.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let runtime = DockModel(sessionAgentStateFileURL: root.appendingPathComponent("agents.json"),
            defaults: defaults, initialSessionID: "selected-workspace", botActivityFileURL: root.appendingPathComponent("bots.json"), rpcClient: PullRequestChatRPC())
        defer { runtime.shutdown() }
        let router = ChatContextRouter()
        router.model = runtime
        let center = PullRequestCenterModel(api: PullRequestCenterAPI(transport: PullRequestDetailRenderTransport()))
        let repository = try #require(GitHubReferenceParser.repository("owner/repo"))
        #expect(await center.open(GitHubItemReference(repository: repository, number: 93, kind: .pullRequest)))
        let record = try #require(center.selected)
        center.filesByID[record.id] = [PullRequestFile(path: "Tests/Measurements.swift", status: "modified", additions: 55, deletions: 7,
            patch: "@@ -1 +1 @@\n-old\n+new", webURL: nil)]
        center.details.fileRevisions[record.id] = record.diffRevision
        center.commitsByID[record.id] = [PullRequestCommit(id: "abc", message: "Bound measurements and preserve existing output", author: "author", authorAvatarURL: nil, committedAt: .now, webURL: nil)]
        let appearances = DockThemeID.allCases.flatMap { theme -> [(DockThemeID, Bool)] in
            let modes = theme.appearance == .system ? [false, true] : [theme.appearance == .dark]
            return modes.map { (theme, $0) }
        }
        for (theme, dark) in appearances {
            DockThemeRuntime.current = theme
            DockThemeRuntime.revision &+= 1
            NSApplication.shared.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let appearanceName = "\(theme.rawValue)-\(dark ? "dark" : "light")"
            for width in [400.0, 1120.0] {
                let view = PullRequestDetailView(center: center, onOpenChat: { _ in })
                    .environment(\.chatContextRouter, router)
                    .frame(width: width, height: 850)
                    .background(Color.dockOpaqueCanvas).dockThemedRoot()
                let host = NSHostingView(rootView: view)
                host.frame = NSRect(x: 0, y: 0, width: width, height: 850)
                let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = host
                window.orderFrontRegardless()
                defer { window.orderOut(nil) }
                for _ in 0..<5 {
                    host.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(100))
                }
                let url = root.appendingPathComponent("pr-\(appearanceName)-\(Int(width)).png")
                // Material layers require a live compositor check; the chat is captured separately below.
                if theme != .glass {
                    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
                }
            }
            let rpc = PullRequestChatRPC()
            rpc.history = ["messages": [
                ["role": "user", "content": "What should I review first?"],
                ["role": "assistant", "content": "Start with **timeout handling**, then check that existing output is preserved.\n\n- Verify process termination.\n- Check invalid output paths.\n- Run the focused measurement suite."],
            ]]
            let chat = PullRequestChatModel()
            chat.text = "What should I review first?"
            await chat.submit(record, client: rpc, drafts: QuickDraftStore(directory: nil))
            await chat.refresh(client: rpc)
            chat.text = "Explain the timeout tests"
            let chatHost = NSHostingView(rootView: PullRequestFloatingChatView(chat: chat, runtime: runtime, record: record, expanded: true)
                .padding(20).frame(width: 400, height: 440)
                .background(Color.dockOpaqueCanvas).dockThemedRoot())
            chatHost.frame = NSRect(x: 0, y: 0, width: 400, height: 440)
            let chatWindow = NSWindow(contentRect: chatHost.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            chatWindow.contentView = chatHost
            chatWindow.orderFrontRegardless()
            defer { chatWindow.orderOut(nil) }
            for _ in 0..<4 {
                chatHost.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(80))
            }
            let bitmap = try #require(chatHost.bitmapImageRepForCachingDisplay(in: chatHost.bounds))
            chatHost.cacheDisplay(in: chatHost.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: root.appendingPathComponent("chat-\(appearanceName)-400.png"))
        }
        #expect(runtime.sessionID == "selected-workspace")
    }
}
