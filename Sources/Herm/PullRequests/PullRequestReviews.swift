import SwiftUI

struct GitHubReviewThread: Identifiable, Equatable, Sendable {
    let id: String
    let path: String
    let line: Int?
    let side: String
    let resolved: Bool
    let outdated: Bool
    let canResolve: Bool
    let canUnresolve: Bool
    var comments: [GitHubConversationItem]
    var partial = false
}
enum GitHubReviewEvent: String, CaseIterable, Identifiable {
    case comment = "COMMENT", approve = "APPROVE", requestChanges = "REQUEST_CHANGES"
    var id: Self { self }
    var title: String { switch self { case .comment: "Comment"; case .approve: "Approve"; case .requestChanges: "Request changes" } }
}
struct GitHubInlineCommentTarget: Identifiable {
    let path: String
    let line: Int
    let side: String
    let revision: String
    var id: String { "\(revision):\(path):\(side):\(line)" }
}

struct GitHubReviewService: Sendable {
    let client: GitHubClient
    static let viewerPath = "/user"
    static let commentFields = "id body createdAt url author{login avatarUrl}"
    func threads(_ record: PullRequestRecord) async throws -> GitHubPage<GitHubReviewThread> {
        guard let nodeID = record.nodeID else { throw GitHubRequestError.unavailable }
        var cursor: String? = nil; var threads: [GitHubReviewThread] = []; var coverage = GitHubCoverage()
        for _ in 0..<30 {
            let query = "query($id:ID!,$after:String){node(id:$id){... on PullRequest{headRefOid reviewThreads(first:100,after:$after){nodes{id path line originalLine diffSide isResolved isOutdated viewerCanResolve viewerCanUnresolve comments(first:100){nodes{\(Self.commentFields)} pageInfo{hasNextPage endCursor}}} pageInfo{hasNextPage endCursor} totalCount}}}}"
            let data = try await client.graphQL(query, variables: ["id": nodeID, "after": cursor as Any? ?? NSNull()])
            guard let node = data["node"] as? [String: Any], node["headRefOid"] as? String == record.headRevision else { throw GitHubRequestError.changed }
            guard let connection = node["reviewThreads"] as? [String: Any], let rows = connection["nodes"] as? [[String: Any]] else { throw GitHubRequestError.malformed }
            for row in rows {
                guard let id = row["id"] as? String, let path = row["path"] as? String, let comments = row["comments"] as? [String: Any] else { continue }
                var thread = GitHubReviewThread(id: id, path: path, line: row["line"] as? Int ?? row["originalLine"] as? Int, side: row["diffSide"] as? String ?? "RIGHT", resolved: row["isResolved"] as? Bool ?? false, outdated: row["isOutdated"] as? Bool ?? false, canResolve: row["viewerCanResolve"] as? Bool ?? false, canUnresolve: row["viewerCanUnresolve"] as? Bool ?? false, comments: (comments["nodes"] as? [[String: Any]] ?? []).compactMap(Self.comment))
                if (comments["pageInfo"] as? [String: Any])?["hasNextPage"] as? Bool == true {
                    do { thread.comments = try await threadComments(id) } catch { thread.partial = true; coverage.partial = true }
                }
                threads.append(thread)
            }
            coverage.loaded = threads.count; coverage.total = connection["totalCount"] as? Int
            let page = connection["pageInfo"] as? [String: Any]
            guard page?["hasNextPage"] as? Bool == true else { return GitHubPage(items: threads, coverage: coverage) }
            guard let next = page?["endCursor"] as? String, next != cursor else { throw GitHubRequestError.malformed }; cursor = next
        }
        coverage.partial = true
        return GitHubPage(items: threads, coverage: coverage)
    }
    private func threadComments(_ id: String) async throws -> [GitHubConversationItem] {
        var cursor: String? = nil; var items: [GitHubConversationItem] = []
        for _ in 0..<30 {
            let data = try await client.graphQL("query($id:ID!,$after:String){node(id:$id){... on PullRequestReviewThread{comments(first:100,after:$after){nodes{\(Self.commentFields)} pageInfo{hasNextPage endCursor}}}}}", variables: ["id": id, "after": cursor as Any? ?? NSNull()])
            guard let connection = (data["node"] as? [String: Any])?["comments"] as? [String: Any], let rows = connection["nodes"] as? [[String: Any]] else { throw GitHubRequestError.malformed }
            items += rows.compactMap(Self.comment)
            let page = connection["pageInfo"] as? [String: Any]
            guard page?["hasNextPage"] as? Bool == true else { return items }
            guard let next = page?["endCursor"] as? String, next != cursor else { throw GitHubRequestError.malformed }; cursor = next
        }
        throw GitHubRequestError.unavailable
    }
    static func comment(_ row: [String: Any]) -> GitHubConversationItem? {
        guard let id = row["id"] as? String else { return nil }
        return GitHubConversationItem(id: id, author: (row["author"] as? [String: Any])?["login"] as? String ?? "Unknown", summary: "commented", body: row["body"] as? String ?? "", date: (row["createdAt"] as? String).flatMap { try? Date($0, strategy: .iso8601) }, url: (row["url"] as? String).flatMap(URL.init), avatarURL: ((row["author"] as? [String: Any])?["avatarUrl"] as? String).flatMap(URL.init))
    }
    func verifyHead(_ record: PullRequestRecord) async throws {
        guard let expected = record.headRevision, GitHubConflictService.validRevision(expected),
              let row = try await client.request(record.repository.apiRepositoryPath + "/pulls/\(record.number)") as? [String: Any],
              (row["head"] as? [String: Any])?["sha"] as? String == expected, row["state"] as? String == "open" else { throw GitHubRequestError.changed }
    }
    func submit(_ event: GitHubReviewEvent, body: String, on record: PullRequestRecord, comments: [PendingReviewComment] = []) async throws {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard body.count <= 10_000, event == .approve || !trimmed.isEmpty || !comments.isEmpty else { throw GitHubRequestError.malformed }
        try await verifyHead(record)
        guard comments.count <= 100, comments.allSatisfy({ $0.target.revision == record.headRevision && $0.target.line > 0 && ["LEFT", "RIGHT"].contains($0.target.side) && RepositoryService.isSafeRelativePath($0.target.path) && !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.body.count <= 10_000 }) else { throw GitHubRequestError.changed }
        var payload: [String: Any] = ["event": event.rawValue, "body": trimmed, "commit_id": record.headRevision!]
        if !comments.isEmpty {
            payload["comments"] = comments.map { ["path": $0.target.path, "line": $0.target.line, "side": $0.target.side, "body": $0.body] as [String: Any] }
        }
        _ = try await client.request(record.repository.apiRepositoryPath + "/pulls/\(record.number)/reviews", method: "POST", body: payload)
    }
    func inlineComment(_ body: String, target: GitHubInlineCommentTarget, on record: PullRequestRecord) async throws {
        guard target.revision == record.headRevision, target.line > 0, ["LEFT", "RIGHT"].contains(target.side), !target.path.hasPrefix("/"), !target.path.split(separator: "/").contains(".."), !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, body.count <= 10_000 else { throw GitHubRequestError.malformed }
        try await verifyHead(record)
        _ = try await client.request(record.repository.apiRepositoryPath + "/pulls/\(record.number)/comments", method: "POST", body: ["body": body, "commit_id": target.revision, "path": target.path, "line": target.line, "side": target.side])
    }
    func reply(_ body: String, threadID: String) async throws {
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, body.count <= 10_000 else { throw GitHubRequestError.malformed }
        _ = try await client.graphQL("mutation($id:ID!,$body:String!){addPullRequestReviewThreadReply(input:{pullRequestReviewThreadId:$id,body:$body}){comment{id}}}", variables: ["id": threadID, "body": body])
    }
    func resolve(_ thread: GitHubReviewThread) async throws {
        guard thread.resolved ? thread.canUnresolve : thread.canResolve else { throw GitHubRequestError.forbidden }
        let operation = thread.resolved ? "unresolveReviewThread" : "resolveReviewThread"
        _ = try await client.graphQL("mutation($id:ID!){\(operation)(input:{threadId:$id}){thread{id isResolved}}}", variables: ["id": thread.id])
    }
}

enum GitHubReviewPendingAction: Equatable {
    case submit, reply(String), resolve(String), inline(String)
}

@MainActor
final class PullRequestReviewModel: ObservableObject {
    let service: GitHubReviewService
    @Published private(set) var threads: [GitHubReviewThread] = []
    @Published private(set) var loading = false
    @Published private(set) var pendingAction: GitHubReviewPendingAction?
    var busy: Bool { pendingAction != nil }
    private var loadGeneration = UUID()
    @Published private(set) var revision: String?
    @Published private(set) var error: String?
    @Published var draft = ""
    @Published var event: GitHubReviewEvent = .comment
    @Published var replies: [String: String] = [:]
    @Published var inlineDrafts: [String: String] = [:]
    @Published var pendingComments: [PendingReviewComment] = []
    @Published private(set) var uncertainSubmission = false
    private var submittedReviewBody: String?
    private var submittedReviewHead: String?
    private var submittedEvent: GitHubReviewEvent?
    private var submittedComments: [PendingReviewComment] = []
    private var submissionDate: Date?

    func stageInline(_ target: GitHubInlineCommentTarget, record: PullRequestRecord) -> Bool {
        let body = inlineDrafts[target.id] ?? ""
        guard !busy, !uncertainSubmission, target.revision == record.headRevision,
              !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, body.count <= 10_000 else { return false }
        pendingComments.removeAll { $0.target.id == target.id }
        pendingComments.append(PendingReviewComment(target: target, body: body))
        inlineDrafts[target.id] = nil
        return true
    }

    func checkSubmission(_ record: PullRequestRecord) async {
        guard uncertainSubmission, !busy else { return }
        pendingAction = .submit; defer { pendingAction = nil }
        do {
            let page = try await service.client.pages(record.repository.apiRepositoryPath + "/pulls/\(record.number)/reviews")
            guard !page.coverage.partial else { throw GitHubRequestError.unavailable }
            let viewer = try await service.client.request(GitHubReviewService.viewerPath) as? [String: Any]
            let login = viewer?["login"] as? String
            let expectedState = submittedEvent.map { event in
                switch event { case .comment: "COMMENTED"; case .approve: "APPROVED"; case .requestChanges: "CHANGES_REQUESTED" }
            }
            var found = false
            for review in page.rows {
                let user = review["user"] as? [String: Any]
                let date = (review["submitted_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
                guard login != nil, user?["login"] as? String == login,
                      review["commit_id"] as? String == submittedReviewHead, review["state"] as? String == expectedState,
                      review["body"] as? String == submittedReviewBody,
                      date.map({ $0 >= (submissionDate ?? .distantFuture).addingTimeInterval(-5) }) == true,
                      let id = review["id"] as? Int else { continue }
                let comments = try await service.client.pages(record.repository.apiRepositoryPath + "/pulls/\(record.number)/reviews/\(id)/comments")
                guard !comments.coverage.partial else { throw GitHubRequestError.unavailable }
                if comments.rows.count == submittedComments.count && submittedComments.allSatisfy({ expected in
                    comments.rows.contains { row in
                        row["path"] as? String == expected.target.path && row["line"] as? Int == expected.target.line &&
                        row["side"] as? String == expected.target.side && row["body"] as? String == expected.body &&
                        row["commit_id"] as? String == expected.target.revision
                    }
                }) { found = true; break }
            }
            if found {
                uncertainSubmission = false
                pendingComments.removeAll { saved in submittedComments.contains { $0.id == saved.id } }
                if draft.trimmingCharacters(in: .whitespacesAndNewlines) == submittedReviewBody { draft = "" }
                error = nil; await refresh(record, force: true)
            } else { error = "Submission is not confirmed. Check the review on GitHub before allowing a deliberate retry." }
        } catch { self.error = error.localizedDescription }
    }
    func allowReviewRetry() { uncertainSubmission = false }

    init(client: GitHubClient) { service = GitHubReviewService(client: client) }
    func refresh(_ record: PullRequestRecord, force: Bool = false) async {
        guard !loading || force else { return }
        let token = UUID(); loadGeneration = token; loading = true
        defer { if token == loadGeneration { loading = false } }
        do {
            let page = try await service.threads(record); try Task.checkCancellation()
            guard token == loadGeneration else { return }
            threads = page.items; revision = record.headRevision; error = page.coverage.label
        } catch { if !Task.isCancelled, token == loadGeneration { self.error = error.localizedDescription } }
    }
    func submit(_ record: PullRequestRecord) async -> Bool {
        guard !busy, !uncertainSubmission else { return false }
        pendingAction = .submit; defer { pendingAction = nil }
        let submitted = draft; let comments = pendingComments
        submittedReviewBody = submitted.trimmingCharacters(in: .whitespacesAndNewlines)
        submittedReviewHead = record.headRevision; submissionDate = .now
        submittedEvent = event; submittedComments = comments
        do {
            try await service.submit(event, body: submitted, on: record, comments: comments)
            if draft == submitted { draft = "" }
            pendingComments.removeAll { saved in comments.contains { $0.id == saved.id } }
            error = nil; await refresh(record, force: true); return true
        } catch {
            if let known = error as? GitHubRequestError { uncertainSubmission = known == .unavailable || known == .malformed }
            else { uncertainSubmission = true }
            self.error = error.localizedDescription; return false
        }
    }

    func reply(_ thread: GitHubReviewThread, record: PullRequestRecord) async {
        guard !busy, threads.contains(where: { $0.id == thread.id }) else { return }; pendingAction = .reply(thread.id); defer { pendingAction = nil }
        let submitted = replies[thread.id] ?? ""
        do { try await service.reply(submitted, threadID: thread.id); if replies[thread.id] == submitted { replies[thread.id] = nil }; await refresh(record, force: true) }
        catch { self.error = error.localizedDescription }
    }
    func resolve(_ thread: GitHubReviewThread, record: PullRequestRecord) async {
        guard !busy else { return }; pendingAction = .resolve(thread.id); defer { pendingAction = nil }
        do { try await service.resolve(thread); await refresh(record, force: true) } catch { self.error = error.localizedDescription }
    }
    func postInline(_ target: GitHubInlineCommentTarget, record: PullRequestRecord) async -> Bool {
        guard !busy else { return false }; pendingAction = .inline(target.id); defer { pendingAction = nil }
        let body = inlineDrafts[target.id] ?? ""
        do { try await service.inlineComment(body, target: target, on: record); if inlineDrafts[target.id] == body { inlineDrafts[target.id] = nil }; await refresh(record, force: true); return true }
        catch { self.error = error.localizedDescription; return false }
    }
}

struct PullRequestReviewView: View {
    @ObservedObject var model: PullRequestReviewModel
    let record: PullRequestRecord
    let viewer: String?
    let onChanged: () -> Void
    @State private var unresolvedOnly = true
    @State private var confirm = false
    @State private var confirmRetry = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    ViewThatFits(in: .horizontal) {
                        HStack {
                            Text("Review threads").font(.system(size: 12, weight: .semibold))
                            Spacer(minLength: 12)
                            threadControls
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Review threads").font(.system(size: 12, weight: .semibold))
                            threadControls
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        if let error = model.error {
                            Text(error).foregroundStyle(Color.dockWarning)
                        }
                        if model.revision == nil {
                            Text(model.loading ? "Loading review threads…" : "Review threads are unavailable.")
                                .foregroundStyle(Color.dockSecondaryText)
                        } else if model.threads.filter({ !unresolvedOnly || !$0.resolved }).isEmpty {
                            Text(unresolvedOnly ? "No unresolved threads" : "No review threads")
                                .font(.system(size: 12, weight: .semibold))
                            Text(unresolvedOnly && !model.threads.isEmpty
                                ? "Turn off Unresolved only to see resolved discussions."
                                : "Comments on changed lines will appear here. Add one from the Code tab.")
                                .foregroundStyle(Color.dockSecondaryText)
                        }
                        PullRequestThreadListView(model: model, record: record, path: nil, unresolvedOnly: unresolvedOnly)
                    }
                    .frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
                }
                Color.dockBorderLight.frame(height: DockLayout.hairline)
                HStack {
                    Text("Your review").font(.system(size: 12, weight: .semibold))
                    Spacer(minLength: 12)
                    Picker("Review type", selection: $model.event) {
                        ForEach(GitHubReviewEvent.allCases) { event in Text(event.title).tag(event) }
                    }
                    .labelsHidden().pickerStyle(.menu).fixedSize()
                    .disabled(model.busy || model.uncertainSubmission)
                }
                ForEach(model.pendingComments) { comment in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(comment.target.path):\(comment.target.line)").font(.system(size: 12, weight: .semibold))
                            Text(comment.body).font(DockTypography.body).textSelection(.enabled)
                            if comment.target.revision != record.headRevision { Text("Source revision changed").foregroundStyle(Color.dockWarning) }
                        }
                        Spacer()
                        Button("Remove") { model.pendingComments.removeAll { $0.id == comment.id } }.buttonStyle(.dockCompact).disabled(model.busy || model.uncertainSubmission)
                    }
                }
                if model.uncertainSubmission {
                    HStack {
                        Button("Check submission") { Task { await model.checkSubmission(record) } }.buttonStyle(.dockCompact).disabled(model.busy)
                        Button("I checked on GitHub; allow retry…") { confirmRetry = true }.buttonStyle(.dockCompact).disabled(model.busy)
                    }
                }
                GitHubMarkdownDraft(text: $model.draft, placeholder: "Leave feedback on these changes…", minimumHeight: 160)
                    .disabled(model.busy || model.uncertainSubmission)
                HStack {
                    Text("Markdown supported").font(DockTypography.metadata).foregroundStyle(Color.dockMetadataText)
                    Spacer(minLength: 12)
                    Button { confirm = true } label: { GitHubActionLabel(title: model.pendingAction == .submit ? "Submitting…" : "Review and submit", isBusy: model.pendingAction == .submit) }.buttonStyle(.dockPrimary).controlSize(.small)
                    .disabled(model.busy || model.uncertainSubmission || viewer == nil || record.state != "open" || record.headRevision == nil || model.draft.count > 10_000 || (model.event != .approve && model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.pendingComments.isEmpty) || (model.event != .comment && viewer?.caseInsensitiveCompare(record.author) == .orderedSame))
                }
            }.padding(20)
        }
        .font(DockTypography.body).foregroundStyle(Color.dockPrimaryText)
        .confirmationDialog("Allow a deliberate retry?", isPresented: $confirmRetry) {
            Button("I checked; allow retry") { model.allowReviewRetry() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Confirm on GitHub that the review was not posted. Retrying a review that already arrived creates a duplicate.") }
        .task(id: record.headRevision) { if model.revision != record.headRevision { await model.refresh(record) } }
        .confirmationDialog("\(model.event.title) on \(record.reference.title)?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Submit review") { Task { if await model.submit(record) { onChanged() } } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Revision \(record.headRevision ?? "unknown")\n\n\(model.draft)") }
    }

    private var threadControls: some View {
        HStack(spacing: 8) {
            Toggle("Unresolved only", isOn: $unresolvedOnly).toggleStyle(.dockSwitch)
            Button { Task { await model.refresh(record) } } label: {
                GitHubActionLabel(title: "Refresh", isBusy: model.loading)
            }
            .buttonStyle(.dockCompact).disabled(model.loading || model.busy)
        }
    }

}

struct PullRequestThreadListView: View {
    @ObservedObject var model: PullRequestReviewModel
    let record: PullRequestRecord
    var path: String? = nil
    var unresolvedOnly = false
    @State private var expanded = Set<String>()
    @State private var pendingReply: String?
    @State private var pendingResolve: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(model.threads.filter { (path == nil || $0.path == path) && (!unresolvedOnly || !$0.resolved) }) { thread in
                VStack(alignment: .leading, spacing: 8) {
                    DockSectionHeader(title: thread.path + (thread.line.map { ":\($0)" } ?? ""), isExpanded: Binding(get: { expanded.contains(thread.id) }, set: { if $0 { expanded.insert(thread.id) } else { expanded.remove(thread.id) } }), style: DockThemePalette(theme: DockThemeRuntime.current))
                    Text((thread.resolved ? "Resolved" : "Unresolved") + (thread.outdated ? " · outdated" : "")).foregroundStyle(Color.dockSecondaryText)
                    if expanded.contains(thread.id) {
                        GitHubTimelineView(reference: record.reference, items: thread.comments)
                        if thread.partial { Text("Some comments are unavailable. Open the thread on GitHub.").foregroundStyle(Color.dockWarning) }
                        TextField("Reply", text: Binding(get: { model.replies[thread.id] ?? "" }, set: { model.replies[thread.id] = $0 }), axis: .vertical).textFieldStyle(.dockGlass)
                        HStack {
                            Button { pendingReply = thread.id } label: { GitHubActionLabel(title: model.pendingAction == .reply(thread.id) ? "Posting…" : "Reply", isBusy: model.pendingAction == .reply(thread.id)) }.buttonStyle(.dockCompact).disabled(model.busy || (model.replies[thread.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (model.replies[thread.id] ?? "").count > 10_000)
                            if thread.resolved ? thread.canUnresolve : thread.canResolve {
                                Button { pendingResolve = thread.id } label: { GitHubActionLabel(title: model.pendingAction == .resolve(thread.id) ? "Updating…" : (thread.resolved ? "Unresolve thread" : "Resolve thread"), isBusy: model.pendingAction == .resolve(thread.id)) }.buttonStyle(.dockCompact).disabled(model.busy)
                            }
                            if let url = thread.comments.first?.url { Link("GitHub", destination: url).buttonStyle(.dockLink) }
                        }
                    }
                }.font(DockTypography.body).dockCard(padding: 10)
            }
            if let error = model.error, path != nil { Text(error).foregroundStyle(Color.dockWarning) }
        }
        .task(id: record.headRevision) { if model.revision != record.headRevision { await model.refresh(record) } }
        .confirmationDialog("Post reply to \(record.reference.title)?", isPresented: Binding(get: { pendingReply != nil }, set: { if !$0 { pendingReply = nil } }), titleVisibility: .visible, presenting: pendingReply) { id in
            Button("Post reply") { pendingReply = nil; if let thread = model.threads.first(where: { $0.id == id }) { Task { await model.reply(thread, record: record) } } }
            Button("Cancel", role: .cancel) { pendingReply = nil }
        } message: { id in Text(model.replies[id] ?? "") }
        .confirmationDialog("Change review thread on \(record.reference.title)?", isPresented: Binding(get: { pendingResolve != nil }, set: { if !$0 { pendingResolve = nil } }), titleVisibility: .visible, presenting: pendingResolve) { id in
            Button("Confirm thread change") { pendingResolve = nil; if let thread = model.threads.first(where: { $0.id == id }) { Task { await model.resolve(thread, record: record) } } }
            Button("Cancel", role: .cancel) { pendingResolve = nil }
        }
    }
}

struct GitHubMarkdownDraft: View {
    @Binding var text: String
    var placeholder = "Write a comment…"
    var minimumHeight: CGFloat = 120
    @State private var preview = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                DockTabButton(title: "Write", isSelected: !preview) { preview = false }
                DockTabButton(title: "Preview", isSelected: preview) { preview = true }
                Spacer()
                Text("\(text.count.formatted()) / 10,000")
                    .font(DockTypography.metadata).monospacedDigit()
                    .foregroundStyle(text.count > 10_000 ? Color.dockWarning : Color.dockMetadataText)
            }
            .padding(8)
            Color.dockBorderLight.frame(height: DockLayout.hairline)
            Group {
                if preview {
                    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("Nothing to preview yet.").font(DockTypography.body).foregroundStyle(Color.dockSecondaryText)
                            .padding(12).frame(maxWidth: .infinity, minHeight: minimumHeight, alignment: .topLeading)
                    } else {
                        MarkdownMessageView(markdown: text).padding(12)
                            .frame(maxWidth: .infinity, minHeight: minimumHeight, alignment: .topLeading)
                    }
                } else {
                    TextEditor(text: $text)
                        .font(DockTypography.body).foregroundStyle(Color.dockPrimaryText)
                        .scrollContentBackground(.hidden).padding(8)
                        .frame(minHeight: minimumHeight)
                        .overlay(alignment: .topLeading) {
                            if text.isEmpty {
                                Text(placeholder).font(DockTypography.body).foregroundStyle(Color.dockSecondaryText)
                                    .padding(.horizontal, 13).padding(.vertical, 8)
                                    .allowsHitTesting(false).accessibilityHidden(true)
                            }
                        }
                        .accessibilityLabel("Comment body")
                }
            }
        }
        .background { DockThemeShape(cornerRadius: DockLayout.controlRadius).dockInputFill() }
        .clipShape(DockThemeShape(cornerRadius: DockLayout.controlRadius))
        .overlay { DockThemeShape(cornerRadius: DockLayout.controlRadius).stroke(Color.dockBorder, lineWidth: DockLayout.hairline) }
    }
}

struct GitHubInlineCommentEditor: View {
    @ObservedObject var model: PullRequestReviewModel
    let record: PullRequestRecord
    let target: GitHubInlineCommentTarget
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        let draft = Binding(get: { model.inlineDrafts[target.id] ?? "" }, set: { model.inlineDrafts[target.id] = $0 })
        DockModal(title: "Comment on changed line", subtitle: "\(record.reference.title) · \(target.path):\(target.line)", width: 560) {
            GitHubMarkdownDraft(text: draft)
            if let error = model.error { Text(error).foregroundStyle(Color.dockWarning) }
        } footer: {
            Button("Cancel") { dismiss() }.buttonStyle(.dockSecondary).disabled(model.busy)
            Spacer()
            Button("Save review draft") { if model.stageInline(target, record: record) { dismiss() } }
                .buttonStyle(.dockPrimary).disabled(model.busy || model.uncertainSubmission || draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.wrappedValue.count > 10_000)
        }
        .interactiveDismissDisabled(model.busy)
    }
}
