import AppKit
import SwiftUI
import Testing
@testable import Herm

private struct WorkspaceVisualTransport: GitHubIssueTransport {
    var restrictedProjects = false
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let path = request.url!.path
        let sha = String(repeating: "a", count: 40)
        let item: [String: Any] = ["number": 1, "node_id": "PR_fixture", "title": "Improve workspace navigation", "body": "## Description\n\nReuse the **shared Markdown renderer**.\n\n- Preserve drafts\n- Show accurate readiness\n\n```swift\nlet state = WorkspaceState()\n```", "state": "open", "repository_url": "https://api.github.com/repos/owner/repo", "user": ["login": "ada"], "head": ["ref": "feature/navigation", "sha": sha], "base": ["ref": "main", "sha": sha], "changed_files": 0, "mergeable": false, "draft": true, "labels": ["type/bug", "comp/cli", "comp/cron", "P3", "sweeper:risk-automation"].enumerated().map { ["name": $0.element, "node_id": "label-\($0.offset)"] }, "assignees": [["login": "ada"]], "html_url": "https://github.com/owner/repo/pull/1"]
        let payload: Any
        if path == "/graphql" {
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let query = body["query"] as! String
            if query.contains("projectItems") && restrictedProjects { payload = ["errors": [["type": "FORBIDDEN", "message": "Projects permission denied"]]] }
            else if query.contains("projectItems") { payload = ["data": ["node": ["projectItems": ["nodes": [], "pageInfo": ["hasNextPage": false]]]]] }
            else if query.contains("closingIssuesReferences") { payload = ["data": ["node": ["closingIssuesReferences": ["nodes": [], "pageInfo": ["hasNextPage": false]]]]] }
            else if query.contains("closedByPullRequestsReferences") { payload = ["data": ["node": ["closedByPullRequestsReferences": ["nodes": [], "pageInfo": ["hasNextPage": false]]]]] }
            else if query.contains("linkedBranches") { payload = ["data": ["node": ["linkedBranches": ["nodes": [], "pageInfo": ["hasNextPage": false]]]]] }
            else { payload = ["data": ["node": ["id": "PR_fixture", "headRefOid": sha, "baseRefOid": sha, "viewerCanUpdate": true, "mergeable": "CONFLICTING", "mergeStateStatus": "DIRTY", "state": "OPEN", "isDraft": false, "reviewDecision": "REVIEW_REQUIRED", "repository": ["viewerPermission": "READ", "squashMergeAllowed": true]]]] }
        } else if path == "/repos/owner/repo/pulls/1" || path == "/repos/owner/repo/issues/1" { payload = item }
        else if path == "/repos/owner/repo" { payload = ["permissions": ["triage": true]] }
        else if path.hasSuffix("check-runs") { payload = ["check_runs": []] }
        else { payload = [] }
        return (try JSONSerialization.data(withJSONObject: payload), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@MainActor
struct GitHubWorkspaceVisualTests {
    @Test func windowDragSurfaceDoesNotCoverPullRequestTabs() async throws {
        let repo = GitHubReferenceParser.repository("owner/repo")!
        let center = PullRequestCenterModel(api: PullRequestCenterAPI(transport: WorkspaceVisualTransport()))
        await center.open(.init(repository: repo, number: 1, kind: .pullRequest))
        await center.loadSelectedDetail()
        let root = PullRequestDetailView(center: center, onOpenChat: { _ in })
            .environment(\.dockTitleRow, DockTitleRow(height: 52, leadingClearance: 28))
            .frame(width: 1000, height: 950)
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 950), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        for _ in 0..<4 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(80)) }
        func strips(in view: NSView) -> [NSView] {
            (view is TitlebarDoubleClickArea.Strip ? [view] : []) + view.subviews.flatMap { strips(in: $0) }
        }
        let strip = try #require(strips(in: host).first)
        let dragFrame = host.convert(strip.bounds, from: strip)
        #expect(dragFrame.minX > 220) // Summary, Code, and Reviews occupy the leading header.
        #expect(dragFrame.maxX < 990) // Trailing actions also retain their own hit areas.
        #expect(dragFrame.height <= 52)
    }
    @Test func renderWorkspaceThemes() async throws {
        guard let directory = ProcessInfo.processInfo.environment["GITHUB_WORKSPACE_SNAPSHOT_DIR"] else { return }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let savedTheme = DockThemeRuntime.current; let savedRevision = DockThemeRuntime.revision
        defer { DockThemeRuntime.current = savedTheme; DockThemeRuntime.revision = savedRevision }
        let panels = ProcessInfo.processInfo.environment["GITHUB_PANEL_SNAPSHOTS"] == "1"
        let transport = WorkspaceVisualTransport(restrictedProjects: panels)
        let repo = GitHubReferenceParser.repository("owner/repo")!
        let pr = PullRequestCenterModel(api: PullRequestCenterAPI(transport: transport))
        await pr.open(.init(repository: repo, number: 1, kind: .pullRequest))
        await pr.loadSelectedDetail()
        let issues = IssueCenterModel(api: GitHubIssueCenterAPI(transport: transport))
        await issues.open(.init(repository: repo, number: 1, kind: .issue))
        await issues.loadSelectedDetail()
        for theme: DockThemeID in [.notebook, .terminal, .glass, .mono] {
            let dark = theme != .notebook
            DockThemeRuntime.current = theme; DockThemeRuntime.revision &+= 1
            for width: CGFloat in (panels ? [380, 760] : [540, 1000]) {
                let root = Group {
                    if panels, let record = pr.selected {
                        ScrollView {
                        VStack(spacing: 12) {
                            PullRequestReadinessView(center: pr, record: record)
                            PullRequestLandingView(record: record, client: pr.api.client, onChanged: {})
                            GitHubMetadataView(reference: record.reference, client: pr.api.client)
                            Spacer(minLength: 0)
                        }.padding(16)
                        }
                    } else {
                        HStack(spacing: 1) {
                            PullRequestDetailView(center: pr, onOpenChat: { _ in })
                            if width > 600 { IssueDetailView(center: issues, onOpenChat: { _ in }) }
                        }
                    }
                }
                .frame(width: width, height: 950).background(Color.dockCanvas).dockThemedRoot()
                .environment(\.colorScheme, dark ? .dark : .light)
                let host = NSHostingView(rootView: root); host.frame = CGRect(x: 0, y: 0, width: width, height: 950)
                let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua); window.contentView = host
                window.orderFrontRegardless()
                for _ in 0..<4 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(80)) }
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: bitmap)
                let data = try #require(bitmap.representation(using: .png, properties: [:]))
                try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("github-\(Int(width))-\(theme.rawValue).png"))
                window.orderOut(nil)
                #expect(bitmap.pixelsWide > 0)
            }
        }
    }
}
