import Foundation
import Testing

@testable import Herm

actor BatchReviewTransport: GitHubIssueTransport {
    enum Mode: Sendable { case accepted, changed, denied, uncertain }
    let mode: Mode
    private var posted: Data?
    private var mismatchedComment = false
    private(set) var posts = 0
    init(_ mode: Mode) { self.mode = mode }
    func setCommentMismatch(_ value: Bool) { mismatchedComment = value }
    func body() -> Data? { posted }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let path = request.url!.path
        let head = String(repeating: "a", count: 40)
        let payload: Any
        var status = 200
        if request.httpMethod == "POST", path.hasSuffix("/reviews") {
            posts += 1
            posted = request.httpBody
            if mode == .uncertain { throw URLError(.timedOut) }
            if mode == .denied { status = 403 }
            payload = ["id": 42]
        } else if path == "/repos/owner/repo/pulls/1" {
            payload = ["state": "open", "head": ["sha": mode == .changed ? String(repeating: "b", count: 40) : head]]
        } else if path == "/user" {
            payload = ["login": "reviewer"]
        } else if path.hasSuffix("/reviews") {
            let body = posted.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            payload = [
                [
                    "id": 42, "user": ["login": "reviewer"], "commit_id": head,
                    "state": "COMMENTED", "body": body["body"] as? String ?? "",
                    "submitted_at": ISO8601DateFormatter().string(from: .now),
                ]
            ]
        } else if path.hasSuffix("/reviews/42/comments") {
            let body = posted.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            payload = (body["comments"] as? [[String: Any]] ?? []).map { row in
                var row = row
                row["commit_id"] = head
                if mismatchedComment { row["body"] = "A different comment" }
                return row
            }
        } else if path == "/graphql" {
            payload = [
                "data": [
                    "node": ["headRefOid": head, "reviewThreads": ["nodes": [], "pageInfo": ["hasNextPage": false]]]
                ]
            ]
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
struct GitHubReviewDraftTests {
    private func record() -> PullRequestRecord {
        PullRequestCenterAPI().parse(
            [
                "number": 1, "node_id": "PR", "title": "Fixture", "state": "open",
                "head": ["sha": String(repeating: "a", count: 40)],
            ],
            repository: GitHubReferenceParser.repository("owner/repo")!, localPath: "")!
    }
    private func stage(_ model: PullRequestReviewModel, record: PullRequestRecord) {
        let target = GitHubInlineCommentTarget(
            path: "file.swift", line: 2, side: "RIGHT", revision: record.headRevision!)
        model.inlineDrafts[target.id] = "Check this input"
        #expect(model.stageInline(target, record: record))
    }
    @Test func editingALineDraftKeepsItPrivateAndPreservesUnfinishedEdits() async {
        let transport = BatchReviewTransport(.accepted)
        let model = PullRequestReviewModel(client: GitHubClient(transport: transport))
        let record = record()
        stage(model, record: record)
        let target = model.pendingComments[0].target
        #expect(model.beginInline(target, record: record))
        #expect(model.inlineDrafts[target.id] == "Check this input")
        model.inlineDrafts[target.id] = "Updated feedback"
        #expect(model.beginInline(target, record: record))
        #expect(model.inlineDrafts[target.id] == "Updated feedback")
        #expect(model.pendingComments[0].body == "Check this input")
        #expect(model.stageInline(target, record: record))
        #expect(model.pendingComments.count == 1)
        #expect(model.pendingComments[0].body == "Updated feedback")
        #expect(await transport.posts == 0)
    }

    @Test func invalidAndStaleTargetsCannotStartOrSaveALineComment() {
        let model = PullRequestReviewModel(client: GitHubClient(transport: BatchReviewTransport(.accepted)))
        let record = record()
        for target in [
            GitHubInlineCommentTarget(path: "file.swift", line: 0, side: "RIGHT", revision: record.headRevision!),
            GitHubInlineCommentTarget(path: "../file.swift", line: 1, side: "RIGHT", revision: record.headRevision!),
            GitHubInlineCommentTarget(path: "file.swift", line: 1, side: "UNKNOWN", revision: record.headRevision!),
            GitHubInlineCommentTarget(path: "file.swift", line: 1, side: "LEFT", revision: "old"),
        ] {
            #expect(!model.beginInline(target, record: record))
            model.inlineDrafts[target.id] = "Keep this draft"
            #expect(!model.stageInline(target, record: record))
            #expect(model.inlineDrafts[target.id] == "Keep this draft")
        }
        #expect(model.pendingComments.isEmpty)
    }

    @Test func submissionPolicyExplainsMissingFeedbackAndStaleDrafts() {
        let model = PullRequestReviewModel(client: GitHubClient(transport: BatchReviewTransport(.accepted)))
        let record = record()
        #expect(model.submissionUnavailableReason(record: record, viewer: "reviewer")?.contains("Add a summary") == true)
        stage(model, record: record)
        #expect(model.submissionUnavailableReason(record: record, viewer: "reviewer") == nil)
        #expect(model.submissionUnavailableReason(record: record, viewer: nil) != nil)
        model.pendingComments.append(PendingReviewComment(
            target: GitHubInlineCommentTarget(path: "file.swift", line: 1, side: "RIGHT", revision: "old"), body: "Old draft"))
        #expect(model.submissionUnavailableReason(record: record, viewer: "reviewer")?.contains("earlier revision") == true)
    }

    @Test func lineContextResolvesTheCorrectDiffSide() {
        let document = DiffDocument(path: "file.swift", patch: "@@ -4,2 +7,2 @@\n-old\n+new\n context")
        let left = GitHubInlineCommentTarget(path: "file.swift", line: 4, side: "LEFT", revision: "head")
        let right = GitHubInlineCommentTarget(path: "file.swift", line: 7, side: "RIGHT", revision: "head")
        #expect(left.source(in: document).map(DiffDocument.source) == "old")
        #expect(right.source(in: document).map(DiffDocument.source) == "new")
        let missing = GitHubInlineCommentTarget(path: "other.swift", line: 7, side: "RIGHT", revision: "head")
        #expect(missing.source(in: document) == nil)
    }

    @Test func commentsRemainPrivateUntilOneBatchSubmission() async throws {
        let transport = BatchReviewTransport(.accepted)
        let model = PullRequestReviewModel(client: GitHubClient(transport: transport))
        let record = record()
        stage(model, record: record)
        #expect(await transport.posts == 0)
        model.draft = "Review summary"
        #expect(await model.submit(record))
        #expect(await transport.posts == 1)
        let data = try #require(await transport.body())
        let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(payload["commit_id"] as? String == record.headRevision)
        #expect((payload["comments"] as? [Any])?.count == 1)
        #expect(model.pendingComments.isEmpty && model.draft.isEmpty)
    }
    @Test(arguments: [BatchReviewTransport.Mode.changed, .denied])
    func rejectionPreservesReviewDraft(mode: BatchReviewTransport.Mode) async {
        let transport = BatchReviewTransport(mode)
        let model = PullRequestReviewModel(client: GitHubClient(transport: transport))
        let record = record()
        stage(model, record: record)
        model.draft = "Keep this review"
        #expect(!(await model.submit(record)))
        #expect(model.pendingComments.count == 1 && model.draft == "Keep this review")
        #expect(!model.uncertainSubmission)
        #expect(await transport.posts == (mode == .changed ? 0 : 1))
    }
    @Test func uncertainDeliveryRequiresMatchingCommentsBeforeClearing() async {
        let transport = BatchReviewTransport(.uncertain)
        let model = PullRequestReviewModel(client: GitHubClient(transport: transport))
        let record = record()
        stage(model, record: record)
        #expect(!(await model.submit(record)))
        #expect(model.uncertainSubmission)
        #expect(!(await model.submit(record)))
        #expect(await transport.posts == 1)
        await transport.setCommentMismatch(true)
        await model.checkSubmission(record)
        #expect(model.uncertainSubmission && model.pendingComments.count == 1)
        await transport.setCommentMismatch(false)
        await model.checkSubmission(record)
        #expect(!model.uncertainSubmission && model.pendingComments.isEmpty)
        #expect(await transport.posts == 1)
    }
}
