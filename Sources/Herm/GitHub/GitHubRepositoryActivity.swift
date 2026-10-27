import SwiftUI

enum GitHubActivityType: String, CaseIterable, Identifiable, Sendable {
    case all = ""
    case push
    case forcePush = "force_push"
    case branchCreation = "branch_creation"
    case branchDeletion = "branch_deletion"
    case merge = "pr_merge"
    case mergeQueue = "merge_queue_merge"
    var id: Self { self }
    var title: String {
        switch self {
        case .all: "All activity"
        case .push: "Pushes"
        case .forcePush: "Force pushes"
        case .branchCreation: "Branch creation"
        case .branchDeletion: "Branch deletion"
        case .merge: "Pull request merges"
        case .mergeQueue: "Merge queue merges"
        }
    }
}

enum GitHubActivityPeriod: String, CaseIterable, Identifiable, Sendable {
    case all = ""
    case day, week, month, quarter, year
    var id: Self { self }
    var title: String {
        switch self {
        case .all: "All time"
        case .day: "Past 24 hours"
        case .week: "Past week"
        case .month: "Past month"
        case .quarter: "Past quarter"
        case .year: "Past year"
        }
    }
}

struct GitHubActivityFilters: Equatable, Hashable, Sendable {
    var branch = ""
    var actor = ""
    var type: GitHubActivityType = .all
    var period: GitHubActivityPeriod = .all
    var oldestFirst = false
    var query: [String: String] {
        var result = ["per_page": "30", "direction": oldestFirst ? "asc" : "desc"]
        for (key, value) in [
            ("ref", branch), ("actor", actor), ("activity_type", type.rawValue), ("time_period", period.rawValue),
        ] where !value.isEmpty {
            result[key] = value
        }
        return result
    }
}

struct GitHubRepositoryActivity: Identifiable, Equatable, Sendable {
    let id: Int
    let before: String
    let after: String
    let ref: String
    let date: Date
    let type: String
    let actor: String?
    let avatarURL: URL?
    var branch: String { ref.hasPrefix("refs/heads/") ? String(ref.dropFirst(11)) : ref }
    var hasAfter: Bool { after.contains { $0 != "0" } }
    var hasBefore: Bool { before.contains { $0 != "0" } }
    var label: String {
        switch type {
        case "push": "Push"
        case "force_push": "Force push"
        case "branch_creation": "Branch creation"
        case "branch_deletion": "Branch deletion"
        case "pr_merge": "Pull request merge"
        case "merge_queue_merge": "Merge queue merge"
        default: type.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
    var action: String {
        switch type {
        case "branch_creation": "created"
        case "branch_deletion": "deleted"
        case "force_push": "force pushed to"
        case "push", "pr_merge", "merge_queue_merge": "pushed to"
        default: "reported \(label.lowercased()) on"
        }
    }
    func webURL(in repository: GitHubRepositoryReference) -> URL {
        if hasBefore && hasAfter { return repository.webURL.appendingPathComponent("compare/\(before)...\(after)") }
        return repository.webURL.appendingPathComponent("commit/\(hasAfter ? after : before)")
    }
    static func validSHA(_ value: String) -> Bool {
        [40, 64].contains(value.count) && value.allSatisfy { "0123456789abcdefABCDEF".contains($0) }
    }
    static func parse(_ row: [String: Any]) throws -> Self {
        guard let id = row["id"] as? Int, id > 0,
            let before = row["before"] as? String, validSHA(before),
            let after = row["after"] as? String, validSHA(after),
            before.contains(where: { $0 != "0" }) || after.contains(where: { $0 != "0" }),
            let ref = row["ref"] as? String, !ref.isEmpty,
            !ref.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
            let rawDate = (row["timestamp"] ?? row["pushed_at"]) as? String,
            let date = ISO8601DateFormatter().date(from: rawDate) ?? fractionalDate(rawDate),
            let rawType = (row["activity_type"] ?? row["push_type"]) as? String, !rawType.isEmpty
        else { throw GitHubRequestError.malformed }
        let actor = row["actor"] as? [String: Any] ?? row["pusher"] as? [String: Any]
        let avatar: URL?
        if let value = actor?["avatar_url"] as? String, let url = URL(string: value),
            url.scheme == "https", url.host == "avatars.githubusercontent.com", url.user == nil,
            url.password == nil, url.port == nil
        {
            avatar = url
        } else {
            avatar = nil
        }
        return Self(
            id: id, before: before, after: after, ref: ref, date: date,
            type: rawType == "normal" ? "push" : rawType, actor: actor?["login"] as? String, avatarURL: avatar)
    }
    private static func fractionalDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }
}

struct GitHubActivitySummary: Sendable {
    var title: String?
    var commitCount: Int?
    var error: String?
}

private actor GitHubActivityReadGate {
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func run(_ work: @Sendable () async -> GitHubActivitySummary) async -> GitHubActivitySummary {
        if active >= 3 { await withCheckedContinuation { waiters.append($0) } } else { active += 1 }
        let result = await work()
        if waiters.isEmpty { active -= 1 } else { waiters.removeFirst().resume() }
        return result
    }
}

private struct GitHubRepositoryActivityService: Sendable {
    let client: GitHubClient
    let gate = GitHubActivityReadGate()
    func rows(_ repository: GitHubRepositoryReference, filters: GitHubActivityFilters) async throws
        -> [GitHubRepositoryActivity]
    {
        guard
            let rows = try await client.request(repository.apiRepositoryPath + "/activity", query: filters.query)
                as? [[String: Any]]
        else { throw GitHubRequestError.malformed }
        var seen = Set<Int>()
        return try rows.map(GitHubRepositoryActivity.parse).filter { seen.insert($0.id).inserted }.sorted {
            if $0.date == $1.date { return $0.id < $1.id }
            return filters.oldestFirst ? $0.date < $1.date : $0.date > $1.date
        }
    }
    func summary(_ item: GitHubRepositoryActivity, repository: GitHubRepositoryReference) async -> GitHubActivitySummary
    {
        await gate.run {
            async let titleResult = self.title(item, repository: repository)
            async let countResult = self.count(item, repository: repository)
            let (name, total) = await (titleResult, countResult)
            return GitHubActivitySummary(title: name.0, commitCount: total.0, error: name.1 ?? total.1)
        }
    }
    private func title(_ item: GitHubRepositoryActivity, repository: GitHubRepositoryReference) async -> (
        String?, String?
    ) {
        guard item.hasAfter else { return (nil, nil) }
        do {
            guard
                let row = try await client.request(repository.apiRepositoryPath + "/git/commits/" + item.after)
                    as? [String: Any],
                let message = row["message"] as? String, let title = message.split(whereSeparator: \.isNewline).first
            else { throw GitHubRequestError.malformed }
            return (String(title), nil)
        } catch { return (nil, HermesDiagnosticsService.safeSummary(error.localizedDescription)) }
    }
    private func count(_ item: GitHubRepositoryActivity, repository: GitHubRepositoryReference) async -> (Int?, String?)
    {
        guard item.hasBefore && item.hasAfter, ["push", "pr_merge", "merge_queue_merge"].contains(item.type) else {
            return (nil, nil)
        }
        do {
            guard
                let row = try await client.request(
                    repository.apiRepositoryPath + "/compare/\(item.before)...\(item.after)", query: ["per_page": "1"])
                    as? [String: Any],
                let count = row["total_commits"] as? Int, count >= 0
            else { throw GitHubRequestError.malformed }
            return (count, nil)
        } catch { return (nil, HermesDiagnosticsService.safeSummary(error.localizedDescription)) }
    }
}

@MainActor
final class GitHubRepositoryActivityModel: ObservableObject {
    struct Request: Equatable {
        let filters: GitHubActivityFilters
        let revision: Int
    }
    let repository: GitHubRepositoryReference
    private let service: GitHubRepositoryActivityService
    @Published var filters = GitHubActivityFilters()
    @Published private(set) var revision = 0
    @Published private(set) var items: [GitHubRepositoryActivity] = []
    @Published private(set) var summaries: [Int: GitHubActivitySummary] = [:]
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var branches: [String] = []
    @Published private(set) var actors: [String] = []
    private var loaded: Request?
    private var generation = UUID()
    private var tasks: [Int: Task<GitHubActivitySummary, Never>] = [:]
    var request: Request { Request(filters: filters, revision: revision) }
    init(repository: GitHubRepositoryReference, client: GitHubClient) {
        self.repository = repository
        service = GitHubRepositoryActivityService(client: client)
    }
    func reload() { revision += 1 }
    func load() async {
        let request = self.request
        guard !Task.isCancelled, request != loaded else { return }
        cancelLoads()
        let token = generation
        if loaded?.filters != request.filters {
            items = []
            summaries = [:]
        }
        loading = true
        error = nil
        defer { if token == generation { loading = false } }
        do {
            let rows = try await service.rows(repository, filters: request.filters)
            guard token == generation, !Task.isCancelled else { return }
            items = rows
            let ids = Set(rows.map(\.id))
            summaries = summaries.filter { ids.contains($0.key) }
            loaded = request
            branches = Array(Set(branches + rows.map(\.ref))).sorted()
            actors = Array(Set(actors + rows.compactMap(\.actor))).sorted()
        } catch {
            guard token == generation, !Task.isCancelled else { return }
            self.error = HermesDiagnosticsService.safeSummary(error.localizedDescription)
        }
    }
    func loadSummary(_ item: GitHubRepositoryActivity, force: Bool = false) async {
        guard !Task.isCancelled, !loading, items.contains(where: { $0.id == item.id }),
            force || summaries[item.id] == nil
        else { return }
        let token = generation
        let task: Task<GitHubActivitySummary, Never>
        if let existing = tasks[item.id] {
            task = existing
        } else {
            let service = service
            let repository = repository
            task = Task { await service.summary(item, repository: repository) }
            tasks[item.id] = task
        }
        let result = await task.value
        guard token == generation, !Task.isCancelled, !task.isCancelled else { return }
        var value = result
        if result.error != nil {
            value.title = result.title ?? summaries[item.id]?.title
            value.commitCount = result.commitCount ?? summaries[item.id]?.commitCount
        }
        summaries[item.id] = value
        tasks[item.id] = nil
    }
    func cancelLoads() {
        generation = UUID()
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        loading = false
    }
}
