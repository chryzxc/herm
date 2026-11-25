import Foundation

struct DiffSearchMatch: Identifiable, Equatable, Sendable {
    let path: String
    let lineIndex: Int
    let range: NSRange
    var id: String { "\(path):\(lineIndex):\(range.location):\(range.length)" }
}

enum DiffSearch {
    struct Patch: Sendable {
        let diff: RepositoryDiff
        let document: DiffDocument
        let noteID: String

        init(_ diff: RepositoryDiff, at comparison: DiffComparisonIdentity) {
            self.diff = diff
            document = DiffDocument(path: diff.path, patch: diff.text)
            noteID = comparison.documentID(document)
        }
    }

    struct Projection: Sendable {
        let files: [String]
        let matches: [DiffSearchMatch]
    }

    static func project(
        search: String, filter: String, files: [String], patches: [String: Patch]
    ) async -> Projection {
        let worker = Task.detached(priority: .userInitiated) {
            let visible =
                filter.isEmpty
                ? files
                : files.filter { path in
                    !Task.isCancelled
                        && (path.localizedCaseInsensitiveContains(filter)
                            || patches[path]?.diff.text.localizedCaseInsensitiveContains(filter) == true)
                }
            return Projection(files: visible, matches: matches(query: search, patches: patches))
        }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    static func matches(query: String, patches: [String: Patch], limit: Int = 10_000) -> [DiffSearchMatch] {
        guard !query.isEmpty else { return [] }
        var matches: [DiffSearchMatch] = []
        for path in patches.keys.sorted() {
            guard let patch = patches[path] else { continue }
            for line in patch.document.lines {
                if Task.isCancelled { return [] }
                let source = DiffDocument.source(line) as NSString
                var remainder = NSRange(location: 0, length: source.length)
                while remainder.length > 0 {
                    let found = source.range(of: query, options: [.caseInsensitive, .literal], range: remainder)
                    guard found.location != NSNotFound else { break }
                    matches.append(DiffSearchMatch(path: path, lineIndex: line.index, range: found))
                    if matches.count >= limit { return matches }
                    remainder = NSRange(location: NSMaxRange(found), length: source.length - NSMaxRange(found))
                }
            }
        }
        return matches
    }
}
