import Foundation
import Testing

@testable import Herm

private actor ScopedRepositoryTransport: GitHubIssueTransport {
    private var responses: [String: Data] = [:]
    private var held: Set<String> = []
    private var arrivals: [String: CheckedContinuation<Bool, Never>] = [:]
    private var releases: [String: CheckedContinuation<Void, Never>] = [:]
    private var finished: Set<String> = []

    func hold(_ key: String) {
        finished.remove(key)
        held.insert(key)
    }
    func waitForArrival(_ key: String) async -> Bool {
        if releases[key] != nil { return true }
        if finished.contains(key) { return false }
        return await withCheckedContinuation { arrivals[key] = $0 }
    }
    func didFinish(_ key: String) {
        finished.insert(key)
        arrivals.removeValue(forKey: key)?.resume(returning: false)
    }
    func release(_ key: String) {
        held.remove(key)
        releases.removeValue(forKey: key)?.resume()
    }

    func set(_ value: Data?, for key: String) {
        responses[key] = value
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = request.url!
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value
        let key = query.map { "\(url.path)?\($0)" } ?? url.path
        if held.contains(key) {
            await withCheckedContinuation { continuation in
                releases[key] = continuation
                arrivals.removeValue(forKey: key)?.resume(returning: true)
            }
        }
        let data: Data?
        if key.hasPrefix("/search/issues?is:pr is:merged repo:") {
            data = try JSONSerialization.data(withJSONObject: ["items": []])
        } else {
            data = responses[key]
        }
        guard let data else { throw GitHubCodeHostError.unavailable }
        return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

struct SessionGitHubRepositoryScopeTests {
    private func repository(_ root: URL, name: String, remote: Bool = true) throws -> URL {
        let directory = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var commands = [["init", "-q"]]
        if remote { commands.append(["remote", "add", "origin", "https://github.com/fixture/\(name).git"]) }
        for arguments in commands {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", directory.path] + arguments
            try process.run()
            process.waitUntilExit()
            try #require(process.terminationStatus == 0)
        }
        return directory
    }

    private func setRows(_ transport: ScopedRepositoryTransport, name: String, rows: Bool?) async throws {
        let repository = "fixture/\(name)"
        let row: [String: Any] = [
            "number": 19, "title": "Scoped item", "state": "open", "body": "Summary",
            "repository": ["full_name": repository], "repository_url": "https://api.github.com/repos/\(repository)",
            "html_url": "https://github.com/\(repository)/issues/19", "user": ["login": "ada"],
            "updated_at": "2026-10-01T00:00:00Z",
        ]
        let items: [[String: Any]] = rows == true ? [row] : []
        let issueData = rows == nil ? nil : try JSONSerialization.data(withJSONObject: ["items": items])
        let pullData = rows == nil ? nil : try JSONSerialization.data(withJSONObject: items)
        await transport.set(issueData, for: "/search/issues?repo:\(repository) is:issue is:open")
        await transport.set(pullData, for: "/repos/\(repository)/pulls")
    }

    @MainActor @Test func listPresentationTracksEachScopedModel() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("herm-scope-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try repository(root, name: "a")
        let b = try repository(root, name: "b")
        let transport = ScopedRepositoryTransport()
        await transport.set(try JSONSerialization.data(withJSONObject: ["login": "ada"]), for: "/user")
        try await setRows(transport, name: "a", rows: false)
        let issues = IssueCenterModel(api: GitHubIssueCenterAPI(transport: transport))
        let pulls = PullRequestCenterModel(api: PullRequestCenterAPI(transport: transport))
        func issueState(_ path: String) -> SessionGitHubListPresentation {
            SessionIssuesSurface.listPresentation(center: issues, repositoryPath: path)
        }
        func pullState(_ path: String) -> SessionGitHubListPresentation {
            SessionPullRequestsSurface.listPresentation(center: pulls, repositoryPath: path)
        }
        let issueKey = "/search/issues?repo:fixture/a is:issue is:open"
        let pullKey = "/repos/fixture/a/pulls"
        for populated in [false, true] {
            try await setRows(transport, name: "a", rows: populated)
            if populated {
                await issues.refreshScoped(repositoryPath: a.path)
                await pulls.refreshScoped(repositoryPath: a.path)
                issues.query = "no matching title"
                pulls.query = "no matching title"
                #expect(issues.records.count == 1 && issues.visible.isEmpty)
                #expect(pulls.records.count == 1 && pulls.visible.isEmpty)
            }
            await transport.hold(issueKey)
            await transport.hold(pullKey)
            let issueRefresh = Task {
                await issues.refreshScoped(repositoryPath: a.path)
                await transport.didFinish(issueKey)
            }
            let pullRefresh = Task {
                await pulls.refreshScoped(repositoryPath: a.path)
                await transport.didFinish(pullKey)
            }
            let issueArrived = await transport.waitForArrival(issueKey)
            let pullArrived = await transport.waitForArrival(pullKey)
            #expect(issueArrived && pullArrived)
            if issueArrived && pullArrived {
                #expect(issueState(a.path).isLoading == !populated)
                #expect(pullState(a.path).isLoading == !populated)
                #expect(issueState(a.path).warning == nil && pullState(a.path).warning == nil)
            }
            await transport.release(issueKey)
            await transport.release(pullKey)
            await issueRefresh.value
            await pullRefresh.value
            #expect(!issueState(a.path).isLoading && !pullState(a.path).isLoading)
        }
        issues.query = ""
        pulls.query = ""
        try await setRows(transport, name: "a", rows: nil)
        await issues.refreshScoped(repositoryPath: a.path)
        await pulls.refreshScoped(repositoryPath: a.path)
        #expect(issues.visible.count == 1 && pulls.visible.count == 1)
        #expect(!issueState(a.path).isLoading && issueState(a.path).warning?.contains("last loaded") == true)
        #expect(!pullState(a.path).isLoading && pullState(a.path).warning?.contains("last loaded") == true)
        #expect(issueState(b.path).isLoading && issueState(b.path).warning == nil)
        #expect(pullState(b.path).isLoading && pullState(b.path).warning == nil)
        await issues.refreshScoped(repositoryPath: b.path)
        await pulls.refreshScoped(repositoryPath: b.path)
        #expect(issues.records.isEmpty && pulls.records.isEmpty)
        #expect(!issueState(b.path).isLoading && issueState(b.path).warning?.contains("fixture/b") == true)
        #expect(!pullState(b.path).isLoading && pullState(b.path).warning?.contains("fixture/b") == true)
    }

    @MainActor @Test func switchFailureNeverRetainsPreviousRepository() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("herm-scope-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try repository(root, name: "a")
        let b = try repository(root, name: "b")
        let noRemote = try repository(root, name: "none", remote: false)
        let transport = ScopedRepositoryTransport()
        await transport.set(try JSONSerialization.data(withJSONObject: ["login": "ada"]), for: "/user")
        try await setRows(transport, name: "a", rows: true)
        let issues = IssueCenterModel(api: GitHubIssueCenterAPI(transport: transport))
        let pulls = PullRequestCenterModel(api: PullRequestCenterAPI(transport: transport))
        await issues.refreshScoped(repositoryPath: a.path)
        await pulls.refreshScoped(repositoryPath: a.path)
        #expect(issues.selected?.repository.id == "fixture/a")
        #expect(pulls.selected?.repository.id == "fixture/a")
        await issues.refreshScoped(repositoryPath: b.path)
        await pulls.refreshScoped(repositoryPath: b.path)
        #expect(
            issues.records.isEmpty && issues.visible.isEmpty && issues.selectedIssueID == nil && issues.selected == nil)
        #expect(pulls.records.isEmpty && pulls.visible.isEmpty && pulls.selectedID == nil && pulls.selected == nil)
        #expect(issues.errorMessage?.contains("fixture/b") == true)
        #expect(pulls.errorMessage?.contains("fixture/b") == true)
        try await setRows(transport, name: "b", rows: true)
        await issues.refreshScoped(repositoryPath: b.path)
        await pulls.refreshScoped(repositoryPath: b.path)
        #expect(issues.selected?.repository.id == "fixture/b" && issues.errorMessage == nil)
        #expect(pulls.selected?.repository.id == "fixture/b" && pulls.errorMessage == nil)
        await issues.refreshScoped(repositoryPath: noRemote.path)
        await pulls.refreshScoped(repositoryPath: noRemote.path)
        #expect(
            issues.records.isEmpty && issues.selected == nil
                && issues.errorMessage?.contains("no GitHub remote") == true)
        #expect(
            pulls.records.isEmpty && pulls.selected == nil && pulls.errorMessage?.contains("no GitHub remote") == true)
    }

    @MainActor @Test func sameRepositoryFailureMarksRetainedRowsStale() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("herm-scope-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try repository(root, name: "a")
        let transport = ScopedRepositoryTransport()
        await transport.set(try JSONSerialization.data(withJSONObject: ["login": "ada"]), for: "/user")
        try await setRows(transport, name: "a", rows: true)
        let issues = IssueCenterModel(api: GitHubIssueCenterAPI(transport: transport))
        let pulls = PullRequestCenterModel(api: PullRequestCenterAPI(transport: transport))
        await issues.refreshScoped(repositoryPath: a.path)
        await pulls.refreshScoped(repositoryPath: a.path)
        #expect(issues.selected != nil && pulls.selected != nil)
        try await setRows(transport, name: "a", rows: nil)
        await issues.refreshScoped(repositoryPath: a.path)
        await pulls.refreshScoped(repositoryPath: a.path)
        #expect(
            issues.visible.count == 1 && issues.selected != nil && issues.errorMessage?.contains("last loaded") == true)
        #expect(
            pulls.visible.count == 1 && pulls.selected != nil && pulls.errorMessage?.contains("last loaded") == true)
        await pulls.loadSelectedDetail()
        #expect(pulls.errorMessage?.contains("last loaded") == true)
        try await setRows(transport, name: "a", rows: false)
        await issues.refreshScoped(repositoryPath: a.path)
        await pulls.refreshScoped(repositoryPath: a.path)
        #expect(issues.selected == nil && issues.errorMessage == nil)
        #expect(pulls.selected == nil && pulls.errorMessage == nil)
    }

    @MainActor @Test func pendingSwitchRejectsLateOldResponse() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("herm-scope-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try repository(root, name: "a")
        let b = try repository(root, name: "b")
        let transport = ScopedRepositoryTransport()
        await transport.set(try JSONSerialization.data(withJSONObject: ["login": "ada"]), for: "/user")
        try await setRows(transport, name: "a", rows: true)
        try await setRows(transport, name: "b", rows: true)
        let issues = IssueCenterModel(api: GitHubIssueCenterAPI(transport: transport))
        let pulls = PullRequestCenterModel(api: PullRequestCenterAPI(transport: transport))
        await issues.refreshScoped(repositoryPath: a.path)
        await pulls.refreshScoped(repositoryPath: a.path)
        #expect(issues.selected != nil && pulls.selected != nil)
        let issueA = "/search/issues?repo:fixture/a is:issue is:open"
        let issueB = "/search/issues?repo:fixture/b is:issue is:open"
        let pullA = "/repos/fixture/a/pulls"
        let pullB = "/repos/fixture/b/pulls"
        for key in [issueA, issueB, pullA, pullB] { await transport.hold(key) }
        let oldIssues = Task {
            await issues.refreshScoped(repositoryPath: a.path)
            await transport.didFinish(issueA)
        }
        let oldPulls = Task {
            await pulls.refreshScoped(repositoryPath: a.path)
            await transport.didFinish(pullA)
        }
        let oldIssueArrived = await transport.waitForArrival(issueA)
        let oldPullArrived = await transport.waitForArrival(pullA)
        #expect(oldIssueArrived && oldPullArrived)
        guard oldIssueArrived && oldPullArrived else {
            for key in [issueA, issueB, pullA, pullB] { await transport.release(key) }
            await oldIssues.value
            await oldPulls.value
            return
        }
        let newIssues = Task {
            await issues.refreshScoped(repositoryPath: b.path)
            await transport.didFinish(issueB)
        }
        let newPulls = Task {
            await pulls.refreshScoped(repositoryPath: b.path)
            await transport.didFinish(pullB)
        }
        let newIssueArrived = await transport.waitForArrival(issueB)
        let newPullArrived = await transport.waitForArrival(pullB)
        #expect(newIssueArrived && newPullArrived)
        guard newIssueArrived && newPullArrived else {
            for key in [issueA, issueB, pullA, pullB] { await transport.release(key) }
            await newIssues.value
            await newPulls.value
            await oldIssues.value
            await oldPulls.value
            return
        }
        #expect(issues.records.isEmpty && issues.selected == nil)
        #expect(pulls.records.isEmpty && pulls.selected == nil)
        await transport.release(issueB)
        await transport.release(pullB)
        await newIssues.value
        await newPulls.value
        await transport.release(issueA)
        await transport.release(pullA)
        await oldIssues.value
        await oldPulls.value
        #expect(issues.selected?.repository.id == "fixture/b" && issues.records.count == 1)
        #expect(pulls.selected?.repository.id == "fixture/b" && pulls.records.count == 1)
    }
}
