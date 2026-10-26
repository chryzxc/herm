import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Herm

private actor GitHubAccessTransport: GitHubIssueTransport {
    var status = 401
    let searchOnly: Bool
    init(searchOnly: Bool = false) { self.searchOnly = searchOnly }
    func allow() { status = 200 }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let viewer = request.url!.path == "/user"
        let code = viewer && searchOnly ? 200 : status
        let payload: [String: Any] = viewer ? ["login": "viewer"] : ["items": [], "total_count": 0]
        return (
            try JSONSerialization.data(withJSONObject: payload),
            HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
        )
    }
}

@MainActor
struct GitHubAccessRecoveryTests {
    @Test func onlyAccessFailuresOfferAuthorization() {
        #expect(GitHubAccessRequirement(error: GitHubRequestError.unauthorized) == .signIn)
        #expect(GitHubAccessRequirement(error: GitHubRequestError.forbidden) == .permission)
        #expect(GitHubAccessRequirement(error: GitHubRequestError.insufficientScopes) == .permission)
        for error in [GitHubRequestError.unavailable, .malformed, .notFound, .rateLimited(nil)] {
            #expect(GitHubAccessRequirement(error: error) == nil)
        }
        #expect(GitHubAccessRequirement.signIn.command(projects: false) == "gh auth login --hostname github.com --web")
        #expect(GitHubAccessRequirement.permission.command(projects: false) == "gh auth refresh -h github.com -s repo")
        #expect(
            GitHubAccessRequirement.permission.command(projects: true) == "gh auth refresh -h github.com -s project")
    }

    @Test func issueAndPullRequestAccessRecoverAfterRetry() async {
        for searchOnly in [false, true] {
            let transport = GitHubAccessTransport(searchOnly: searchOnly)
            let issues = IssueCenterModel(api: GitHubIssueCenterAPI(transport: transport))
            let pulls = PullRequestCenterModel(
                api: PullRequestCenterAPI(transport: transport), details: PullRequestDetailStore())
            await issues.refresh(projects: [])
            await pulls.refresh(projects: [])
            #expect(issues.accessRequirement == .signIn)
            #expect(pulls.accessRequirement == .signIn)
            #expect(!issues.isRefreshing)
            #expect(!pulls.isRefreshing)
            await transport.allow()
            await issues.refresh(projects: [])
            await pulls.refresh(projects: [])
            #expect(issues.accessRequirement == nil)
            #expect(pulls.accessRequirement == nil)
            #expect(issues.errorMessage == nil)
            #expect(pulls.errorMessage == nil)
        }
    }
    @Test func renderSharedRecovery() async throws {
        guard let directory = ProcessInfo.processInfo.environment["GITHUB_ACCESS_SNAPSHOT_DIR"] else { return }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let saved = DockThemeRuntime.current
        defer { DockThemeRuntime.current = saved }
        for theme: DockThemeID in [.clean, .storm, .glass, .mono] {
            DockThemeRuntime.current = theme
            DockThemeRuntime.revision &+= 1
            for width: CGFloat in [360, 1000] {
                let root = GitHubAccessRecoveryView(
                    feature: "Pull requests", requirement: .permission, isRetrying: false, retry: {}
                )
                .environment(\.colorScheme, theme == .clean ? .light : .dark)
                .frame(width: width, height: 600).dockThemedRoot()
                let host = NSHostingView(rootView: root)
                host.frame = CGRect(x: 0, y: 0, width: width, height: 600)
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
                        "access-\(theme.rawValue)-\(Int(width)).png"))
                window.orderOut(nil)
            }
        }
    }

}
