import Foundation

/// A view-local cache of the explorer's filtered and disclosed rows.
@MainActor
final class ExplorerVisibleTree {
    struct Result {
        let entries: [ProjectFileEntry]
        let fileCount: Int
        let firstFile: ProjectFileEntry?
    }

    private var previousEntries: [ProjectFileEntry]?
    private var previousExpanded: Set<String> = []
    private var previousQuery = ""
    private var previousResult: Result?
    private(set) var buildCount = 0

    func resolve(entries: [ProjectFileEntry], expanded: Set<String>, query: String) -> Result {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if previousEntries == entries, previousExpanded == expanded, previousQuery == query, let previousResult {
            return previousResult
        }
        let visible: [ProjectFileEntry]
        if !query.isEmpty {
            var paths = Set<String>()
            for entry in entries where !entry.isDirectory {
                let name = entry.path.split(separator: "/").last.map(String.init) ?? entry.path
                guard name.lowercased().contains(query) else { continue }
                paths.insert(entry.path)
                let components = entry.path.split(separator: "/").map(String.init)
                for index in 0..<max(0, components.count - 1) {
                    paths.insert(components[...index].joined(separator: "/"))
                }
            }
            visible = entries.filter { paths.contains($0.path) }
        } else {
            visible = entries.filter { entry in
                let components = entry.path.split(separator: "/").map(String.init)
                for index in 0..<max(0, components.count - 1)
                where !expanded.contains(components[...index].joined(separator: "/")) {
                    return false
                }
                return true
            }
        }
        let files = visible.filter { !$0.isDirectory }
        let result = Result(entries: visible, fileCount: files.count, firstFile: files.first)
        previousEntries = entries
        previousExpanded = expanded
        previousQuery = query
        previousResult = result
        buildCount += 1
        return result
    }
}
