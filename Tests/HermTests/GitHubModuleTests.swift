import Foundation
import Testing
@testable import Herm

private actor ModuleTransport: GitHubIssueTransport {
    struct Reply: Sendable { let status: Int; let data: Data }
    private var requests: [URLRequest] = []
    let respond: @Sendable (URLRequest) throws -> Reply
    init(_ respond: @escaping @Sendable (URLRequest) throws -> Reply) { self.respond = respond }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let reply = try respond(request)
        return (reply.data, HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: nil)!)
    }
    func recorded() -> [URLRequest] { requests }
    static func json(_ value: Any, status: Int = 200) throws -> Reply { Reply(status: status, data: try JSONSerialization.data(withJSONObject: value)) }
}

struct GitHubModuleTests {
    @Test func discussionKeepsProviderAvatarsAndAllowsMissingUsers() throws {
        let avatar = "https://avatars.githubusercontent.com/u/123?v=4"
        let comment = try #require(GitHubConversationService.comment(["id": 1, "user": ["login": "ada", "avatar_url": avatar]]))
        #expect(comment.avatarURL?.absoluteString == avatar)
        let event = try #require(GitHubConversationService.event(["id": 2, "event": "labeled", "actor": ["login": "ada", "avatar_url": avatar]]))
        #expect(event.avatarURL == comment.avatarURL)
        #expect(GitHubConversationService.comment(["id": 3])?.avatarURL == nil)
    }
    @Test func paginationLoadsBeyondOneHundredAndReportsSearchLimits() async throws {
        let transport = ModuleTransport { request in
            let page = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "page" }!.value!
            let rows = (0..<(page == "1" ? 100 : 21)).map { ["id": Int(page)! * 100 + $0] }
            return try ModuleTransport.json(["items": rows, "total_count": 121, "incomplete_results": false])
        }
        let page = try await GitHubClient(transport: transport).pages("/search/issues", key: "items", search: true)
        #expect(page.rows.count == 121)
        #expect(!page.coverage.partial)
        #expect(await transport.recorded().count == 2)
        let capped = ModuleTransport { _ in try ModuleTransport.json(["items": (0..<100).map { ["id": $0] }, "total_count": 1001]) }
        let limited = try await GitHubClient(transport: capped).pages("/search/issues", key: "items", search: true)
        #expect(limited.rows.count == 1000)
        #expect(limited.coverage.partial)
    }
    @Test func paginationRetainsLoadedRowsAfterDeniedPage() async throws {
        let transport = ModuleTransport { request in
            if request.url!.query!.contains("page=2") { return try ModuleTransport.json(["message": "denied"], status: 403) }
            return try ModuleTransport.json((0..<100).map { ["id": $0] })
        }
        let page = try await GitHubClient(transport: transport).pages("/repos/a/b/issues")
        #expect(page.rows.count == 100)
        #expect(page.coverage.partial)
        #expect(page.coverage.label?.contains("denied") == true)
    }
    @Test func labelEditsUseDeltasRatherThanReplacingConcurrentLabels() async throws {
        let transport = ModuleTransport { _ in try ModuleTransport.json([]) }
        let reference = GitHubItemReference(repository: repo, number: 1, kind: .issue)
        try await GitHubMetadataService(client: GitHubClient(transport: transport)).changeLabels(reference, adding: ["new label"], removing: ["old/label"])
        let requests = await transport.recorded()
        #expect(requests.map(\.httpMethod) == ["POST", "DELETE"])
        #expect(requests.allSatisfy { $0.httpMethod != "PUT" && $0.httpMethod != "PATCH" })
        #expect(requests.last?.url?.absoluteString.contains("old%2Flabel") == true)
    }
    @Test func mergeTreeOutputPreservesUnusualFileNamesAndUnknownIsNotClean() throws {
        let sha = String(repeating: "a", count: 40)
        let data = Data((sha + "\0a file\nwith newline.swift\0binary.dat\0").utf8)
        let analysis = try GitHubConflictService.parse(data, exitCode: 1, head: sha, base: sha)
        #expect(analysis.hasConflicts && analysis.complete)
        #expect(analysis.files == ["a file\nwith newline.swift", "binary.dat"])
        let incomplete = try GitHubConflictService.parse(Data((sha + "\0").utf8), exitCode: 1, head: sha, base: sha)
        #expect(!incomplete.complete)
        #expect(incomplete.hasConflicts)
        #expect(throws: (any Error).self) { try GitHubConflictService.parse(Data("fatal\0".utf8), exitCode: 0, head: sha, base: sha) }
    }
    @Test func diffLineNumbersFollowBothSidesAndDoNotCountNoNewlineMarkers() {
        let lines = PullRequestDiffPresentation.lines("@@ -10,2 +20,3 @@\n context\n-old\n+new\n+extra\n\\ No newline at end of file")
        #expect(lines[1].oldLine == 10 && lines[1].newLine == 20)
        #expect(lines[2].oldLine == 11 && lines[2].newLine == nil)
        #expect(lines[3].oldLine == nil && lines[3].newLine == 21)
        #expect(lines[4].newLine == 22)
        #expect(lines[5].oldLine == nil && lines[5].newLine == nil)
    }
    @Test func browsingScopesAreExplicitAndRejectQueryInjection() throws {
        var options = GitHubBrowseOptions()
        options.repository = "owner/repo"; options.state = .closed; options.label = "needs review"
        #expect(try options.query(kind: .issue, viewer: nil) == "is:issue is:closed repo:owner/repo label:\"needs review\"")
        options.label = "a\" is:open"
        #expect(throws: (any Error).self) { try options.query(kind: .issue, viewer: nil) }
    }
    private var repo: GitHubRepositoryReference { GitHubReferenceParser.repository("owner/repo")! }

    @Test(arguments: ["content", "clean", "binary", "renameDelete"])
    func isolatedConflictAnalysisLeavesSourceRepositoryUntouched(kind: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("herm-conflict-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func git(_ args: [String]) throws -> String {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git"); process.arguments = ["-C", root.path] + args
            let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
            try process.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw GitHubConflictError.unavailable }
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        _ = try git(["init", "-b", "main"])
        _ = try git(["config", "user.email", "fixture@example.invalid"]); _ = try git(["config", "user.name", "Fixture"])
        let file = root.appendingPathComponent("conflict.txt")
        try Data((kind == "binary" ? "initial\0data" : "initial\n").utf8).write(to: file)
        _ = try git(["add", "."]); _ = try git(["commit", "-m", "initial"])
        _ = try git(["checkout", "-b", "feature"])
        if kind == "renameDelete" { _ = try git(["mv", "conflict.txt", "renamed.txt"]) }
        else { try Data((kind == "binary" ? "head\0data" : "head\n").utf8).write(to: file) }
        _ = try git(["commit", "-am", "head"]); let head = try git(["rev-parse", "HEAD"])
        _ = try git(["update-ref", "refs/pull/1/head", head]); _ = try git(["checkout", "main"])
        if kind == "renameDelete" { _ = try git(["rm", "conflict.txt"]) }
        else if kind == "clean" {
            try "base\n".write(to: root.appendingPathComponent("base.txt"), atomically: true, encoding: .utf8)
            _ = try git(["add", "base.txt"])
        } else { try Data((kind == "binary" ? "base\0data" : "base\n").utf8).write(to: file) }
        _ = try git(["commit", "-am", "base"]); let base = try git(["rev-parse", "HEAD"])
        try "uncommitted\n".write(to: root.appendingPathComponent("local.txt"), atomically: true, encoding: .utf8)
        let refs = try git(["show-ref"]); let status = try git(["status", "--porcelain=v1"])
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        var record = PullRequestCenterAPI().parse(["number": 1, "title": "fixture", "head": ["ref": "feature", "sha": head], "base": ["ref": "main", "sha": base]], repository: repo, localPath: root.path)!
        record.headRevision = head; record.baseRevision = base
        let result = try await GitHubConflictService().analyze(record, sourceURL: root)
        #expect(result.hasConflicts == (kind != "clean"))
        #expect(result.complete)
        #expect(result.files == (kind == "clean" ? [] : [kind == "renameDelete" ? "renamed.txt" : "conflict.txt"]))
        #expect(try git(["show-ref"]) == refs)
        #expect(try Data(contentsOf: root.appendingPathComponent(".git/index")) == index)
        #expect(try git(["status", "--porcelain=v1"]) == status)
        record.headRevision = String(repeating: "f", count: 40)
        await #expect(throws: (any Error).self) { try await GitHubConflictService().analyze(record, sourceURL: root) }
        await #expect(throws: (any Error).self) { try await GitHubConflictService(timeout: 0).analyze(record, sourceURL: root) }
    }
}
