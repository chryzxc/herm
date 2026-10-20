import Foundation

enum DiffLineKind: Equatable, Codable, Sendable {
    case context, addition, deletion, hunk, metadata
}

struct DiffLine: Identifiable, Equatable, Codable, Sendable {
    let index: Int
    let text: String
    let kind: DiffLineKind
    var oldLine: Int? = nil
    var newLine: Int? = nil
    var id: Int { index }

    init(index: Int, text: String, kindOverride: DiffLineKind? = nil) {
        self.index = index
        self.text = text
        if let kindOverride {
            kind = kindOverride
        } else if text.hasPrefix("@@") {
            kind = .hunk
        } else if text.hasPrefix("+++") || text.hasPrefix("---") {
            kind = .metadata
        } else if text.hasPrefix("+") {
            kind = .addition
        } else if text.hasPrefix("-") {
            kind = .deletion
        } else {
            kind = .context
        }
    }
}

struct DiffSplitRow: Identifiable, Equatable {
    let id: Int
    let left: DiffLine?
    let right: DiffLine?
}

enum DiffPresentation {
    static func lines(_ patch: String) -> [DiffLine] {
        var old: Int?
        var new: Int?
        return patch.split(separator: "\n", omittingEmptySubsequences: false).enumerated().map { index, text in
            let inHunk = old != nil && new != nil
            let override: DiffLineKind? =
                inHunk && text.hasPrefix("---") ? .deletion : (inHunk && text.hasPrefix("+++") ? .addition : nil)
            var line = DiffLine(index: index, text: String(text), kindOverride: override)
            if line.kind == .hunk {
                old = nil
                new = nil
                let fields = text.split(separator: " ")
                if fields.count >= 3 {
                    old = fields[1].dropFirst().split(separator: ",").first.flatMap { Int($0) }
                    new = fields[2].dropFirst().split(separator: ",").first.flatMap { Int($0) }
                }
            } else if !text.hasPrefix("\\"), line.kind != .metadata {
                if line.kind != .addition {
                    line.oldLine = old
                    old = old.flatMap {
                        let (value, overflow) = $0.addingReportingOverflow(1)
                        return overflow ? nil : value
                    }
                }
                if line.kind != .deletion {
                    line.newLine = new
                    new = new.flatMap {
                        let (value, overflow) = $0.addingReportingOverflow(1)
                        return overflow ? nil : value
                    }
                }
            }
            return line
        }
    }

    static func splitRows(_ lines: [DiffLine]) -> [DiffSplitRow] {
        var rows: [DiffSplitRow] = []
        var cursor = 0
        while cursor < lines.count {
            let line = lines[cursor]
            if line.kind == .deletion {
                var deletions: [DiffLine] = []
                while cursor < lines.count, lines[cursor].kind == .deletion {
                    deletions.append(lines[cursor])
                    cursor += 1
                }
                var additions: [DiffLine] = []
                while cursor < lines.count, lines[cursor].kind == .addition {
                    additions.append(lines[cursor])
                    cursor += 1
                }
                for index in 0..<max(deletions.count, additions.count) {
                    rows.append(
                        DiffSplitRow(
                            id: rows.count, left: index < deletions.count ? deletions[index] : nil,
                            right: index < additions.count ? additions[index] : nil))
                }
            } else if line.kind == .addition {
                rows.append(DiffSplitRow(id: rows.count, left: nil, right: line))
                cursor += 1
            } else {
                rows.append(DiffSplitRow(id: rows.count, left: line, right: line))
                cursor += 1
            }
        }
        return rows
    }
}
