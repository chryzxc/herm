import AppKit
import SwiftUI
import Testing

@testable import Herm

private struct WorkspaceVisualTransport: GitHubIssueTransport {
    var cleanReadiness = false
    var merged = false
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let path = request.url!.path
        let sha = String(repeating: "a", count: 40)
        var item: [String: Any] = [
            "number": 1, "node_id": "PR_fixture", "title": "Improve workspace navigation",
            "body":
                "## Description\n\nReuse the **shared Markdown renderer**.\n\n- Preserve drafts\n- Show accurate readiness\n\n```swift\nlet state = WorkspaceState()\n```",
            "state": "open", "repository_url": "https://api.github.com/repos/owner/repo", "user": ["login": "ada"],
            "head": ["ref": "feature/navigation", "sha": sha], "base": ["ref": "main", "sha": sha], "changed_files": 5,
            "additions": 108, "deletions": 22, "mergeable": cleanReadiness, "draft": !cleanReadiness,
            "labels": ["type/bug", "comp/cli", "comp/cron", "P3", "sweeper:risk-automation"].enumerated().map {
                [
                    "name": $0.element, "node_id": "label-\($0.offset)",
                    "color": ["d73a4a", "0075ca", "0e8a16", "fbca04", "5319e7"][$0.offset],
                ]
            }, "assignees": [["login": "ada"]], "html_url": "https://github.com/owner/repo/pull/1",
        ]
        if merged {
            item["state"] = "closed"
            item["draft"] = false
            item["merged_at"] = "2026-10-18T00:01:00Z"
        }
        let payload: Any
        if path == "/graphql" {
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let query = body["query"] as! String
            if query.contains("closingIssuesReferences") {
                payload = [
                    "data": ["node": ["closingIssuesReferences": ["nodes": [], "pageInfo": ["hasNextPage": false]]]]
                ]
            } else if query.contains("closedByPullRequestsReferences") {
                payload = [
                    "data": [
                        "node": ["closedByPullRequestsReferences": ["nodes": [], "pageInfo": ["hasNextPage": false]]]
                    ]
                ]
            } else if query.contains("viewerCanDeleteHeadRef") {
                payload = [
                    "data": [
                        "node": [
                            "id": "PR_fixture", "state": "MERGED", "headRefOid": sha, "viewerCanDeleteHeadRef": true,
                            "headRef": [
                                "id": "BRANCH", "name": "feature/navigation", "prefix": "refs/heads/",
                                "target": ["oid": sha], "branchProtectionRule": NSNull(),
                                "repository": [
                                    "id": "REPO", "nameWithOwner": "owner/repo", "defaultBranchRef": ["id": "MAIN"],
                                ],
                            ],
                        ]
                    ]
                ]
            } else if query.contains("linkedBranches") {
                payload = ["data": ["node": ["linkedBranches": ["nodes": [], "pageInfo": ["hasNextPage": false]]]]]
            } else {
                payload = [
                    "data": [
                        "node": [
                            "id": "PR_fixture", "headRefOid": sha, "baseRefOid": sha, "viewerCanUpdate": true,
                            "mergeable": cleanReadiness ? "MERGEABLE" : "CONFLICTING",
                            "mergeStateStatus": cleanReadiness ? "UNSTABLE" : "DIRTY", "state": "OPEN",
                            "isDraft": false, "reviewDecision": cleanReadiness ? "APPROVED" : "REVIEW_REQUIRED",
                            "repository": [
                                "viewerPermission": cleanReadiness ? "WRITE" : "READ", "squashMergeAllowed": true,
                            ],
                        ]
                    ]
                ]
            }
        } else if path == "/repos/owner/repo/pulls/1" || path == "/repos/owner/repo/issues/1" {
            payload = item
        } else if path == "/repos/owner/repo" {
            payload = ["permissions": ["triage": true]]
        } else if path.hasSuffix("/files") {
            payload = [
                "Sources/App.swift", "Tests/AppTests.swift", "Tests/Mocks/MockClient.swift", "docs/setup.md",
                ".github/workflows/ci.yml",
            ].enumerated().map { index, path in
                [
                    "filename": path, "status": "modified", "additions": index == 0 ? 100 : 2,
                    "deletions": index == 0 ? 18 : 1,
                ] as [String: Any]
            }
        } else if path.hasSuffix("/timeline") {
            payload = [1, 2].map {
                [
                    "id": $0, "event": "labeled", "actor": ["login": "ada"],
                    "label": ["name": $0 == 1 ? "enhancement" : "type: feature"], "created_at": "2026-10-21T00:00:00Z",
                ] as [String: Any]
            }
        } else if path.hasSuffix("check-runs") {
            payload = [
                "check_runs": cleanReadiness
                    ? [["id": 1, "name": "Build", "status": "completed", "conclusion": "failure"]] : []
            ]
        } else {
            payload = []
        }
        return (
            try JSONSerialization.data(withJSONObject: payload),
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
    }
}

@MainActor
struct GitHubWorkspaceVisualTests {
    @Test func renderGitHubNavigation() async throws {
        guard let directory = ProcessInfo.processInfo.environment["GITHUB_NAVIGATION_SNAPSHOT_DIR"] else { return }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let savedTheme = DockThemeRuntime.current
        let savedRevision = DockThemeRuntime.revision
        defer {
            DockThemeRuntime.current = savedTheme
            DockThemeRuntime.revision = savedRevision
        }
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let transport = WorkspaceVisualTransport()
        let repo = GitHubReferenceParser.repository("owner/repo")!
        let pr = PullRequestCenterModel(
            api: PullRequestCenterAPI(transport: transport), details: PullRequestDetailStore())
        let issues = IssueCenterModel(api: GitHubIssueCenterAPI(transport: transport))
        await pr.open(.init(repository: repo, number: 1, kind: .pullRequest))
        await issues.open(.init(repository: repo, number: 1, kind: .issue))
        for (theme, dark): (DockThemeID, Bool) in [
            (.clean, false), (.clean, true), (.glass, false), (.glass, true), (.mono, true),
        ] {
            DockThemeRuntime.current = theme
            DockThemeRuntime.revision &+= 1
            for width: CGFloat in [440, 960, 1200] {
                for section in [GitHubWorkspaceSection.pullRequests, .issues] {
                    let root = GitHubWorkspace(repositories: GitHubRepositoriesModel(), selection: .constant(section)) {
                        if section == .pullRequests {
                            PullRequestWorkspace(center: pr, projects: [], onOpenChat: { _ in })
                        } else {
                            IssueWorkspacePage(center: issues, projects: [], onOpenChat: { _ in })
                        }
                    }
                    .defaultAppStorage(defaults)
                    .environment(\.dockTitleRow, DockTitleRow(height: 52, leadingClearance: 28))
                    .frame(width: width, height: 800)
                    // Native backdrop capture depends on the host desktop; keep the tint reproducible.
                    .background(DockThemePalette(theme: theme).windowBackground)
                    .background(dark ? Color.black : Color.white)
                    .dockThemedRoot()
                    .environment(\.colorScheme, dark ? .dark : .light)
                    let host = NSHostingView(rootView: root)
                    host.frame = CGRect(x: 0, y: 0, width: width, height: 800)
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
                    let data = try #require(bitmap.representation(using: .png, properties: [:]))
                    try data.write(
                        to: URL(fileURLWithPath: directory).appendingPathComponent(
                            "github-navigation-\(section.rawValue)-\(Int(width))-\(theme.rawValue)-\(dark ? "dark" : "light").png"
                        ))
                    window.orderOut(nil)
                }
            }
        }
    }

    @Test func iconActionsKeepTheirExactFootprintAcrossThemesAndStates() {
        let savedTheme = DockThemeRuntime.current
        defer { DockThemeRuntime.current = savedTheme }
        for theme: DockThemeID in [.notebook, .terminal, .glass, .mono] {
            DockThemeRuntime.current = theme
            for size: CGFloat in [24, 28] {
                for busy in [false, true] {
                    for enabled in [false, true] {
                        let host = NSHostingView(
                            rootView:
                                DockIconButton(
                                    icon: .arrowsClockwise, label: "Refresh", isBusy: busy, size: size,
                                    style: DockThemePalette(theme: theme), action: {}
                                )
                                .disabled(!enabled).dockThemedRoot())
                        let measured = host.fittingSize
                        #expect(abs(measured.width - size) < 0.5)
                        #expect(abs(measured.height - size) < 0.5)
                    }
                }
            }
        }
    }
    @Test func windowDragSurfaceDoesNotCoverPullRequestTabs() async throws {
        let repo = GitHubReferenceParser.repository("owner/repo")!
        let center = PullRequestCenterModel(api: PullRequestCenterAPI(transport: WorkspaceVisualTransport()))
        await center.open(.init(repository: repo, number: 1, kind: .pullRequest))
        await center.loadSelectedDetail()
        let root = PullRequestDetailView(center: center, onOpenChat: { _ in })
            .environment(\.dockTitleRow, DockTitleRow(height: 52, leadingClearance: 28))
            .frame(width: 1000, height: 950)
        let host = NSHostingView(rootView: root)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1000, height: 950), styleMask: [.borderless], backing: .buffered,
            defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        for _ in 0..<4 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(80))
        }
        func strips(in view: NSView) -> [NSView] {
            (view is TitlebarDoubleClickArea.Strip ? [view] : []) + view.subviews.flatMap { strips(in: $0) }
        }
        let strip = try #require(strips(in: host).first)
        let dragFrame = host.convert(strip.bounds, from: strip)
        #expect(dragFrame.minX >= 210)  // Shared Summary, Code, and Reviews tabs occupy the leading header.
        #expect(dragFrame.maxX < 990)  // Trailing actions also retain their own hit areas.
        #expect(dragFrame.height <= 52)
    }
    @Test func windowDragSurfaceDoesNotCoverIssueActions() async throws {
        let repo = GitHubReferenceParser.repository("owner/repo")!
        let center = IssueCenterModel(api: GitHubIssueCenterAPI(transport: WorkspaceVisualTransport()))
        await center.open(.init(repository: repo, number: 1, kind: .issue))
        await center.loadSelectedDetail()
        let root = IssueDetailView(center: center, onOpenChat: { _ in })
            .environment(\.dockTitleRow, DockTitleRow(height: 52, leadingClearance: 28))
            .frame(width: 1000, height: 950)
        let host = NSHostingView(rootView: root)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1000, height: 950), styleMask: [.borderless], backing: .buffered,
            defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        for _ in 0..<4 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(80))
        }
        func strips(in view: NSView) -> [NSView] {
            (view is TitlebarDoubleClickArea.Strip ? [view] : []) + view.subviews.flatMap { strips(in: $0) }
        }
        let strip = try #require(strips(in: host).first)
        let dragFrame = host.convert(strip.bounds, from: strip)
        #expect(dragFrame.minX > 100)  // Repository identity stays outside the drag surface.
        #expect(dragFrame.maxX < 990)  // Trailing actions also retain their own hit areas.
        #expect(dragFrame.height <= 52)
    }
    private func closedIssueFixture(_ issue: GitHubIssueRecord) -> GitHubIssueRecord {
        var row = issue
        row.state = "closed"
        row.assignees = ["ada"]
        return row
    }

    private func rowFixture(_ record: PullRequestRecord, index: Int) -> PullRequestRecord {
        var row = record
        row.isDraft = index == 0
        row.checks = []
        row.mergeability = index == 1 ? .conflicting : .mergeable
        row.reviewDecision = index == 1 ? "CHANGES_REQUESTED" : "REVIEW_REQUIRED"
        row.mergedAt = index == 3 ? Date(timeIntervalSince1970: 1) : nil
        row.state = index == 3 || index == 5 ? "closed" : "open"
        if index == 4 {
            row.checks = [
                .init(id: "failed", name: "Tests", status: "completed", conclusion: "failure", detailsURL: nil)
            ]
        }
        return row
    }

    @Test func renderWorkspaceThemes() async throws {
        guard let directory = ProcessInfo.processInfo.environment["GITHUB_WORKSPACE_SNAPSHOT_DIR"] else { return }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let savedTheme = DockThemeRuntime.current
        let savedRevision = DockThemeRuntime.revision
        defer {
            DockThemeRuntime.current = savedTheme
            DockThemeRuntime.revision = savedRevision
        }
        let panels = ProcessInfo.processInfo.environment["GITHUB_PANEL_SNAPSHOTS"] == "1"
        let transport = WorkspaceVisualTransport(
            cleanReadiness: ProcessInfo.processInfo.environment["GITHUB_READINESS_CLEAN"] == "1",
            merged: ProcessInfo.processInfo.environment["GITHUB_MERGED_SNAPSHOT"] == "1")
        let repo = GitHubReferenceParser.repository("owner/repo")!
        let pr = PullRequestCenterModel(api: PullRequestCenterAPI(transport: transport))
        await pr.open(.init(repository: repo, number: 1, kind: .pullRequest))
        await pr.loadSelectedDetail()
        let issues = IssueCenterModel(api: GitHubIssueCenterAPI(transport: transport))
        await issues.open(.init(repository: repo, number: 1, kind: .issue))
        await issues.loadSelectedDetail()
        let prOnly = ProcessInfo.processInfo.environment["GITHUB_PR_ONLY"] == "1"
        let issuesOnly = ProcessInfo.processInfo.environment["GITHUB_ISSUE_ONLY"] == "1"
        let conversationOnly = ProcessInfo.processInfo.environment["GITHUB_CONVERSATION_SNAPSHOT"] == "1"
        if let issue = issues.selected { await issues.conversation(for: issue).refresh() }
        let colorAudit = ProcessInfo.processInfo.environment["GITHUB_COLOR_AUDIT"] == "1"
        let variants: [(DockThemeID, Bool)] =
            colorAudit
            ? [
                (.clean, false), (.clean, true), (.glass, false), (.glass, true), (.mono, true), (.eInk, false),
                (.dusk, true), (.warmLight, false),
            ]
            : ((prOnly || issuesOnly)
                ? [.clean, .glass, .mono, .notebook, .slate, .dusk] : [.notebook, .terminal, .glass, .mono])
                .map { ($0, $0 != .notebook && !(issuesOnly && $0 == .clean)) }
        for (theme, dark) in variants {
            DockThemeRuntime.current = theme
            DockThemeRuntime.revision &+= 1
            for width: CGFloat in (panels ? [380, 760] : [540, 1000]) {
                let root = Group {
                    if conversationOnly, let issue = issues.selected {
                        ScrollView { GitHubConversationView(model: issues.conversation(for: issue)).padding(24) }
                    } else if issuesOnly {
                        HStack(spacing: 1) {
                            if width > 600, let issue = issues.selected {
                                VStack(spacing: 4) {
                                    IssueRowView(issue: issue, isSelected: true, viewer: "ada")
                                    IssueRowView(issue: closedIssueFixture(issue), isSelected: false, viewer: "ada")
                                    Spacer()
                                }.padding(10).frame(width: 300)
                            }
                            IssueDetailView(center: issues, onOpenChat: { _ in })
                        }
                    } else if panels, let record = pr.selected {
                        ScrollView {
                            VStack(spacing: 12) {
                                LazyVGrid(
                                    columns: [GridItem(.adaptive(minimum: 340), spacing: 16, alignment: .top)],
                                    alignment: .leading, spacing: 16
                                ) {
                                    VStack(alignment: .leading, spacing: 12) {
                                        PullRequestReadinessView(center: pr, record: record, embedded: true)
                                        Divider().overlay(Color.dockBorderLight)
                                        PullRequestLandingView(
                                            record: record, client: pr.api.client, embedded: true, onChanged: {})
                                    }.dockCard(padding: 12)
                                    PullRequestChangeBreakdownView(
                                        files: pr.filesByID[record.id], expectedCount: record.changedFiles,
                                        isCurrent: pr.filesAreCurrent(for: record), isLoading: false, onReviewFiles: {})
                                }
                                GitHubMetadataView(reference: record.reference, client: pr.api.client)
                                Spacer(minLength: 0)
                            }.padding(16)
                        }
                    } else {
                        HStack(spacing: 1) {
                            if prOnly, width > 600, let record = pr.selected {
                                VStack(spacing: 4) {
                                    ForEach(0..<(colorAudit ? 6 : 4)) { index in
                                        PullRequestRowView(
                                            pullRequest: rowFixture(record, index: index), isSelected: index == 0)
                                    }
                                    Spacer()
                                }.padding(10).frame(width: 300)
                            }
                            PullRequestDetailView(center: pr, onOpenChat: { _ in })
                            if width > 600 && !prOnly { IssueDetailView(center: issues, onOpenChat: { _ in }) }
                        }
                    }
                }
                .frame(width: width, height: 950).background(Color.dockCanvas).dockThemedRoot()
                .environment(\.colorScheme, dark ? .dark : .light)
                let host = NSHostingView(rootView: root)
                host.frame = CGRect(x: 0, y: 0, width: width, height: 950)
                let window = NSWindow(
                    contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentView = host
                window.orderFrontRegardless()
                for _ in 0..<4 {
                    host.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(80))
                }
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let data = try #require(bitmap.representation(using: .png, properties: [:]))
                try data.write(
                    to: URL(fileURLWithPath: directory).appendingPathComponent(
                        "github-\(Int(width))-\(theme.rawValue)\(colorAudit ? (dark ? "-dark" : "-light") : "").png"))
                window.orderOut(nil)
                #expect(bitmap.pixelsWide > 0)
            }
        }
    }
}
