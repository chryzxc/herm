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
            var queries = ["is:issue is:open"]
            if let viewerLogin, !viewerLogin.isEmpty {
                queries += ["is:issue is:open author:\(viewerLogin)", "is:issue is:open assignee:\(viewerLogin)"]
            }
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
        if let token = GitHubCodeHostService.localGitHubToken() { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await transport.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw GitHubCodeHostError.unavailable }
        return try JSONSerialization.jsonObject(with: data)
    }
}

@MainActor
final class IssueCenterModel: ObservableObject {
    private let api: GitHubIssueCenterAPI
    @Published var records: [GitHubIssueRecord] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var hasLoaded = false
    @Published var viewerLogin: String?
    @Published var selectedIssueID: String?
    @Published private(set) var detailByID: [String: GitHubIssueRecord] = [:]
    @Published var filter: GitHubIssueFilter = .all
    @Published var query = ""
    @Published var repositoryScope: String?
    private var generation = UUID()

    init(api: GitHubIssueCenterAPI = GitHubIssueCenterAPI()) { self.api = api }

    var selected: GitHubIssueRecord? { records.first { $0.id == selectedIssueID } }
    var visible: [GitHubIssueRecord] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return records.filter { issue in
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
    }

    func refresh(projects: [ProjectSummary]) async {
        let paths = Array(Set(projects.filter(\.isRenderableProject).map(\.name))).filter { !$0.isEmpty }
        let remotes = await withTaskGroup(of: (String, GitHubRepositoryReference?).self, returning: [String: String].self) { group in
            for path in paths { group.addTask { (path, await RepositoryService.githubRemote(path: path)) } }
            var output: [String: String] = [:]
            for await (path, remote) in group { if let remote { output[remote.id] = path } }
            return output
        }
        let token = UUID(); generation = token; isRefreshing = true; errorMessage = nil
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
        if let detail = await api.detail(issue) { detailByID[issue.id] = detail }
    }

    func repairSelection() { if !visible.contains(where: { $0.id == selectedIssueID }) { selectedIssueID = visible.first?.id } }
}

struct IssueRowView: View {
    let issue: GitHubIssueRecord
    let isSelected: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("#\(issue.displayNumber)  \(issue.title)").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.dockPrimaryText).lineLimit(2)
            Text("\(issue.repository.id) · \(issue.author)").font(.system(size: 11)).foregroundStyle(Color.dockMetadataText).lineLimit(1)
            Text(issue.assignee.map { "ASSIGNED TO \($0)" } ?? "UNASSIGNED").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(issue.assignee == nil ? Color.dockMetadataText : Color.dockAccent)
        }
        .padding(.horizontal, 12).padding(.vertical, 11).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(isSelected ? Color.dockAccent.opacity(0.16) : Color.clear))
        .contentShape(Rectangle())
    }
}

struct IssueDetailView: View {
    @ObservedObject var center: IssueCenterModel
    let onOpenChat: (GitHubIssueRecord) -> Void
    var body: some View {
        Group {
            if let issue = center.selected {
                let displayedIssue = center.detailByID[issue.id] ?? issue
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("#\(displayedIssue.number)").font(.system(size: 16, weight: .semibold, design: .monospaced)).foregroundStyle(Color.dockAccent)
                        Text(displayedIssue.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Color.dockPrimaryText).lineLimit(2)
                        Spacer()
                        Button("Open chat") { onOpenChat(displayedIssue) }.buttonStyle(.borderless).foregroundStyle(Color.dockAccent)
                        if let url = displayedIssue.webURL { Link("Open on GitHub", destination: url).font(.system(size: 11)).foregroundStyle(Color.dockAccent) }
                    }.padding(20).overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }
                    ScrollView { MarkdownMessageView(markdown: displayedIssue.body.isEmpty ? "No description provided." : displayedIssue.body).frame(maxWidth: .infinity, alignment: .leading).padding(24) }
                }.task(id: issue.id) { await center.loadSelectedDetail() }
            } else {
                VStack(spacing: 10) { LucideIcon(name: .fileText, size: 28); Text(center.isRefreshing ? "Loading issues…" : "Select an issue") }.foregroundStyle(Color.dockMetadataText).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.dockCanvas)
    }
}

struct IssueWorkspace: View {
    @ObservedObject var center: IssueCenterModel
    let projects: [ProjectSummary]
    let onOpenChat: (GitHubIssueRecord) -> Void

    var body: some View {
        HSplitView {
            listPane.frame(minWidth: 300, idealWidth: 390, maxWidth: 460, maxHeight: .infinity)
            IssueDetailView(center: center, onOpenChat: onOpenChat)
                .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.dockCanvas)
        .task { if center.records.isEmpty { await center.refresh(projects: projects) } }
        .onChange(of: center.filter) { _, _ in center.repairSelection() }
        .onChange(of: center.query) { _, _ in center.repairSelection() }
    }

    private var listPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                HStack(spacing: 3) {
                    ForEach(GitHubIssueFilter.allCases) { filter in
                        PullRequestFilterTabButton(title: filter.rawValue, isSelected: center.filter == filter) { center.filter = filter }
                    }
                }
                Divider().frame(height: 22)
                HStack(spacing: 8) {
                    LucideIcon(name: .search, size: 16)
                    TextField("Search issues", text: $center.query).textFieldStyle(.plain)
                }
                .padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: 34)
                .background(Color.dockCanvas.opacity(0.55)).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                Menu {
                    Button("All repositories") { center.repositoryScope = nil }
                    ForEach(Array(Set(center.records.map(\.repository.id))).sorted(), id: \.self) { repository in
                        Button(repository) { center.repositoryScope = repository }
                    }
                } label: {
                    Text(center.repositoryScope ?? "Repositories")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.dockSecondaryText)
                        .lineLimit(1)
                }
                .menuStyle(.borderlessButton)
            }
            .padding(.horizontal, 18).padding(.vertical, 11).background(Color.dockSurface2.opacity(0.45))
            if let error = center.errorMessage {
                Text(error).font(.system(size: 11)).foregroundStyle(Color.dockWarning).padding(.horizontal, 18).padding(.bottom, 8)
            }
            ScrollView {
                LazyVStack(spacing: 2) {
                    if center.isRefreshing && center.records.isEmpty {
                        VStack(spacing: 12) { ProgressView().controlSize(.small); Text("Loading issues…").font(.system(size: 12)) }
                            .foregroundStyle(Color.dockMetadataText).frame(maxWidth: .infinity).padding(.vertical, 32)
                    } else if !center.hasLoaded && center.errorMessage != nil {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Issues unavailable").font(.system(size: 12, weight: .semibold))
                            Text("Check your GitHub sign-in and try again.").font(.system(size: 12)).foregroundStyle(Color.dockMetadataText)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
                    } else if center.visible.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("No issues match this view").font(.system(size: 12, weight: .semibold))
                            Text("Try another filter or search term.").font(.system(size: 12)).foregroundStyle(Color.dockMetadataText)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
                    } else {
                        ForEach(center.visible) { issue in
                            Button { center.selectedIssueID = issue.id } label: { IssueRowView(issue: issue, isSelected: center.selectedIssueID == issue.id) }.buttonStyle(.plain)
                        }
                    }
                }.padding(.horizontal, 10).padding(.vertical, 6)
            }
        }.background(Color.dockSurface2.opacity(0.55))
    }
}
