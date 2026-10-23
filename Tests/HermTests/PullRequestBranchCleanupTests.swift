import Foundation
import Testing

@testable import Herm

private actor BranchCleanupTransport: GitHubIssueTransport {
    enum Mode: CaseIterable, Sendable {
        case available, fork, deleted, protected, defaultBranch, denied, advanced, unmerged, writeDenied
    }
    let mode: Mode
    var advanced = false
    var writes: [[String: Any]] = []
    init(_ mode: Mode) { self.mode = mode }
    func advance() { advanced = true }
    func writeCount() -> Int { writes.count }
    func writtenRepository() -> String? { writes.first?["repositoryId"] as? String }
    func writtenRef() -> (name: String?, before: String?, after: String?, force: Bool?)? {
        guard let ref = (writes.first?["refUpdates"] as? [[String: Any]])?.first else { return nil }
        return (ref["name"] as? String, ref["beforeOid"] as? String, ref["afterOid"] as? String, ref["force"] as? Bool)
    }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        let query = body["query"] as! String
        let payload: Any
        var status = 200
        if query.hasPrefix("mutation") {
            writes.append((body["variables"] as? [String: Any])?["input"] as? [String: Any] ?? [:])
            if mode == .writeDenied { status = 403 }
            payload = ["data": ["updateRefs": ["clientMutationId": NSNull()]]]
        } else {
            let oid = String(repeating: advanced || mode == .advanced ? "b" : "a", count: 40)
            let ref: Any =
                mode == .deleted
                ? NSNull()
                : [
                    "id": "REF", "name": "feature/fix", "prefix": "refs/heads/", "target": ["oid": oid],
                    "branchProtectionRule": mode == .protected ? ["id": "RULE"] as Any : NSNull(),
                    "repository": [
                        "id": mode == .fork ? "FORK" : "REPO",
                        "nameWithOwner": mode == .fork ? "contributor/fork" : "owner/repo",
                        "defaultBranchRef": ["id": mode == .defaultBranch ? "REF" : "MAIN"],
                    ],
                ]
            payload = [
                "data": [
                    "node": [
                        "id": "PR", "state": mode == .unmerged ? "OPEN" : "MERGED",
                        "headRefOid": String(repeating: "a", count: 40), "viewerCanDeleteHeadRef": mode != .denied,
                        "headRef": ref,
                    ]
                ]
            ]
        }
        return (
            try JSONSerialization.data(withJSONObject: payload),
            HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        )
    }
}

struct PullRequestBranchCleanupTests {
    private func record() -> PullRequestRecord {
        var pr = PullRequestCenterAPI().parse(
            [
                "number": 1, "node_id": "PR", "title": "Fixture", "head": ["sha": String(repeating: "a", count: 40)],
                "base": ["sha": String(repeating: "b", count: 40)],
            ], repository: GitHubReferenceParser.repository("owner/repo")!, localPath: "/tmp/local")!
        pr.mergedAt = Date(timeIntervalSince1970: 1_792_281_660)
        pr.state = "closed"
        return pr
    }
    @Test(arguments: BranchCleanupTransport.Mode.allCases)
    fileprivate func cleanupIsOfferedOnlyForAnUnchangedDeletableMergedHead(mode: BranchCleanupTransport.Mode)
        async throws
    {
        let transport = BranchCleanupTransport(mode)
        let service = GitHubBranchCleanupService(client: GitHubClient(transport: transport))
        if mode == .unmerged {
            await #expect(throws: GitHubRequestError.changed) { try await service.snapshot(record()) }
        } else {
            let snapshot = try await service.snapshot(record())
            #expect((snapshot.target != nil) == (mode == .available || mode == .fork || mode == .writeDenied))
        }
        #expect(await transport.writeCount() == 0)
    }
    @Test func forkDeletionUsesItsRepositoryAndAnAtomicExpectedRevision() async throws {
        let transport = BranchCleanupTransport(.fork)
        let service = GitHubBranchCleanupService(client: GitHubClient(transport: transport))
        let target = try #require(try await service.snapshot(record()).target)
        try await service.delete(target, for: record())
        #expect(await transport.writtenRepository() == "FORK")
        let ref = try #require(await transport.writtenRef())
        #expect(ref.name == "refs/heads/feature/fix")
        #expect(ref.before == record().headRevision)
        #expect(ref.after == String(repeating: "0", count: 40))
        #expect(ref.force == false)
    }
    @Test func changedBranchIsRejectedBeforeDeletion() async throws {
        let transport = BranchCleanupTransport(.available)
        let service = GitHubBranchCleanupService(client: GitHubClient(transport: transport))
        let target = try #require(try await service.snapshot(record()).target)
        await transport.advance()
        await #expect(throws: GitHubRequestError.changed) { try await service.delete(target, for: record()) }
        #expect(await transport.writeCount() == 0)
    }
    @Test func providerDenialIsReportedWithoutClaimingDeletion() async throws {
        let transport = BranchCleanupTransport(.writeDenied)
        let service = GitHubBranchCleanupService(client: GitHubClient(transport: transport))
        let target = try #require(try await service.snapshot(record()).target)
        await #expect(throws: GitHubRequestError.forbidden) { try await service.delete(target, for: record()) }
    }
}
