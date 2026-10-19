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
    func submit(_ event: GitHubReviewEvent, body: String, on record: PullRequestRecord) async throws {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard body.count <= 10_000, event == .approve || !trimmed.isEmpty else { throw GitHubRequestError.malformed }
        try await verifyHead(record)
        _ = try await client.request(record.repository.apiRepositoryPath + "/pulls/\(record.number)/reviews", method: "POST", body: ["event": event.rawValue, "body": trimmed, "commit_id": record.headRevision!])
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
        guard !busy else { return false }; pendingAction = .submit; defer { pendingAction = nil }; let submitted = draft
        do { try await service.submit(event, body: submitted, on: record); if draft == submitted { draft = "" }; error = nil; await refresh(record, force: true); return true }
        catch { self.error = error.localizedDescription; return false }
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
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Review threads").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Toggle("Unresolved only", isOn: $unresolvedOnly).toggleStyle(.dockSwitch)
                    Button { Task { await model.refresh(record) } } label: { GitHubActionLabel(title: "Refresh", isBusy: model.loading) }.buttonStyle(.dockCompact).disabled(model.loading || model.busy)
                }

                if let error = model.error { Text(error).foregroundStyle(Color.dockWarning) }
                if model.revision != nil, model.threads.filter({ !unresolvedOnly || !$0.resolved }).isEmpty { Text(unresolvedOnly ? "No unresolved threads." : "No review threads.").foregroundStyle(Color.dockSecondaryText) }
                PullRequestThreadListView(model: model, record: record, path: nil, unresolvedOnly: unresolvedOnly)
                DockSectionHeader(title: "Submit review", style: DockThemePalette(theme: DockThemeRuntime.current))
                Picker("Review", selection: $model.event) { ForEach(GitHubReviewEvent.allCases) { event in Text(event.title).tag(event) } }.pickerStyle(.menu)
                GitHubMarkdownDraft(text: $model.draft)
                Button { confirm = true } label: { GitHubActionLabel(title: model.pendingAction == .submit ? "Submitting…" : "Review and submit", isBusy: model.pendingAction == .submit) }.buttonStyle(.dockPrimary).controlSize(.small)
                    .disabled(model.busy || viewer == nil || record.state != "open" || record.headRevision == nil || model.draft.count > 10_000 || (model.event != .approve && model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) || (model.event != .comment && viewer?.caseInsensitiveCompare(record.author) == .orderedSame))
            }.padding(16)
        }
        .font(DockTypography.body).foregroundStyle(Color.dockPrimaryText)
        .task(id: record.headRevision) { if model.revision != record.headRevision { await model.refresh(record) } }
        .confirmationDialog("\(model.event.title) on \(record.reference.title)?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Submit review") { Task { if await model.submit(record) { onChanged() } } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Revision \(record.headRevision ?? "unknown")\n\n\(model.draft)") }
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
    @State private var preview = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                DockTabButton(title: "Write", isSelected: !preview) { preview = false }
                DockTabButton(title: "Preview", isSelected: preview) { preview = true }
                Spacer(); Text("\(text.count)/10000").font(DockTypography.metadata).foregroundStyle(Color.dockMetadataText)
            }
            if preview { MarkdownMessageView(markdown: text).frame(minHeight: 100, alignment: .topLeading) }
            else { TextEditor(text: $text).font(DockTypography.body).scrollContentBackground(.hidden).padding(8).frame(minHeight: 120).background(Color.dockControlSurface, in: DockThemeShape(cornerRadius: DockLayout.controlRadius)) }
        }
    }
}

struct GitHubInlineCommentEditor: View {
    @ObservedObject var model: PullRequestReviewModel
    let record: PullRequestRecord
    let target: GitHubInlineCommentTarget
    @Environment(\.dismiss) private var dismiss
    @State private var confirm = false
    var body: some View {
        let draft = Binding(get: { model.inlineDrafts[target.id] ?? "" }, set: { model.inlineDrafts[target.id] = $0 })
        DockModal(title: "Comment on changed line", subtitle: "\(record.reference.title) · \(target.path):\(target.line)", width: 560) {
            GitHubMarkdownDraft(text: draft)
            if let error = model.error { Text(error).foregroundStyle(Color.dockWarning) }
        } footer: {
            Button("Cancel") { dismiss() }.buttonStyle(.dockSecondary).disabled(model.busy)
            Spacer()
            Button { confirm = true } label: { GitHubActionLabel(title: model.pendingAction == .inline(target.id) ? "Posting…" : "Post comment", isBusy: model.pendingAction == .inline(target.id)) }.buttonStyle(.dockPrimary).disabled(model.busy || draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.wrappedValue.count > 10_000)
        }
        .interactiveDismissDisabled(model.busy)
        .confirmationDialog("Post inline comment to \(record.reference.title)?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Post comment") { Task { if await model.postInline(target, record: record) { dismiss() } } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("\(target.path):\(target.line) · \(target.side)\nRevision \(target.revision)\n\n\(draft.wrappedValue)") }
    }
}
