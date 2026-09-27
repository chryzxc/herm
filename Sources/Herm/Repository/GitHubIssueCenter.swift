import Foundation
import SwiftUI

enum GitHubIssueFilter: String, CaseIterable, Identifiable, Sendable {
    case all = "All"
    case authored = "Authored"
    case assigned = "Assigned"
    var id: Self { self }
}

struct GitHubIssueRecord: Identifiable, Equatable, Sendable {
    let repository: GitHubRepositoryReference
    let localPath: String
    let number: Int
    var title: String
    var body: String
    var state: String
    var author: String
    var assignee: String?
    var assignees: [String]
    var updatedAt: Date?
    var webURL: URL?
    var id: String { "github:\(repository.id)#\(number)" }
    var displayNumber: String { String(number) }

    init(repository: GitHubRepositoryReference, localPath: String, number: Int, title: String, body: String, state: String, author: String, assignee: String?, assignees: [String] = [], updatedAt: Date?, webURL: URL?) {
        self.repository = repository; self.localPath = localPath; self.number = number; self.title = title; self.body = body; self.state = state; self.author = author; self.assignee = assignee
        self.assignees = assignees.isEmpty ? (assignee.map { [$0] } ?? []) : assignees
        self.updatedAt = updatedAt; self.webURL = webURL
    }
}

enum GitHubIssueParser {
    static func parse(_ payload: [String: Any], localPaths: [String: String] = [:]) -> GitHubIssueRecord? {
        guard let number = payload["number"] as? Int,
              number > 0,
              let title = bounded(payload["title"] as? String),
              let state = bounded(payload["state"] as? String),
              let repository = repositoryReference(from: payload) else { return nil }
        let user = payload["user"] as? [String: Any]
        let primaryAssignee = ((payload["assignee"] as? [String: Any])?["login"] as? String).flatMap(bounded)
        let assignees = (payload["assignees"] as? [[String: Any] ])?.compactMap { bounded($0["login"] as? String) } ?? []
        let allAssignees = assignees.isEmpty ? (primaryAssignee.map { [$0] } ?? []) : assignees
        return GitHubIssueRecord(
            repository: repository,
            localPath: localPaths[repository.id] ?? "",
            number: number,
            title: title,
            body: payload["body"] as? String ?? "",
            state: state,
            author: bounded(user?["login"] as? String) ?? "Unknown",
            assignee: primaryAssignee,
            assignees: allAssignees,
            updatedAt: (payload["updated_at"] as? String).flatMap { try? Date($0, strategy: .iso8601) },
            webURL: (payload["html_url"] as? String).flatMap(URL.init)
        )
    }

    private static func repositoryReference(from payload: [String: Any]) -> GitHubRepositoryReference? {
        let fullName = ((payload["repository"] as? [String: Any])?["full_name"] as? String)
            ?? (payload["repository_url"] as? String).flatMap { URL(string: $0)?.pathComponents.dropFirst().dropFirst().joined(separator: "/") }
        guard let fullName else { return nil }
        let parts = fullName.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count == 2 else { return nil }
        let owner = String(parts[0]); let name = String(parts[1])
        guard let webURL = URL(string: "https://github.com/\(owner)/\(name)") else { return nil }
        return GitHubRepositoryReference(owner: owner, name: name, webURL: webURL)
    }

    private static func bounded(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 240, trimmed.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        return trimmed
    }
}

struct IssueContext: Equatable, Sendable {
    let repositoryID: String
    let number: Int
    let title: String
    let webURL: URL?
    var id: String { "github:\(repositoryID)#\(number)" }
    var prompt: String {
        """
        Issue #\(number), "\(title)", in \(repositoryID).
        Issue: \(webURL?.absoluteString ?? "Unavailable")

        Review the issue context and propose next steps. Do not modify files unless I ask.
        """
    }

    init(issue: GitHubIssueRecord) {
        repositoryID = issue.repository.id; number = issue.number; title = issue.title; webURL = issue.webURL
    }

    init(repositoryID: String, number: Int, title: String, webURL: URL?) {
        self.repositoryID = repositoryID; self.number = number; self.title = title; self.webURL = webURL
    }
}

protocol GitHubIssueTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: GitHubIssueTransport {}

struct GitHubIssueCenterAPI: Sendable {
    private let transport: any GitHubIssueTransport

    init(transport: any GitHubIssueTransport = URLSession(configuration: .ephemeral)) { self.transport = transport }

    func viewer() async -> Result<String, PullRequestCenterFailure> {
        do {
            guard let row = try await request(path: "/user") as? [String: Any],
                  let login = row["login"] as? String,
                  !login.isEmpty else { throw GitHubCodeHostError.malformedResponse }
            return .success(login)
        } catch {
            return .failure(PullRequestCenterFailure(repository: "GitHub account"))
        }
    }

    func searchIssues(viewerLogin: String?, localPaths: [String: String]) async -> Result<[GitHubIssueRecord], PullRequestCenterFailure> {
        do {
            // The All view is intentionally scoped to the signed-in user's
            // authored and assigned issues. Never fall back to a global open
            // issue search, which can expose unrelated repository activity.
            guard let viewerLogin = viewerLogin?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !viewerLogin.isEmpty else {
                return .failure(PullRequestCenterFailure(repository: "GitHub issue search"))
            }
            let queries = [
                "is:issue is:open author:\(viewerLogin)",
                "is:issue is:open assignee:\(viewerLogin)"
            ]
            var unique: [String: GitHubIssueRecord] = [:]
            for query in queries {
                let payload = try await request(path: "/search/issues", query: ["q": query, "per_page": "100"])
                guard let items = (payload as? [String: Any])?["items"] as? [[String: Any]] else { throw GitHubCodeHostError.malformedResponse }
                for item in items {
                    if let issue = GitHubIssueParser.parse(item, localPaths: localPaths) { unique[issue.id] = issue }
                }
            }
            return .success(Array(unique.values))
        } catch { return .failure(PullRequestCenterFailure(repository: "GitHub issue search")) }
    }

    func detail(_ issue: GitHubIssueRecord) async -> GitHubIssueRecord? {
        guard let payload = try? await request(path: issue.repository.apiRepositoryPath + "/issues/\(issue.number)") as? [String: Any] else { return nil }
        return GitHubIssueParser.parse(payload, localPaths: [issue.repository.id: issue.localPath])
    }

    private func request(path: String, query: [String: String] = [:]) async throws -> Any {
        var components = URLComponents(string: "https://api.github.com\(path)")!
        components.queryItems = query.map(URLQueryItem.init)
        var request = URLRequest(url: components.url!); request.timeoutInterval = GitHubCodeHostService.requestTimeout
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let token = await GitHubCodeHostService.localGitHubToken() { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await transport.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw GitHubCodeHostError.unavailable }
        return try JSONSerialization.jsonObject(with: data)
    }
}

@MainActor
final class IssueCenterModel: ObservableObject {
    private let api: GitHubIssueCenterAPI
    private let repositoryRemote: @Sendable (String) async -> GitHubRepositoryReference?
    @Published var records: [GitHubIssueRecord] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var hasLoaded = false
    @Published var viewerLogin: String?
    @Published var selectedIssueID: String? {
        didSet {
            if oldValue != selectedIssueID { detailErrorMessage = nil }
        }
    }
    @Published private(set) var detailByID: [String: GitHubIssueRecord] = [:]
    @Published private(set) var loadingDetailID: String?
    @Published private(set) var detailErrorMessage: String?
    @Published var filter: GitHubIssueFilter = .all
    @Published var query = ""
    @Published var repositoryScope: String?
    private var generation = UUID()

    init(
        api: GitHubIssueCenterAPI = GitHubIssueCenterAPI(),
        repositoryRemote: @escaping @Sendable (String) async -> GitHubRepositoryReference? = { path in
            await RepositoryService.githubRemote(path: path)
        }
    ) {
        self.api = api
        self.repositoryRemote = repositoryRemote
    }

    var selected: GitHubIssueRecord? { records.first { $0.id == selectedIssueID } }
    var hasActiveFilters: Bool {
        filter != .all || !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || repositoryScope != nil
    }
    var visible: [GitHubIssueRecord] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return records.filter { matches($0, filter: filter, needle: needle) }.sorted { lhs, rhs in
            let left = lhs.updatedAt ?? .distantPast
            let right = rhs.updatedAt ?? .distantPast
            if left != right { return left > right }
            return lhs.id < rhs.id
        }
    }

    /// Visible issues grouped by repository, ordered by each group's most
    /// recently updated issue.
    var visibleGroups: [(repository: String, issues: [GitHubIssueRecord])] {
        var order: [String] = []
        var groups: [String: [GitHubIssueRecord]] = [:]
        for issue in visible {
            if groups[issue.repository.id] == nil { order.append(issue.repository.id) }
            groups[issue.repository.id, default: []].append(issue)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }

    func count(for filter: GitHubIssueFilter) -> Int {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return records.filter { matches($0, filter: filter, needle: needle) }.count
    }

    private func matches(_ issue: GitHubIssueRecord, filter: GitHubIssueFilter, needle: String) -> Bool {
        guard repositoryScope == nil || repositoryScope == issue.repository.id else { return false }
        let matchesFilter: Bool
        switch filter {
        case .all: matchesFilter = true
        case .authored: matchesFilter = viewerLogin.map { issue.author.caseInsensitiveCompare($0) == .orderedSame } ?? false
        case .assigned: matchesFilter = viewerLogin.map { viewer in issue.assignees.contains { assignee in assignee.caseInsensitiveCompare(viewer) == .orderedSame } } ?? false
        }
        guard matchesFilter else { return false }
        guard !needle.isEmpty else { return true }
        return [issue.title, issue.repository.id, issue.author, issue.assignee ?? "", "#\(issue.number)"].joined(separator: " ").lowercased().contains(needle)
    }

    func refresh(projects: [ProjectSummary]) async {
        let token = UUID(); generation = token; isRefreshing = true; errorMessage = nil
        let paths = Array(Set(projects.filter(\.isRenderableProject).map(\.name))).filter { !$0.isEmpty }
        let remotes = await withTaskGroup(of: (String, GitHubRepositoryReference?).self, returning: [String: String].self) { group in
            for path in paths { group.addTask { (path, await self.repositoryRemote(path)) } }
            var output: [String: String] = [:]
            for await (path, remote) in group { if let remote { output[remote.id] = path } }
            return output
        }
        let viewerResult = await api.viewer()
        guard token == generation else { return }
        guard case .success(let viewer) = viewerResult else {
            viewerLogin = nil
            errorMessage = hasLoaded ? "Using last known GitHub issues. Refresh to retry." : "GitHub issues are unavailable. Check your sign-in or try again."
            isRefreshing = false
            repairSelection()
            return
        }
        viewerLogin = viewer
        let result = await api.searchIssues(viewerLogin: viewer, localPaths: remotes)
        guard token == generation else { return }
        switch result {
        case .success(let issues): records = issues.sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }; hasLoaded = true; errorMessage = nil
        case .failure: errorMessage = hasLoaded ? "Using last known GitHub issues. Refresh to retry." : "GitHub issues are unavailable. Check your sign-in or try again."
        }
        isRefreshing = false; repairSelection()
    }

    func loadSelectedDetail() async {
        guard let issue = selected, detailByID[issue.id] == nil else { return }
        loadingDetailID = issue.id
        detailErrorMessage = nil
        defer {
            if loadingDetailID == issue.id { loadingDetailID = nil }
        }
        let detail = await api.detail(issue)
        guard !Task.isCancelled, selectedIssueID == issue.id else { return }
        if let detail {
            detailByID[issue.id] = detail
        } else {
            detailErrorMessage = "Could not refresh full issue details. Showing the latest available summary."
        }
    }

    func resetFilters() {
        filter = .all
        query = ""
        repositoryScope = nil
        repairSelection()
    }

    func repairSelection() { if !visible.contains(where: { $0.id == selectedIssueID }) { selectedIssueID = visible.first?.id } }
}

struct GitHubIssueRowMetadata: Equatable {
    let repository: String
    let assignment: String
    let updated: String?

    var values: [String] {
        [repository, assignment, updated]
            .compactMap { value in
                guard let value else { return nil }
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
    }

    static func make(repository: String, assignees: [String], updated: String?, viewer: String? = nil) -> Self {
        let names = assignees
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { name in viewer.map { name.caseInsensitiveCompare($0) == .orderedSame } == true ? "you" : name }
        let assignment = names.isEmpty ? "Unassigned" : "Assigned to \(names.joined(separator: ", "))"
        return Self(repository: repository, assignment: assignment, updated: updated)
    }
}

struct IssueRowView: View {
    let issue: GitHubIssueRecord
    let isSelected: Bool
    var viewer: String?
    @State private var isHovered = false

    var body: some View {
        let metadata = GitHubIssueRowMetadata.make(
            repository: issue.repository.id,
            assignees: issue.assignees,
            updated: issue.updatedAt.map { HumanDateFormatting.relative($0) },
            viewer: viewer
        )
        HStack(alignment: .top, spacing: 10) {
            DockIcon(.record, size: 14, color: issue.isOpen ? DockStatusTone.complete.color : Color.dockMetadataText)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 5) {
                Text(issue.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isSelected ? Color.dockPrimaryText : Color.dockPrimaryText.opacity(0.9))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 5) {
                    Text("#\(issue.displayNumber)")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                    Text("·")
                    Text(metadata.assignment)
                    if let updated = metadata.updated {
                        Text("·")
                        Text(updated)
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(Color.dockMetadataText)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.dockAccent.opacity(0.12) : (isHovered ? Color.dockSurface4.opacity(0.45) : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.dockAccent.opacity(isSelected ? 0.35 : 0), lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}

extension GitHubIssueRecord {
    var isOpen: Bool { state.caseInsensitiveCompare("open") == .orderedSame }
}

struct IssueDetailView: View {
    @ObservedObject var center: IssueCenterModel
    let onOpenChat: (GitHubIssueRecord) -> Void

    var body: some View {
        Group {
            if let issue = center.selected {
                Group {
                    if shouldShowLoadingState(for: issue) {
                        detailLoadingPane
                    } else {
                        issueContent(issue)
                    }
                }
                .task(id: issue.id) { await center.loadSelectedDetail() }
            } else {
                VStack(spacing: 10) {
                    DockIcon(.fileText, size: 28, color: Color.dockMetadataText)
                    Text(center.isRefreshing ? "Loading issues…" : "Select an issue")
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.dockMetadataText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.dockCanvas)
    }

    private func shouldShowLoadingState(for issue: GitHubIssueRecord) -> Bool {
        center.detailByID[issue.id] == nil && center.detailErrorMessage == nil
    }

    private var detailLoadingPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                RepositoryShimmerBlock(width: 188, height: 11, cornerRadius: 4)
                Spacer(minLength: 12)
                RepositoryShimmerBlock(width: 76, height: 26, cornerRadius: 7)
                RepositoryShimmerBlock(width: 104, height: 28, cornerRadius: 7)
            }
            .padding(.horizontal, 24)
            .frame(height: 52)
            .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading issue")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.dockMetadataText)
                    }
                    .padding(.top, 28)

                    RepositoryShimmerBlock(width: nil, height: 26, cornerRadius: 7)
                        .padding(.top, 14)
                    RepositoryShimmerBlock(width: 420, height: 26, cornerRadius: 7)
                        .padding(.top, 8)

                    HStack(spacing: 10) {
                        RepositoryShimmerBlock(width: 64, height: 22, cornerRadius: 11)
                        RepositoryShimmerBlock(width: 248, height: 11, cornerRadius: 4)
                    }
                    .padding(.top, 16)
                    .padding(.bottom, 22)

                    RepositoryShimmerBlock(width: nil, height: 1, cornerRadius: 0)

                    VStack(alignment: .leading, spacing: 9) {
                        RepositoryShimmerBlock(width: nil, height: 11, cornerRadius: 4)
                        RepositoryShimmerBlock(width: nil, height: 11, cornerRadius: 4)
                        RepositoryShimmerBlock(width: 520, height: 11, cornerRadius: 4)
                        RepositoryShimmerBlock(width: 370, height: 11, cornerRadius: 4)
                    }
                    .padding(.top, 24)
                    .padding(.bottom, 48)
                }
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading issue")
    }

    @ViewBuilder
    private func issueContent(_ issue: GitHubIssueRecord) -> some View {
        let displayedIssue = center.detailByID[issue.id] ?? issue
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    DockIcon(.folder, size: 12, color: Color.dockMetadataText)
                    Text(displayedIssue.repository.id)
                        .foregroundStyle(Color.dockSecondaryText)
                        .truncationMode(.middle)
                    Text("/").foregroundStyle(Color.dockMetadataText)
                    Text("#\(displayedIssue.number)").foregroundStyle(Color.dockAccent)
                }
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .lineLimit(1)
                Spacer(minLength: 12)
                if center.loadingDetailID == issue.id {
                    ProgressView().controlSize(.small)
                }
                if let url = displayedIssue.webURL {
                    GitHubLinkButton(
                        destination: url,
                        accessibilityLabel: "Open issue on GitHub"
                    )
                }
                Button { onOpenChat(displayedIssue) } label: {
                    HStack(spacing: 5) {
                        DockIcon(.notePencil, size: 12, color: Color.dockOnAccentText)
                        Text("Open in chat")
                    }
                }
                .buttonStyle(.dockPrimary)
                .controlSize(.small)
            }
            .padding(.horizontal, 24)
            .frame(height: 52)
            .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }

            if let error = center.detailErrorMessage {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dockWarning)
                    .padding(.horizontal, 24)
                    .padding(.top, 10)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(displayedIssue.title)
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(Color.dockPrimaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 28)

                    issueMetadata(displayedIssue)
                        .padding(.top, 14)
                        .padding(.bottom, 22)

                    Color.dockBorderLight.frame(height: 0.5)

                    MarkdownMessageView(markdown: displayedIssue.body.isEmpty ? "No description provided." : displayedIssue.body)
                        .frame(maxWidth: 760, alignment: .leading)
                        .padding(.top, 24)
                        .padding(.bottom, 48)
                }
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28)
            }
        }
    }

    private func issueMetadata(_ issue: GitHubIssueRecord) -> some View {
        let metadata = GitHubIssueRowMetadata.make(
            repository: issue.repository.id,
            assignees: issue.assignees,
            updated: issue.updatedAt.map { "updated " + HumanDateFormatting.relative($0) },
            viewer: center.viewerLogin
        )
        return HStack(spacing: 10) {
            DockStatusPill(tone: issue.isOpen ? .complete : .inactive, text: issue.state.capitalized)
            HStack(spacing: 5) {
                Text(issue.author).fontWeight(.medium).foregroundStyle(Color.dockSecondaryText)
                Text("opened this")
                Text("·")
                Text(metadata.assignment)
                if let updated = metadata.updated {
                    Text("·")
                    Text(updated)
                }
            }
            .lineLimit(1)
        }
        .font(.system(size: 12))
        .foregroundStyle(Color.dockMetadataText)
    }
}

struct IssueWorkspace: View {
    @ObservedObject var center: IssueCenterModel
    let projects: [ProjectSummary]
    let onOpenChat: (GitHubIssueRecord) -> Void
    @State private var collapsedRepositories: Set<String> = []

    var body: some View {
        HSplitView {
            listPane.frame(minWidth: 340, idealWidth: 390, maxWidth: 460, maxHeight: .infinity)
            IssueDetailView(center: center, onOpenChat: onOpenChat)
                .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.dockCanvas)
        .task { if center.records.isEmpty { await center.refresh(projects: projects) } }
        .onChange(of: center.filter) { _, _ in center.repairSelection() }
        .onChange(of: center.query) { _, _ in center.repairSelection() }
        .onChange(of: center.repositoryScope) { _, _ in center.repairSelection() }
    }

    private var listPane: some View {
        VStack(spacing: 0) {
            issueToolbar
            ScrollView {
                LazyVStack(spacing: 2) {
                    if center.isRefreshing && center.records.isEmpty {
                        ForEach(0..<6, id: \.self) { _ in issueLoadingRow }
                    } else if !center.hasLoaded && center.errorMessage != nil {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Issues unavailable").font(.system(size: 12, weight: .semibold))
                            Text("Check your GitHub sign-in and try again.").font(.system(size: 12)).foregroundStyle(Color.dockMetadataText)
                            Button("Try again") { refresh() }.buttonStyle(.borderless).foregroundStyle(Color.dockAccent)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
                    } else if center.visible.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(center.hasActiveFilters ? "No issues match this view" : "No open issues")
                                .font(.system(size: 12, weight: .semibold))
                            Text(center.hasActiveFilters ? "Try another filter or search term." : "Issues from your repositories will appear here.")
                                .font(.system(size: 12)).foregroundStyle(Color.dockMetadataText)
                            if center.hasActiveFilters {
                                Button("Clear filters") { center.resetFilters() }
                                    .buttonStyle(.borderless)
                                    .foregroundStyle(Color.dockAccent)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
                    } else {
                        ForEach(center.visibleGroups, id: \.repository) { group in
                            DockSectionHeader(
                                title: group.repository,
                                count: group.issues.count,
                                isExpanded: expansion(for: group.repository),
                                style: DockThemePalette(theme: DockThemeRuntime.current)
                            )
                            .padding(.top, 6)
                            if !collapsedRepositories.contains(group.repository) {
                                ForEach(group.issues) { issue in
                                    Button { center.selectedIssueID = issue.id } label: {
                                        IssueRowView(issue: issue, isSelected: center.selectedIssueID == issue.id, viewer: center.viewerLogin)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }.padding(.horizontal, 8).padding(.vertical, 6)
            }
        }
        .background(Color.dockSurface2.opacity(0.55))
    }

    private var issueToolbar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                DockIcon(.magnifyingGlass, size: 15, color: Color.dockMetadataText)
                TextField("Search issues", text: $center.query)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 34)
            .background(Color.dockControlSurface)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            HStack(spacing: 4) {
                ForEach(GitHubIssueFilter.allCases) { filter in
                    DockTabButton(title: center.hasLoaded ? "\(filter.rawValue)  \(center.count(for: filter))" : filter.rawValue, isSelected: center.filter == filter) {
                        center.filter = filter
                    }
                }
                Spacer(minLength: 8)
                Menu {
                    Button("All repositories") { center.repositoryScope = nil }
                    ForEach(Array(Set(center.records.map(\.repository.id))).sorted(), id: \.self) { repository in
                        Button(repository) { center.repositoryScope = repository }
                    }
                } label: {
                    HStack(spacing: 4) {
                        DockIcon(.folder, size: 12, color: Color.dockSecondaryText)
                        Text(center.repositoryScope ?? "All repositories")
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        DockIcon(.caretDown, size: 9, color: Color.dockMetadataText)
                    }
                    .foregroundStyle(Color.dockSecondaryText)
                    .frame(minHeight: 30)
                }
                .menuStyle(.borderlessButton)
            }

            if let error = center.errorMessage {
                HStack(spacing: 6) {
                    DockIcon(.warning, size: 12, color: Color.dockWarning)
                    Text(error).foregroundStyle(Color.dockWarning)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 10))
                .lineLimit(1)
                .frame(height: 18, alignment: .leading)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.dockCanvas)
        .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }
    }

    private var issueLoadingRow: some View {
        VStack(alignment: .leading, spacing: 7) {
            RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.dockSurface4.opacity(0.6)).frame(height: 13)
            RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.dockSurface4.opacity(0.35)).frame(width: 190, height: 10)
        }
        .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
        .padding(.horizontal, 14)
    }

    private func expansion(for repository: String) -> Binding<Bool> {
        Binding(
            get: { !collapsedRepositories.contains(repository) },
            set: { expanded in
                if expanded { collapsedRepositories.remove(repository) } else { collapsedRepositories.insert(repository) }
            }
        )
    }

    private func refresh() {
        Task { await center.refresh(projects: projects) }
    }
}
