import Foundation

struct DiffSearchMatch: Identifiable, Equatable {
    let path: String
    let lineIndex: Int
    let range: NSRange
    var id: String { "\(path):\(lineIndex):\(range.location):\(range.length)" }
}

enum DiffSearch {
    static func matches(query: String, patches: [String: RepositoryDiff], limit: Int = 10_000) -> [DiffSearchMatch] {
        guard !query.isEmpty else { return [] }
        var matches: [DiffSearchMatch] = []
        for path in patches.keys.sorted() {
            guard let patch = patches[path] else { continue }
            for line in DiffDocument(path: path, patch: patch.text).lines {
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
