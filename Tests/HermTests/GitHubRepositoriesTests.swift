import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Herm

private actor RepositoriesTransport: GitHubIssueTransport {
    let reversesRows: Bool
    let pins: [String]
    init(reversesRows: Bool = false, pins: [String] = []) {
        self.reversesRows = reversesRows
        self.pins = pins
    }
    var denied = false
    func deny() { denied = true }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        if request.url?.path == "/graphql" {
            let nodes = pins.map { ["nameWithOwner": $0] }
            return (
                try JSONSerialization.data(withJSONObject: ["data": ["viewer": ["pinnedItems": ["nodes": nodes]]]]),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )
        }
        if request.url?.path != "/user/repos" {
            return try await RepositoryDetailsTransport().data(for: request)
        }
        #expect(request.url?.path == "/user/repos")
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
        #expect(query?.first { $0.name == "affiliation" }?.value == "owner,collaborator,organization_member")
        let payload: [[String: Any]] = [
            [
                "full_name": "octocat/Herm",
                "description":
                    "A native workspace for your agents, with streaming conversations, repository reviews, shared team tools, and scheduled automations.",
                "private": false,
                "archived": false, "language": "Swift", "stargazers_count": 42,
                "forks_count": 7, "open_issues_count": 12, "default_branch": "main",
                "pushed_at": "2026-10-24T10:00:00Z", "updated_at": "2026-10-25T09:00:00Z",
                "license": ["name": "MIT License"], "permissions": ["pull": true, "push": true, "admin": false],
                "has_issues": true,
            ],
            ["full_name": "team/archive", "private": true, "archived": true],
            [
                "full_name": "team/shared", "private": true, "archived": false,
                "description": "Shared tooling for the engineering team.", "language": "Vue",
                "stargazers_count": 8, "updated_at": "2026-10-24T10:00:00Z", "pushed_at": "2026-10-26T09:00:00Z",
            ],
        ]
        return (
            try JSONSerialization.data(withJSONObject: reversesRows ? Array(payload.reversed()) : payload),
            HTTPURLResponse(url: request.url!, statusCode: denied ? 401 : 200, httpVersion: nil, headerFields: nil)!
        )
    }
}

@MainActor
struct GitHubRepositoriesTests {
    @Test func loadsFiltersAndRetainsDataAfterFailure() async {
        let transport = RepositoriesTransport()
        let model = GitHubRepositoriesModel(client: GitHubClient(transport: transport))
        await model.refresh()
        #expect(model.repositories.count == 3)
        #expect(model.repositories.first?.forks == 7)
        #expect(model.repositories.first?.openIssuesAndPullRequests == 12)
        #expect(model.repositories.first?.defaultBranch == "main")
        #expect(model.repositories.first?.pushedAt != nil)
        #expect(model.repositories.first?.license == "MIT License")
        #expect(model.visible.count == 2)
        model.includesArchived = true
        model.visibility = "Private"
        #expect(model.visible.map(\.id) == ["team/shared", "team/archive"])
        model.visibility = "All"
        model.owner = "team"
        #expect(model.visible.map(\.id) == ["team/shared", "team/archive"])
        #expect(model.owners == ["octocat", "team"])
        model.owner = "All owners"
        model.query = "native"
        #expect(model.visible.first?.id == "octocat/Herm")
        await transport.deny()
        await model.refresh()
        #expect(model.repositories.count == 3)
        #expect(model.accessRequirement == .signIn)
        #expect(!model.loading)
    }

    @Test func sortsByLastUpdateRatherThanLastPush() async {
        let model = GitHubRepositoriesModel(client: GitHubClient(transport: RepositoriesTransport(reversesRows: true)))
        await model.refresh()
        #expect(model.repositories.map(\.id) == ["octocat/Herm", "team/shared", "team/archive"])
        #expect(model.visible.map(\.id) == ["octocat/Herm", "team/shared"])
        #expect(model.repositories.first?.updatedAt == ISO8601DateFormatter().date(from: "2026-10-25T09:00:00Z"))
        model.owner = "team"
        model.includesArchived = true
        #expect(model.visible.map(\.id) == ["team/shared", "team/archive"])
    }

    @Test func listsProfilePinsFirstInGitHubOrder() async {
        let model = GitHubRepositoriesModel(
            client: GitHubClient(transport: RepositoriesTransport(pins: ["team/Archive", "team/shared"])))
        await model.refresh()
        #expect(model.pinned == ["team/archive", "team/shared"])
        #expect(model.visible.map(\.id) == ["team/shared", "octocat/Herm"])
        model.includesArchived = true
        #expect(model.visible.map(\.id) == ["team/archive", "team/shared", "octocat/Herm"])
        #expect(model.isPinned(model.visible[0]) && !model.isPinned(model.visible[2]))
    }

    @Test func parsesTrustedRepositoryReferences() throws {
        let row = try GitHubRepositorySummary.parse(["full_name": "owner/repo", "private": false, "archived": false])
        #expect(row.forks == nil)
        #expect(row.pushedAt == nil)
        #expect(row.updatedAt == nil)
        #expect(row.defaultBranch == nil)
        #expect(row.cloneURL == "https://github.com/owner/repo.git")
        #expect(throws: GitHubRequestError.self) {
            try GitHubRepositorySummary.parse(["full_name": "../repo", "private": false, "archived": false])
        }
        let navigation = SessionNavigationState()
        navigation.selectGitHubRepositories()
        #expect(navigation.selectedGitHubSection == .repositories)
        navigation.openSession("session")
        #expect(navigation.selectedGitHubSection == .repositories)
    }

    @Test func renderRepositories() async throws {
        guard let directory = ProcessInfo.processInfo.environment["GITHUB_REPOSITORIES_SNAPSHOT_DIR"] else { return }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let model = GitHubRepositoriesModel(
            client: GitHubClient(transport: RepositoriesTransport(pins: ["team/shared"])))
        await model.refresh()
        let saved = DockThemeRuntime.current
        defer { DockThemeRuntime.current = saved }
        for theme: DockThemeID in [.clean, .storm, .glass, .mono] {
            DockThemeRuntime.current = theme
            DockThemeRuntime.revision &+= 1
            for width: CGFloat in [340, 470, 1100] {
                for overview in [false, true] {
                    model.selectedID = overview ? model.repositories.first?.id : nil
                    let content = AnyView(GitHubRepositoriesView(model: model))
                    let height: CGFloat = overview ? 1250 : 650
                    let host = NSHostingView(
                        rootView:
                            content
                            .environment(\.openGitHubRepository, { _, _ in })
                            .environment(\.colorScheme, theme == .clean ? .light : .dark)
                            .frame(width: width, height: height).dockThemedRoot())
                    host.frame = CGRect(x: 0, y: 0, width: width, height: height)
                    let window = NSWindow(
                        contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                    window.appearance = NSAppearance(named: theme == .clean ? .aqua : .darkAqua)
                    window.contentView = host
                    window.orderFrontRegardless()
                    host.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(160))
                    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let data = try #require(bitmap.representation(using: .png, properties: [:]))
                    try data.write(
                        to: URL(fileURLWithPath: directory).appendingPathComponent(
                            "repos-\(overview ? "overview" : "list")-\(theme.rawValue)-\(Int(width)).png"))
                    window.orderOut(nil)
                }
            }
        }
    }
}
