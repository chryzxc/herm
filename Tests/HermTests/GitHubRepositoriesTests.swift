import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Herm

private actor RepositoriesTransport: GitHubIssueTransport {
    var denied = false
    func deny() { denied = true }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        #expect(request.url?.path == "/user/repos")
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
        #expect(query?.first { $0.name == "affiliation" }?.value == "owner,collaborator,organization_member")
        let payload: [[String: Any]] = [
            [
                "full_name": "octocat/Herm", "description": "A native workspace for your agents.", "private": false,
                "archived": false, "language": "Swift", "stargazers_count": 42,
                "forks_count": 7, "open_issues_count": 12, "default_branch": "main",
                "pushed_at": "2026-10-24T10:00:00Z", "license": ["name": "MIT License"],
            ],
            ["full_name": "team/archive", "private": true, "archived": true],
            [
                "full_name": "team/shared", "private": true, "archived": false,
                "description": "Shared tooling for the engineering team.", "language": "TypeScript",
                "stargazers_count": 8,
            ],
        ]
        return (
            try JSONSerialization.data(withJSONObject: payload),
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
        #expect(model.visible.first?.id == "team/archive")
        model.visibility = "All"
        model.owner = "team"
        #expect(model.visible.first?.id == "team/archive")
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

    @Test func parsesTrustedRepositoryReferences() throws {
        let row = try GitHubRepositorySummary.parse(["full_name": "owner/repo", "private": false, "archived": false])
        #expect(row.forks == nil)
        #expect(row.pushedAt == nil)
        #expect(row.defaultBranch == nil)
        #expect(row.cloneURL == "https://github.com/owner/repo.git")
        #expect(throws: GitHubRequestError.self) {
            try GitHubRepositorySummary.parse(["full_name": "../repo", "private": false, "archived": false])
        }
        let navigation = MissionControlNavigationState()
        navigation.selectGitHubRepositories()
        #expect(navigation.selectedGitHubSection == .repositories)
        navigation.openSession("session")
        #expect(navigation.selectedGitHubSection == .repositories)
    }

    @Test func renderRepositories() async throws {
        guard let directory = ProcessInfo.processInfo.environment["GITHUB_REPOSITORIES_SNAPSHOT_DIR"] else { return }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let model = GitHubRepositoriesModel(client: GitHubClient(transport: RepositoriesTransport()))
        await model.refresh()
        let saved = DockThemeRuntime.current
        defer { DockThemeRuntime.current = saved }
        for theme: DockThemeID in [.clean, .storm] {
            DockThemeRuntime.current = theme
            DockThemeRuntime.revision &+= 1
            for width: CGFloat in [440, 1100] {
                for overview in [false, true] {
                    let content: AnyView
                    if overview, let repository = model.repositories.first {
                        content = AnyView(
                            GitHubRepositoriesView(model: model, selected: repository))
                    } else {
                        content = AnyView(GitHubRepositoriesView(model: model))
                    }
                    let host = NSHostingView(
                        rootView:
                            content
                            .environment(\.colorScheme, theme == .clean ? .light : .dark)
                            .frame(width: width, height: 650).dockThemedRoot())
                    host.frame = CGRect(x: 0, y: 0, width: width, height: 650)
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
