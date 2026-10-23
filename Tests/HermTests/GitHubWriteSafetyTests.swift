import Foundation
import Testing
@testable import Herm

private actor WriteSafetyTransport: GitHubIssueTransport {
    enum Mode { case denied, staleHead, queue, restrictedProjects, linking, unstable, blocked }
    let mode: Mode
    let methods: [GitHubMergeMethod]
    var reads = 0
    var writes: [[String: String]] = []
    init(_ mode: Mode, methods: [GitHubMergeMethod] = [.merge]) { self.mode = mode; self.methods = methods }
    func mutations() -> [[String: String]] { writes }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let query = body["query"] as? String ?? ""
        let variables = body["variables"] as? [String: Any] ?? [:]
        var status = 200
        let payload: Any
        if mode == .denied { status = 403; payload = ["message": "denied"] }
        else if query.hasPrefix("mutation") {
            let input = variables["input"] as? [String: String] ?? [:]
            writes.append(input.merging(variables.compactMapValues { $0 as? String }, uniquingKeysWith: { a, _ in a }))
            if mode == .unstable {
                payload = ["data": ["mergePullRequest": ["pullRequest": ["id": "PR", "headRefOid": String(repeating: "a", count: 40), "state": "MERGED", "isDraft": false, "mergedAt": "2026-10-18T00:01:00Z", "updatedAt": "2026-10-18T00:01:00Z", "repository": ["viewerPermission": "WRITE", "mergeCommitAllowed": methods.contains(.merge), "squashMergeAllowed": methods.contains(.squash), "rebaseMergeAllowed": methods.contains(.rebase)]]]]]
            } else { payload = ["data": ["accepted": ["clientMutationId": NSNull()]]] }
        } else if mode == .staleHead || mode == .queue || mode == .unstable || mode == .blocked {
            reads += 1
            let head = mode == .staleHead && reads > 1 ? String(repeating: "b", count: 40) : String(repeating: "a", count: 40)
            payload = ["data": ["node": ["id": "PR", "headRefOid": head, "state": "OPEN", "isDraft": false, "mergeable": "MERGEABLE", "mergeStateStatus": mode == .unstable ? "UNSTABLE" : (mode == .blocked ? "BLOCKED" : "CLEAN"), "isMergeQueueEnabled": mode == .queue, "isInMergeQueue": !writes.isEmpty, "repository": ["viewerPermission": "WRITE", "mergeCommitAllowed": methods.contains(.merge), "squashMergeAllowed": methods.contains(.squash), "rebaseMergeAllowed": methods.contains(.rebase)]]]]
        } else if mode == .restrictedProjects {
            if query.contains("projectItems") { payload = ["errors": [["type": "FORBIDDEN", "message": "restricted"]]] }
            else if query.contains("closedByPullRequestsReferences") { payload = ["data": ["node": ["closedByPullRequestsReferences": ["nodes": [], "pageInfo": ["hasNextPage": false]]]]] }
            else if query.contains("linkedBranches") { payload = ["data": ["node": ["linkedBranches": ["nodes": [], "pageInfo": ["hasNextPage": false]]]]] }
            else if !query.isEmpty { payload = ["data": ["node": ["viewerCanUpdate": true]]] }
            else if request.url!.path == "/repos/owner/repo" { payload = ["permissions": ["triage": true]] }
            else { payload = ["node_id": "ISSUE", "title": "Retained", "body": "**Markdown**", "labels": [["name": "bug"]]] }
        } else { payload = ["data": [:]] }
        return (try JSONSerialization.data(withJSONObject: payload), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

struct GitHubWriteSafetyTests {
    private func record() -> PullRequestRecord {
        PullRequestCenterAPI().parse(["number": 1, "node_id": "PR", "title": "Fixture", "head": ["sha": String(repeating: "a", count: 40), "ref": "feature"], "base": ["ref": "main"]], repository: GitHubReferenceParser.repository("owner/repo")!, localPath: "")!
    }
    @Test func landingExplainsIndependentRequirementsAtTheMergeAction() {
        var record = record()
        record.checksAvailable = false
        let snapshot = GitHubLandingSnapshot(id: "PR", head: record.headRevision!, state: "OPEN", draft: true, mergeable: "CONFLICTING", mergeState: "DIRTY", reviewDecision: "REVIEW_REQUIRED", canMerge: false, canAuto: false, canDisableAuto: false, queueEnabled: false, queued: false, autoEnabled: false, methods: [.merge])
        let blockers = snapshot.mergeBlockers(for: record)
        #expect(blockers.contains("You do not have permission to merge this pull request."))
        #expect(blockers.contains("Mark this draft ready for review before merging."))
        #expect(blockers.contains("Resolve merge conflicts before merging."))
        #expect(blockers.contains("Required approving reviews are still missing."))
        #expect(snapshot.checkWarnings(for: record).contains("Check status is incomplete or unavailable. Refresh to retry."))
    }
    @Test func landingExplainsProviderRulesWithoutInventingSpecificRequirements() {
        var record = record(); record.checksAvailable = true
        func snapshot(_ mergeState: String) -> GitHubLandingSnapshot {
            .init(id: "PR", head: record.headRevision!, state: "OPEN", draft: false, mergeable: "MERGEABLE", mergeState: mergeState, reviewDecision: "APPROVED", canMerge: true, canAuto: false, canDisableAuto: false, queueEnabled: false, queued: false, autoEnabled: false, methods: [.merge])
        }
        #expect(snapshot("CLEAN").mergeBlockers(for: record).isEmpty)
        #expect(snapshot("BEHIND").mergeBlockers(for: record) == ["Update the PR branch with the latest base branch changes."])
        #expect(snapshot("BLOCKED").mergeBlockers(for: record) == ["GitHub reports an unmet repository rule. Open on GitHub to see the exact requirement."])
    }
    @Test func nonPassingChecksWarnWithoutOverridingProviderMergeability() async throws {
        let transport = WriteSafetyTransport(.unstable)
        let service = GitHubLandingService(client: GitHubClient(transport: transport))
        var pr = record(); pr.checksAvailable = true
        pr.checks = [.init(id: "verify", name: "verify", status: "completed", conclusion: "failure", detailsURL: nil)]
        let confirmed = try await service.snapshot(pr)
        #expect(confirmed.canMergeNow)
        #expect(confirmed.mergeBlockers(for: pr).isEmpty)
        #expect(confirmed.checkWarnings(for: pr) == ["Failing checks: verify."])
        let merged = try await service.perform(.merge, method: .merge, record: pr, confirmed: confirmed)
        #expect(merged.status == "Merged")
        #expect(await transport.mutations().first?["expectedHeadOid"] == pr.headRevision)
    }
    @Test(arguments: GitHubMergeMethod.allCases)
    func selectedMergeMethodReachesGitHubWithExpectedHead(method: GitHubMergeMethod) async throws {
        let transport = WriteSafetyTransport(.unstable, methods: GitHubMergeMethod.allCases)
        let service = GitHubLandingService(client: GitHubClient(transport: transport))
        let pr = record()
        let confirmed = try await service.snapshot(pr)
        #expect(confirmed.methods == GitHubMergeMethod.allCases)
        let updated = try await service.perform(.merge, method: method, record: pr, confirmed: confirmed)
        #expect(updated.state == "MERGED")
        let writes = await transport.mutations()
        #expect(writes.count == 1)
        #expect(writes.first?["mergeMethod"] == method.rawValue)
        #expect(writes.first?["expectedHeadOid"] == pr.headRevision)
    }

    @Test func unavailableMergeMethodNeverWrites() async throws {
        let transport = WriteSafetyTransport(.unstable, methods: [.squash])
        let service = GitHubLandingService(client: GitHubClient(transport: transport))
        let pr = record()
        let confirmed = try await service.snapshot(pr)
        #expect(confirmed.methods == [.squash])
        await #expect(throws: GitHubRequestError.forbidden) {
            try await service.perform(.merge, method: .merge, record: pr, confirmed: confirmed)
        }
        #expect(await transport.mutations().isEmpty)
    }

    @Test func providerBlockedStateStillRejectsMergeWithFailingChecks() async throws {
        let transport = WriteSafetyTransport(.blocked)
        let service = GitHubLandingService(client: GitHubClient(transport: transport))
        var pr = record(); pr.checksAvailable = true
        pr.checks = [.init(id: "verify", name: "verify", status: "completed", conclusion: "failure", detailsURL: nil)]
        let confirmed = try await service.snapshot(pr)
        #expect(!confirmed.canMergeNow)
        #expect(confirmed.mergeBlockers(for: pr).contains("GitHub reports an unmet repository rule. Open on GitHub to see the exact requirement."))
        await #expect(throws: GitHubRequestError.forbidden) { try await service.perform(.merge, method: .merge, record: pr, confirmed: confirmed) }
        #expect(await transport.mutations().isEmpty)
    }

    @Test func changedHeadRejectsLandingBeforeAnyMutation() async throws {
        let transport = WriteSafetyTransport(.staleHead)
        let service = GitHubLandingService(client: GitHubClient(transport: transport))
        let record = record(); let confirmed = try await service.snapshot(record)
        await #expect(throws: GitHubRequestError.changed) { try await service.perform(.merge, method: .merge, record: record, confirmed: confirmed) }
        #expect(await transport.mutations().isEmpty)
    }
    @Test func queueMutationCarriesExpectedHeadAndNeverReportsMerged() async throws {
        let transport = WriteSafetyTransport(.queue)
        let service = GitHubLandingService(client: GitHubClient(transport: transport))
        let record = record(); let confirmed = try await service.snapshot(record)
        let result = try await service.perform(.enqueue, method: .merge, record: record, confirmed: confirmed)
        #expect(result.queued)
        #expect(result.status == "Queued · waiting for GitHub")
        #expect(await transport.mutations().first?["expectedHeadOid"] == record.headRevision)
        #expect(await transport.mutations().first?["pullRequestId"] == "PR")
    }
    @Test func manualLinkTargetsIssueRegardlessOfNavigationDirection() async throws {
        let transport = WriteSafetyTransport(.linking)
        let service = GitHubMetadataService(client: GitHubClient(transport: transport))
        let repo = GitHubReferenceParser.repository("owner/repo")!
        let pr = GitHubItemReference(repository: repo, number: 1, kind: .pullRequest, nodeID: "PR")
        let issue = GitHubItemReference(repository: repo, number: 2, kind: .issue, nodeID: "ISSUE")
        try await service.link(pr, to: issue, adding: true)
        try await service.link(issue, to: pr, adding: false)
        let writes = await transport.mutations()
        #expect(writes.count == 2)
        #expect(writes.allSatisfy { $0["issue"] == "ISSUE" && $0["pr"] == "PR" })
    }
    @MainActor @Test func deniedReviewRetainsTheDraft() async {
        let model = PullRequestReviewModel(client: GitHubClient(transport: WriteSafetyTransport(.denied)))
        model.draft = "Please add coverage."
        model.event = .requestChanges
        #expect(await model.submit(record()) == false)
        #expect(model.draft == "Please add coverage.")
        #expect(model.error != nil)
    }
    @MainActor @Test func restrictedProjectsDoNotEraseOtherMetadata() async {
        let repo = GitHubReferenceParser.repository("owner/repo")!
        let model = GitHubMetadataModel(reference: .init(repository: repo, number: 1, kind: .issue), client: GitHubClient(transport: WriteSafetyTransport(.restrictedProjects)))
        await model.refresh()
        #expect(model.basic?.title == "Retained")
        #expect(model.basic?.labels.first?.name == "bug")
        #expect(model.projects == nil)
        #expect(model.errors["Projects"] != nil)
        #expect(model.development == [])
    }
}

@MainActor
struct GitHubFeatureStateTests {
    @Test func cachedFilesAreReviewableOnlyForTheirVerifiedRevisions() {
        let store = PullRequestDetailStore()
        let center = PullRequestCenterModel(details: store)
        var record = PullRequestCenterAPI().parse(["number": 1, "title": "Fixture", "head": ["sha": "head"], "base": ["sha": "base"]], repository: GitHubReferenceParser.repository("owner/repo")!, localPath: "")!
        #expect(!center.filesAreCurrent(for: record))
        store.fileRevisions[record.id] = record.diffRevision
        #expect(center.filesAreCurrent(for: record))
        record.headRevision = "new-head"
        #expect(!center.filesAreCurrent(for: record))
        record.headRevision = "head"; record.baseRevision = "new-base"
        #expect(!center.filesAreCurrent(for: record))
    }
    @Test func sharedDetailsKeepListSelectionsAndFiltersIndependent() {
        let details = PullRequestDetailStore()
        let global = PullRequestCenterModel(details: details)
        let session = PullRequestCenterModel(details: details)
        global.selectedID = "global-selection"
        session.selectedID = "session-selection"
        global.filter = .authored
        session.filter = .reviewing
        global.commentDrafts["github:owner/repo#1"] = "Keep this draft"
        #expect(session.commentDrafts["github:owner/repo#1"] == "Keep this draft")
        #expect(global.selectedID == "global-selection")
        #expect(session.selectedID == "session-selection")
        #expect(global.filter == .authored)
        #expect(session.filter == .reviewing)
        session.cancelLoads()
        #expect(global.commentDrafts["github:owner/repo#1"] == "Keep this draft")
    }
    @Test func diffContentThatLooksLikeHeadersStillHasReviewableLineNumbers() {
        let rows = PullRequestDiffPresentation.lines("@@ -2 +2 @@\n--- old content\n+++ new content")
        #expect(rows[1].kind == .deletion)
        #expect(rows[1].oldLine == 2)
        #expect(rows[2].kind == .addition)
        #expect(rows[2].newLine == 2)
        let malformed = PullRequestDiffPresentation.lines("@@ - + @@\n+content")
        #expect(malformed[1].newLine == nil)
    }
}
