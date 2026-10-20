import Foundation

/// Adds only unchanged source lines proven against both immutable revisions.
enum DiffContextExpansion {
    private struct Hunk {
        let oldStart: Int
        let oldCount: Int
        let newStart: Int
        let newCount: Int
        let suffix: String
        var rows: [String]
        var oldOffset: Int { max(0, oldStart - 1) }
        var newOffset: Int { max(0, newStart - 1) }
    }

    static func expand(patch: String, oldSource: String, newSource: String, additionalContext: Int) throws -> String {
        guard patch.utf8.count <= 256_000, oldSource.utf8.count <= 256_000, newSource.utf8.count <= 256_000 else {
            throw unavailable()
        }
        let expression = try NSRegularExpression(pattern: #"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@(.*)$"#)
        var hunks: [Hunk] = []
        for row in patch.components(separatedBy: "\n") {
            let text = row as NSString
            if let match = expression.firstMatch(in: row, range: NSRange(location: 0, length: text.length)) {
                func number(_ group: Int, fallback: Int = 1) -> Int {
                    let range = match.range(at: group)
                    return range.location == NSNotFound ? fallback : Int(text.substring(with: range)) ?? -1
                }
                let oldStart = number(1)
                let oldCount = number(2)
                let newStart = number(3)
                let newCount = number(4)
                guard [oldStart, oldCount, newStart, newCount].allSatisfy({ (0...1_000_000).contains($0) }),
                    oldStart > 0 || oldCount == 0, newStart > 0 || newCount == 0
                else { throw unavailable() }
                hunks.append(
                    Hunk(
                        oldStart: oldStart, oldCount: oldCount, newStart: newStart, newCount: newCount,
                        suffix: text.substring(with: match.range(at: 5)), rows: []))
            } else if !hunks.isEmpty, [" ", "+", "-", "\\"].contains(row.first.map(String.init) ?? "") {
                hunks[hunks.count - 1].rows.append(row)
            }
        }
        guard !hunks.isEmpty else { throw unavailable() }
        func lines(_ source: String) -> [String] {
            guard !source.isEmpty else { return [] }
            let rows = source.components(separatedBy: "\n")
            return source.hasSuffix("\n") ? Array(rows.dropLast()) : rows
        }
        let old = lines(oldSource)
        let new = lines(newSource)
        let amount = min(200, max(0, additionalContext))
        var result: [String] = []
        for (index, hunk) in hunks.enumerated() {
            var oldIndex = hunk.oldOffset
            var newIndex = hunk.newOffset
            for row in hunk.rows {
                guard let prefix = row.first else { continue }
                if prefix == "\\" { continue }
                let content = String(row.dropFirst())
                if prefix != "+" {
                    guard old.indices.contains(oldIndex), old[oldIndex] == content else { throw unavailable() }
                    oldIndex += 1
                }
                if prefix != "-" {
                    guard new.indices.contains(newIndex), new[newIndex] == content else { throw unavailable() }
                    newIndex += 1
                }
            }
            guard oldIndex - hunk.oldOffset == hunk.oldCount, newIndex - hunk.newOffset == hunk.newCount else {
                throw unavailable()
            }
            let previousOldEnd = index > 0 ? hunks[index - 1].oldOffset + hunks[index - 1].oldCount : 0
            let previousNewEnd = index > 0 ? hunks[index - 1].newOffset + hunks[index - 1].newCount : 0
            let nextOldStart = index + 1 < hunks.count ? hunks[index + 1].oldOffset : old.count
            let nextNewStart = index + 1 < hunks.count ? hunks[index + 1].newOffset : new.count
            let beforeGap = min(hunk.oldOffset - previousOldEnd, hunk.newOffset - previousNewEnd)
            let afterGap = min(nextOldStart - oldIndex, nextNewStart - newIndex)
            guard beforeGap >= 0, afterGap >= 0 else { throw unavailable() }
            let beforeLimit = min(amount, index > 0 ? beforeGap / 2 : beforeGap)
            let afterLimit = min(amount, index + 1 < hunks.count ? afterGap / 2 : afterGap)
            var before = 0
            var after = 0
            while before < beforeLimit, old[hunk.oldOffset - before - 1] == new[hunk.newOffset - before - 1] {
                before += 1
            }
            while after < afterLimit, old[oldIndex + after] == new[newIndex + after] { after += 1 }
            result.append(
                "@@ -\(hunk.oldStart - before),\(hunk.oldCount + before + after) +\(hunk.newStart - before),\(hunk.newCount + before + after) @@\(hunk.suffix)"
            )
            if before > 0 { result += old[(hunk.oldOffset - before)..<hunk.oldOffset].map { " " + $0 } }
            result += hunk.rows
            if after > 0 { result += old[oldIndex..<(oldIndex + after)].map { " " + $0 } }
        }
        let output = result.joined(separator: "\n")
        guard !RepositoryService.boundDiff(output).isTruncated else {
            throw QuickDraftError.message("More context exceeds the review display limit.")
        }
        return output
    }
    private static func unavailable() -> QuickDraftError {
        .message("The source does not match this captured comparison. Refresh the review before expanding context.")
    }
}
