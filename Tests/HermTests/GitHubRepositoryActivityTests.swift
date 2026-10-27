import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Herm

actor RepositoryActivityTransport: GitHubIssueTransport {
    enum Mode: Sendable { case success, denied, slow, summaryDenied }
    private var mode: Mode = .success
    private var requested = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var queries: [[String: String]] = []
    private(set) var summaryReads = 0
    func setMode(_ mode: Mode) { self.mode = mode }
    func waitForRequest() async {
        if requested { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    static func row(_ id: Int, type: String, branch: String, actor: String?, date: String) -> [String: Any] {
        [
            "id": id,
            "before": type == "branch_creation" ? String(repeating: "0", count: 40) : String(repeating: "a", count: 40),
            "after": type == "branch_deletion" ? String(repeating: "0", count: 40) : String(repeating: "b", count: 40),
            "ref": "refs/heads/" + branch, "activity_type": type, "timestamp": date,
            "actor": actor.map { ["login": $0] } as Any? ?? NSNull(),
        ]
    }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let path = request.url!.path
        let parameters = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let query = Dictionary(
            parameters.compactMap { item in item.value.map { (item.name, $0) } }, uniquingKeysWith: { _, last in last })
        let status: Int
        let payload: Any
        if path.hasSuffix("/activity") {
            requested = true
            for waiter in waiters { waiter.resume() }
            waiters.removeAll()
            queries.append(query)
            #expect(query["per_page"] == "30")
            if mode == .slow { try await Task.sleep(for: .seconds(30)) }
            status = mode == .denied ? 403 : 200
            var rows = [
                Self.row(1, type: "push", branch: "main", actor: "octocat", date: "2026-10-24T08:00:00Z"),
                Self.row(2, type: "pr_merge", branch: "main", actor: "octocat", date: "2026-10-26T08:00:00Z"),
                Self.row(
                    3, type: "force_push", branch: "feature/calendar", actor: "contributor",
                    date: "2026-10-25T08:00:00Z"),
                Self.row(
                    4, type: "branch_creation", branch: "feature/calendar", actor: "contributor",
                    date: "2026-10-23T08:00:00Z"),
            ]
            rows += [rows[0]]
            if let ref = query["ref"] { rows = rows.filter { $0["ref"] as? String == ref } }
            if let actor = query["actor"] {
                rows = rows.filter { ($0["actor"] as? [String: Any])?["login"] as? String == actor }
            }
            if let type = query["activity_type"] { rows = rows.filter { $0["activity_type"] as? String == type } }
            payload = rows
        } else {
            summaryReads += 1
            status = mode == .summaryDenied ? 403 : 200
            if path.contains("/git/commits/") {
                payload = ["message": "fix(calendar): preserve user selections\n\nDetails"]
            } else {
                #expect(path.contains("/compare/"))
                #expect(query["per_page"] == "1")
                payload = ["total_commits": 7]
            }
        }
        return (
            try JSONSerialization.data(withJSONObject: payload),
            HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        )
    }
}

@MainActor
struct GitHubRepositoryActivityTests {
    private func reference() throws -> GitHubRepositoryReference {
        try #require(GitHubReferenceParser.repository("owner/repo"))
    }
    @Test func queriesGithubFiltersSortsAndKeepsStaleDataWithinTheSameScope() async throws {
        let transport = RepositoryActivityTransport()
        let model = GitHubRepositoryActivityModel(
            repository: try reference(), client: GitHubClient(transport: transport))
        await model.load()
        #expect(model.items.map(\.id) == [2, 3, 1, 4])
        #expect(model.branches == ["refs/heads/feature/calendar", "refs/heads/main"])
        #expect(model.actors == ["contributor", "octocat"])
        model.filters = GitHubActivityFilters(
            branch: "refs/heads/feature/calendar", actor: "contributor", type: .forcePush, period: .week,
            oldestFirst: true)
        await model.load()
        #expect(model.items.map(\.id) == [3])
        let query = try #require(await transport.queries.last)
        #expect(query["ref"] == "refs/heads/feature/calendar" && query["actor"] == "contributor")
        #expect(query["activity_type"] == "force_push" && query["time_period"] == "week" && query["direction"] == "asc")
        await transport.setMode(.denied)
        model.reload()
        await model.load()
        #expect(model.items.map(\.id) == [3] && model.error != nil)
        model.filters.actor = "someone-else"
        await model.load()
        #expect(model.items.isEmpty && model.error != nil)
        await transport.setMode(.success)
        model.filters = GitHubActivityFilters(oldestFirst: true)
        await model.load()
        #expect(model.items.map(\.id) == [4, 1, 3, 2] && model.error == nil)
        model.filters.actor = "nobody"
        await model.load()
        #expect(model.items.isEmpty && model.error == nil)
    }

    @Test func lazyCommitDetailsAreSharedAndForcePushesDoNotInventCounts() async throws {
        let transport = RepositoryActivityTransport()
        let model = GitHubRepositoryActivityModel(
            repository: try reference(), client: GitHubClient(transport: transport))
        await model.load()
        let merge = try #require(model.items.first { $0.type == "pr_merge" })
        async let first: Void = model.loadSummary(merge)
        async let second: Void = model.loadSummary(merge)
        _ = await (first, second)
        #expect(model.summaries[merge.id]?.title == "fix(calendar): preserve user selections")
        #expect(model.summaries[merge.id]?.commitCount == 7)
        #expect(await transport.summaryReads == 2)
        let force = try #require(model.items.first { $0.type == "force_push" })
        await model.loadSummary(force)
        #expect(model.summaries[force.id]?.commitCount == nil)
        #expect(await transport.summaryReads == 3)
        await transport.setMode(.summaryDenied)
        await model.loadSummary(merge, force: true)
        #expect(model.summaries[merge.id]?.error != nil)
        #expect(model.summaries[merge.id]?.commitCount == 7)
        #expect(model.summaries[merge.id]?.title == "fix(calendar): preserve user selections")
        #expect(model.items.count == 4)
    }

    @Test func cancelledRepositoryLoadDoesNotPublish() async throws {
        let transport = RepositoryActivityTransport()
        await transport.setMode(.slow)
        let model = GitHubRepositoryActivityModel(
            repository: try reference(), client: GitHubClient(transport: transport))
        let load = Task { await model.load() }
        await transport.waitForRequest()
        load.cancel()
        await load.value
        #expect(model.items.isEmpty && model.error == nil && !model.loading)
    }

    @Test func validatesRevisionsAndNullableActors() throws {
        let reference = try reference()
        let deleted = try GitHubRepositoryActivity.parse(
            RepositoryActivityTransport.row(
                1, type: "branch_deletion", branch: "old", actor: nil, date: "2026-10-26T08:00:00.123Z"))
        #expect(deleted.actor == nil && deleted.avatarURL == nil && !deleted.hasAfter)
        #expect(deleted.webURL(in: reference).path == "/owner/repo/commit/" + String(repeating: "a", count: 40))
        var row = RepositoryActivityTransport.row(
            2, type: "push", branch: "main", actor: "octocat", date: "2026-10-26T08:00:00Z")
        let avatar = "https://avatars.githubusercontent.com/u/1"
        row["actor"] = ["login": "octocat", "avatar_url": avatar]
        #expect(try GitHubRepositoryActivity.parse(row).avatarURL?.absoluteString == avatar)
        for value in [
            "http://avatars.githubusercontent.com/u/1", "https://avatars.githubusercontent.com:443/u/1",
            "https://user@avatars.githubusercontent.com/u/1", "https://user:pass@avatars.githubusercontent.com/u/1",
        ] {
            row["actor"] = ["login": "octocat", "avatar_url": value]
            #expect(try GitHubRepositoryActivity.parse(row).avatarURL == nil)
        }
        row["actor"] = ["login": "octocat", "avatar_url": "https://example.com/tracker"]
        #expect(try GitHubRepositoryActivity.parse(row).avatarURL == nil)
        row["after"] = "../../settings"
        #expect(throws: GitHubRequestError.self) { try GitHubRepositoryActivity.parse(row) }
        #expect(GitHubActivityFilters().query == ["per_page": "30", "direction": "desc"])
    }

    @Test func renderActivityReference() async throws {
        guard let directory = ProcessInfo.processInfo.environment["GITHUB_ACTIVITY_SNAPSHOT_DIR"] else { return }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let model = GitHubRepositoryActivityModel(
            repository: try reference(), client: GitHubClient(transport: RepositoryActivityTransport()))
        await model.load()
        for row in model.items { await model.loadSummary(row) }
        let saved = DockThemeRuntime.current
        defer { DockThemeRuntime.current = saved }
        for theme: DockThemeID in [.clean, .storm, .mono, .glass] {
            DockThemeRuntime.current = theme
            DockThemeRuntime.revision &+= 1
            for width: CGFloat in [440, 1100] {
                let host = NSHostingView(
                    rootView: GitHubRepositoryActivityView(model: model)
                        .environment(\.colorScheme, theme == .clean ? .light : .dark)
                        .frame(width: width, height: 700).dockThemedRoot())
                host.frame = CGRect(x: 0, y: 0, width: width, height: 700)
                let window = NSWindow(
                    contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = host
                window.appearance = NSAppearance(named: theme == .clean ? .aqua : .darkAqua)
                window.orderFrontRegardless()
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(160))
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                try png.write(
                    to: URL(fileURLWithPath: directory).appendingPathComponent(
                        "activity-\(theme.rawValue)-\(Int(width)).png"))
                window.orderOut(nil)
            }
        }
    }
}
