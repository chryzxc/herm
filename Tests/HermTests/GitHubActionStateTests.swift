import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Herm

private actor LifecycleTransport: GitHubIssueTransport {
    let failRead: Bool
    init(failRead: Bool = false) { self.failRead = failRead }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let query = body["query"] as? String ?? ""
        let payload: Any
        var status = 200
        if query.hasPrefix("mutation") {
            let operation =
                query.contains("markPullRequestReadyForReview")
                ? "markPullRequestReadyForReview" : "convertPullRequestToDraft"
            payload = [
                "data": [
                    operation: [
                        "pullRequest": [
                            "id": "PR", "isDraft": operation == "convertPullRequestToDraft", "state": "OPEN",
                            "updatedAt": "2026-10-18T00:01:00Z",
                        ]
                    ]
                ]
            ]
        } else if request.url!.path == "/repos/owner/repo/pulls/1" {
            // Reproduce a successful write followed by an older REST snapshot.
            if failRead { status = 503 }
            payload = [
                "number": 1, "node_id": "PR", "title": "Fixture", "state": "open", "draft": true,
                "updated_at": "2026-10-18T00:00:00Z", "head": ["sha": String(repeating: "a", count: 40)],
                "base": ["sha": String(repeating: "b", count: 40)],
            ]
        } else if request.url!.path == "/graphql" {
            payload = ["data": [:]]
        } else if request.url!.path.hasSuffix("check-runs") {
            payload = ["check_runs": []]
        } else {
            payload = []
        }
        return (
            try JSONSerialization.data(withJSONObject: payload),
            HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        )
    }
}

@MainActor
private final class SuspendedStatusWrite: PullRequestMutationExecuting {
    var continuation: CheckedContinuation<PullRequestRecord?, Never>?
    var calls = 0
    func postComment(_ body: String, on record: PullRequestRecord) async -> PullRequestComment? { nil }
    func updateStatus(_ status: PullRequestStatus, for record: PullRequestRecord) async -> PullRequestRecord? {
        calls += 1
        return await withCheckedContinuation { continuation = $0 }
    }
}

@MainActor
struct GitHubActionStateTests {
    private func record() -> PullRequestRecord {
        PullRequestCenterAPI().parse(
            [
                "number": 1, "node_id": "PR", "title": "Fixture", "draft": true,
                "head": ["sha": String(repeating: "a", count: 40)], "base": ["sha": String(repeating: "b", count: 40)],
            ], repository: GitHubReferenceParser.repository("owner/repo")!, localPath: "")!
    }

    @Test(arguments: [false, true])
    func confirmedLifecycleSurvivesStaleOrUnavailableFollowUpRead(failRead: Bool) async throws {
        let api = PullRequestCenterAPI(transport: LifecycleTransport(failRead: failRead))
        let updated = try #require(await api.updateStatus(.readyForReview, for: record()))
        #expect(!updated.isDraft)
        #expect(updated.state == "open")
        if failRead { #expect(updated.detailWarning?.contains("Status updated") == true) }
        #expect(updated.updatedAt == Date(timeIntervalSince1970: 1_792_281_660))
    }

    @Test func confirmedRequestSurvivesDialogDismissalAndPendingStateCoversWrite() async throws {
        let executor = SuspendedStatusWrite()
        let details = PullRequestDetailStore()
        let center = PullRequestCenterModel(mutationExecutor: executor, details: details)
        let coordinator = PullRequestMutationCoordinator()
        var pr = record()
        coordinator.requestStatus(.readyForReview, for: pr)
        let request = try #require(coordinator.pending)
        coordinator.cancel()  // SwiftUI dismisses the dialog before the Task executes.
        let task = Task { await coordinator.confirm(request, using: center) }
        for _ in 0..<100 where executor.continuation == nil { await Task.yield() }
        let continuation = try #require(executor.continuation)
        #expect(center.isUpdatingStatus)
        #expect(center.updatingStatusID == pr.id)
        #expect(await center.updateStatus(.closed, for: pr) == false)
        #expect(executor.calls == 1)
        pr.isDraft = false
        pr.refreshedAt = .now
        continuation.resume(returning: pr)
        #expect(await task.value)
        #expect(!center.isUpdatingStatus)
        #expect(center.updatingStatusID == nil)
        #expect(details.records[pr.id]?.isDraft == false)
    }

    @Test(arguments: [GitHubBrowseState.open, .closed, .all])
    func issueLifecycleAppliesConfirmedStateAndPreservesRepositoryMapping(scope: GitHubBrowseState) throws {
        let repo = GitHubReferenceParser.repository("owner/repo")!
        let issue = GitHubIssueRecord(
            repository: repo, localPath: "/tmp/local-repo", number: 1, title: "Fixture", body: "Keep context",
            state: "open", author: "ada", assignee: nil, updatedAt: nil, webURL: nil)
        let center = IssueCenterModel()
        center.browsing.state = scope
        center.records = [issue]
        center.selectedIssueID = issue.id
        var confirmed = issue
        confirmed.state = "closed"
        confirmed.updatedAt = .now
        center.applyIssueState(confirmed)
        #expect(center.detailByID[issue.id]?.state == "closed")
        #expect(center.detailByID[issue.id]?.localPath == "/tmp/local-repo")
        if scope == .open { #expect(center.records.isEmpty) } else { #expect(center.selected?.state == "closed") }
        confirmed.state = "open"
        center.applyIssueState(confirmed)
        if scope == .closed { #expect(center.records.isEmpty) }
        if scope == .all { #expect(center.selected?.state == "open") }
    }

    @Test func olderSummaryCannotRevertConfirmedLifecycleState() async {
        let center = PullRequestCenterModel(api: PullRequestCenterAPI(transport: LifecycleTransport()))
        var confirmed = record()
        confirmed.isDraft = false
        confirmed.updatedAt = Date(timeIntervalSince1970: 1_792_281_660)
        center.details.records[confirmed.id] = confirmed
        let result = await center.loadSummary(for: record())
        #expect(result?.isDraft == false)
        #expect(center.details.records[confirmed.id]?.isDraft == false)
    }

    @Test func confirmedMergeUpdatesSharedDetailsAndSurvivesStaleRefreshes() async throws {
        let details = PullRequestDetailStore()
        let api = PullRequestCenterAPI(transport: LifecycleTransport())
        let center = PullRequestCenterModel(api: api, details: details)
        let pr = record()
        await center.open(pr.reference)
        center.browsing.state = .open
        let snapshot = GitHubLandingSnapshot(
            id: "PR", head: pr.headRevision!, state: "MERGED", draft: false, mergeable: "UNKNOWN",
            mergeState: "UNKNOWN", reviewDecision: nil, canMerge: true, canAuto: false, canDisableAuto: false,
            queueEnabled: false, queued: false, autoEnabled: false, methods: [.merge],
            mergedAt: Date(timeIntervalSince1970: 1_792_281_660), updatedAt: Date(timeIntervalSince1970: 1_792_281_660))
        center.applyLandingSnapshot(snapshot, for: pr)
        #expect(center.selected?.mergedAt == snapshot.mergedAt)
        #expect(center.selected?.state == "closed")
        #expect(center.selected?.availableStatusActions.isEmpty == true)
        #expect(center.visible.isEmpty)
        await center.refreshSelectedDetail()
        #expect(center.selected?.mergedAt == snapshot.mergedAt)
        #expect(center.selected?.state == "closed")
        let otherHost = PullRequestCenterModel(api: api, details: details)
        await otherHost.open(pr.reference)
        #expect(otherHost.selected?.mergedAt == snapshot.mergedAt)
        #expect(otherHost.records.first?.state == "closed")
        var queued = snapshot
        queued.mergedAt = nil
        let untouched = PullRequestCenterModel()
        untouched.applyLandingSnapshot(queued, for: pr)
        #expect(untouched.details.records.isEmpty)
    }

    @Test func failedStatusClearsPendingAndRetainsKnownState() async throws {
        let executor = SuspendedStatusWrite()
        let center = PullRequestCenterModel(mutationExecutor: executor)
        let pr = record()
        center.details.records[pr.id] = pr
        let task = Task { await center.updateStatus(.readyForReview, for: pr) }
        for _ in 0..<100 where executor.continuation == nil { await Task.yield() }
        let continuation = try #require(executor.continuation)
        continuation.resume(returning: nil)
        #expect(await task.value == false)
        #expect(!center.isUpdatingStatus)
        #expect(center.errorMessage != nil)
        #expect(center.details.records[pr.id]?.isDraft == true)
    }
}

private actor ReviewActionTransport: GitHubIssueTransport {
    private var write: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    func waitForWrite() async {
        if write != nil { return }
        await withCheckedContinuation { observer = $0 }
    }
    func finishWrite() {
        write?.resume()
        write = nil
    }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let query = body["query"] as? String ?? ""
        let payload: Any
        if request.httpMethod == "POST", request.url!.path.hasSuffix("/reviews") {
            await withCheckedContinuation {
                write = $0
                observer?.resume()
                observer = nil
            }
            payload = ["id": 1]
        } else if query.contains("reviewThreads") {
            payload = [
                "data": [
                    "node": [
                        "headRefOid": String(repeating: "a", count: 40),
                        "reviewThreads": ["nodes": [], "totalCount": 0, "pageInfo": ["hasNextPage": false]],
                    ]
                ]
            ]
        } else {
            payload = ["state": "open", "head": ["sha": String(repeating: "a", count: 40)]]
        }
        return (
            try JSONSerialization.data(withJSONObject: payload),
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
    }
}

extension GitHubActionStateTests {
    @Test func reviewPendingCoversProviderWriteAndDraftClearsOnlyAfterSuccess() async {
        let transport = ReviewActionTransport()
        let model = PullRequestReviewModel(client: GitHubClient(transport: transport))
        model.draft = "Reviewed the changes."
        model.event = .comment
        let task = Task { await model.submit(record()) }
        await transport.waitForWrite()
        #expect(model.busy)
        #expect(model.pendingAction == .submit)
        #expect(model.draft == "Reviewed the changes.")
        if let directory = ProcessInfo.processInfo.environment["GITHUB_ACTION_SNAPSHOT_DIR"] {
            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let savedTheme = DockThemeRuntime.current
            defer { DockThemeRuntime.current = savedTheme }
            for theme: DockThemeID in [.notebook, .terminal, .glass, .mono] {
                DockThemeRuntime.current = theme
                let root = PullRequestReviewView(model: model, record: record(), viewer: "reviewer", onChanged: {})
                    .frame(width: 560, height: 680).background(Color.dockCanvas).dockThemedRoot()
                let host = NSHostingView(rootView: root)
                host.frame = CGRect(x: 0, y: 0, width: 560, height: 680)
                let window = NSWindow(
                    contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: theme == .notebook ? .aqua : .darkAqua)
                window.contentView = host
                window.orderFrontRegardless()
                for _ in 0..<3 {
                    host.layoutSubtreeIfNeeded()
                    try? await Task.sleep(for: .milliseconds(80))
                }
                if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    if let png = bitmap.representation(using: .png, properties: [:]) {
                        try? png.write(
                            to: URL(fileURLWithPath: directory).appendingPathComponent(
                                "pending-review-\(theme.rawValue).png"))
                    }
                }
                window.orderOut(nil)
            }
        }
        #expect(await model.submit(record()) == false)
        await transport.finishWrite()
        #expect(await task.value)
        #expect(!model.busy)
        #expect(model.pendingAction == nil)
        #expect(model.draft.isEmpty)
        #expect(model.revision == record().headRevision)
    }
}
