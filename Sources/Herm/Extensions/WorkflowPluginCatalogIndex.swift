import Foundation

enum WorkflowIntegrationSection: String, CaseIterable, Identifiable {
    case skills = "Skills"
    case tools = "Tools"
    case connectors = "Connectors"
    case plugins = "Plugins"
    case mcp = "MCP"
    var id: String { rawValue }
}

/// Rebuild only when inventory or popularity changes, never for selection or typing.
struct WorkflowPluginCatalogIndex {
    private struct Row {
        let entry: WorkflowPluginCatalogEntry
        let search: String
        let stars: Int
    }

    private var alphabetical: [Row] = []
    private var popular: [Row] = []
    private(set) var categories: [String] = []

    init(catalog: [WorkflowPluginCatalogEntry] = [], installed: Set<String> = [], stars: [String: Int] = [:]) {
        var seen = Set<String>()
        let rows = catalog.filter {
            !$0.installed && !installed.contains($0.id) && seen.insert($0.id).inserted
        }.map {
            Row(
                entry: $0, search: "\($0.id) \($0.title) \($0.detail)".lowercased(),
                stars: $0.githubSlug.flatMap { stars[$0] } ?? -1)
        }
        categories = Array(Set(rows.map { $0.entry.category })).sorted()
        func ordered(_ left: Row, _ right: Row, byStars: Bool) -> Bool {
            if left.entry.category != right.entry.category { return left.entry.category < right.entry.category }
            if byStars && left.stars != right.stars { return left.stars > right.stars }
            if left.entry.official != right.entry.official { return left.entry.official }
            let comparison = left.entry.title.localizedCaseInsensitiveCompare(right.entry.title)
            return comparison == .orderedSame ? left.entry.id < right.entry.id : comparison == .orderedAscending
        }
        alphabetical = rows.sorted { ordered($0, $1, byStars: false) }
        popular = rows.sorted { ordered($0, $1, byStars: true) }
    }

    func matches(_ query: String, category: String = "", byStars: Bool = false, limit: Int = .max)
        -> [WorkflowPluginCatalogEntry]
    {
        let needle = query.lowercased()
        return Array(
            (byStars ? popular : alphabetical).lazy.filter {
                (category.isEmpty || $0.entry.category == category) && (needle.isEmpty || $0.search.contains(needle))
            }.prefix(max(0, limit)).map(\.entry))
    }
}
