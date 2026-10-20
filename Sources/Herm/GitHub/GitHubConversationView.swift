import SwiftUI

struct GitHubConversationItem: Identifiable, Equatable, Sendable {
    let id: String
    let author: String
    let summary: String
    let body: String
    let date: Date?
    let url: URL?
    var avatarURL: URL? = nil
}
struct GitHubConversationService: Sendable {
    let client: GitHubClient
    func load(_ reference: GitHubItemReference) async throws -> GitHubPage<GitHubConversationItem> {
        async let commentsLookup = client.pages(reference.issuePath + "/comments")
        async let timelineLookup = try? client.pages(reference.issuePath + "/timeline")
        let comments = try await commentsLookup
        let timeline = await timelineLookup
        var items = comments.rows.compactMap(Self.comment)
        items += (timeline?.rows ?? []).compactMap(Self.event)
        var coverage = comments.coverage
        coverage.partial = coverage.partial || timeline == nil || timeline?.coverage.partial == true
        if timeline == nil { coverage.message = "Some activity is unavailable. Showing loaded comments; refresh to retry." }
        let unique = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return GitHubPage(items: unique.values.sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }, coverage: coverage)
    }
    func post(_ body: String, to reference: GitHubItemReference) async throws -> GitHubConversationItem {
        let value = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 10_000, !value.contains("\0") else { throw GitHubRequestError.malformed }
        guard let row = try await client.request(reference.issuePath + "/comments", method: "POST", body: ["body": value]) as? [String: Any], let item = Self.comment(row) else { throw GitHubRequestError.malformed }
        return item
    }
    static func comment(_ row: [String: Any]) -> GitHubConversationItem? {
        guard let id = row["id"] else { return nil }
        return GitHubConversationItem(id: "comment:\(id)", author: (row["user"] as? [String: Any])?["login"] as? String ?? "Unknown", summary: "commented", body: row["body"] as? String ?? "", date: date(row["created_at"]), url: (row["html_url"] as? String).flatMap(URL.init), avatarURL: ((row["user"] as? [String: Any])?["avatar_url"] as? String).flatMap(URL.init))
    }
    static func event(_ row: [String: Any]) -> GitHubConversationItem? {
        guard let event = row["event"] as? String, event != "commented" else { return nil }
        let author = (row["actor"] as? [String: Any])?["login"] as? String ?? (row["user"] as? [String: Any])?["login"] as? String ?? (row["author"] as? [String: Any])?["name"] as? String ?? "Unknown"
        let label = (row["label"] as? [String: Any])?["name"] as? String ?? ""
        let summary: String
        switch event {
        case "closed": summary = "closed this"
        case "reopened": summary = "reopened this"
        case "assigned": summary = "assigned " + ((row["assignee"] as? [String: Any])?["login"] as? String ?? "")
        case "unassigned": summary = "removed an assignee"
        case "labeled": summary = "added label " + label
        case "unlabeled": summary = "removed label " + label
        case "milestoned": summary = "assigned a milestone"
        case "demilestoned": summary = "removed the milestone"
        case "reviewed": summary = (row["state"] as? String ?? "reviewed").replacingOccurrences(of: "_", with: " ").capitalized
        case "committed": summary = (row["message"] as? String ?? "Committed").components(separatedBy: "\n").first ?? "Committed"
        case "cross-referenced": summary = "referenced this in related work"
        case "merged": summary = "merged this pull request"
        case "ready_for_review": summary = "marked ready for review"
        case "convert_to_draft": summary = "converted to draft"
        case "review_requested": summary = "requested a review"
        default: return nil
        }
        guard let id = row["id"] ?? row["node_id"] ?? row["sha"] else { return nil }
        return GitHubConversationItem(id: "event:\(id)", author: author, summary: summary, body: event == "reviewed" ? row["body"] as? String ?? "" : "", date: date(row["created_at"] ?? row["submitted_at"] ?? row["committed_at"]), url: (row["html_url"] as? String).flatMap(URL.init), avatarURL: (((row["actor"] ?? row["user"] ?? row["author"]) as? [String: Any])?["avatar_url"] as? String).flatMap(URL.init))
    }
    private static func date(_ value: Any?) -> Date? { (value as? String).flatMap { try? Date($0, strategy: .iso8601) } }
}

@MainActor
final class GitHubConversationModel: ObservableObject {
    let reference: GitHubItemReference
    let service: GitHubConversationService
    @Published private(set) var items: [GitHubConversationItem] = []
    @Published private(set) var loading = false
    @Published private(set) var posting = false
    @Published private(set) var error: String?
    @Published private(set) var loaded = false
    @Published var draft = ""
    init(reference: GitHubItemReference, client: GitHubClient) { self.reference = reference; service = GitHubConversationService(client: client) }
    func refresh() async {
        guard !loading else { return }; loading = true; defer { loading = false }
        do {
            let result = try await service.load(reference); try Task.checkCancellation()
            if result.coverage.partial {
                var retained = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
                for item in result.items { retained[item.id] = item }
                items = retained.values.sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
            } else { items = result.items }
            error = result.coverage.label; loaded = true
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
    func post() async -> Bool {
        guard !posting, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, draft.count <= 10_000 else { return false }
        posting = true; defer { posting = false }
        let submitted = draft
        do {
            let item = try await service.post(submitted, to: reference)
            if !items.contains(where: { $0.id == item.id }) { items.append(item) }
            if draft == submitted { draft = "" }; error = nil
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
}

struct GitHubTimelineView: View {
    let reference: GitHubItemReference
    let items: [GitHubConversationItem]
    var body: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        if let avatarURL = item.avatarURL {
                            AsyncImage(url: avatarURL) { phase in
                                if let image = phase.image { image.resizable().scaledToFill() }
                                else {
                                    DockIcon(.user, size: 14, color: Color.dockMetadataText)
                                        .frame(width: 24, height: 24)
                                        .background(Circle().fill(Color.dockSurface2))
                                }
                            }
                            .frame(width: 24, height: 24)
                            .clipShape(Circle())
                            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                            .accessibilityHidden(true)
                        }
                        Text(item.author).fontWeight(.semibold)
                        Text(item.summary).foregroundStyle(Color.dockSecondaryText)
                        Spacer(minLength: 8)
                        if let date = item.date { Text(HumanDateFormatting.relative(date)).font(DockTypography.metadata).foregroundStyle(Color.dockMetadataText) }
                        if let url = item.url { Link("GitHub", destination: url).buttonStyle(.dockLink) }
                    }
                    if !item.body.isEmpty {
                        MarkdownMessageView(markdown: item.body).frame(maxWidth: .infinity, alignment: .leading)
                        AttachToChatMenu { ChatContext(id: reference.id + ":" + item.id, title: reference.title + " · " + item.author, body: "\(reference.title)\n\(item.url?.absoluteString ?? reference.webURL.absoluteString)\n\n" + String(item.body.prefix(12_000))) }
                    }
                }.font(DockTypography.body).foregroundStyle(Color.dockPrimaryText).tint(Color.dockAccent).dockCard(padding: 12)
            }
        }
    }
}

struct GitHubConversationView: View {
    @ObservedObject var model: GitHubConversationModel
    let description: String
    @State private var confirm = false
    @State private var preview = false
    private var style: DockThemePalette { DockThemePalette(theme: DockThemeRuntime.current) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            MarkdownMessageView(markdown: description.isEmpty ? "No description provided." : description).frame(maxWidth: .infinity, alignment: .leading)
            DockSectionHeader(title: "Conversation", count: model.loaded ? model.items.count : nil, style: style) {
                DockIconButton(icon: .arrowsClockwise, label: "Refresh conversation", isBusy: model.loading, size: 24, style: style) { Task { await model.refresh() } }
            }
            if model.loading && !model.loaded { ProgressView("Loading conversation…") }
            if let error = model.error { Text(error).foregroundStyle(Color.dockWarning) }
            if model.loaded && model.items.isEmpty { Text("No discussion yet.").foregroundStyle(Color.dockSecondaryText) }
            GitHubTimelineView(reference: model.reference, items: model.items)
            HStack {
                DockTabButton(title: "Write", isSelected: !preview) { preview = false }
                DockTabButton(title: "Preview", isSelected: preview) { preview = true }
                Spacer(); Text("\(model.draft.count)/10000").font(DockTypography.metadata).foregroundStyle(Color.dockMetadataText)
            }
            if preview { MarkdownMessageView(markdown: model.draft).frame(minHeight: 100, alignment: .topLeading) }
            else { TextEditor(text: $model.draft).font(DockTypography.body).scrollContentBackground(.hidden).padding(8).frame(minHeight: 100).background(DockThemeShape(cornerRadius: DockLayout.controlRadius).dockSurfaceFill(Color.dockControlSurface)) }
            HStack { Spacer(); Button { confirm = true } label: { GitHubActionLabel(title: model.posting ? "Posting…" : "Post comment", isBusy: model.posting) }.buttonStyle(.dockPrimary).controlSize(.small).disabled(model.posting || model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.draft.count > 10_000) }
        }
        .font(DockTypography.body).foregroundStyle(Color.dockPrimaryText)
        .task { if !model.loaded { await model.refresh() } }
        .confirmationDialog("Post comment to \(model.reference.title)?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Post comment") { Task { _ = await model.post() } }
            Button("Cancel", role: .cancel) {}
        } message: { Text(model.draft) }
    }
}
