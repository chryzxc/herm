import Foundation

struct ReviewGuideSource {
    let documents: [DiffDocument]
    let text: String
    let partial: Bool

    static func capture(_ documents: [DiffDocument], partial: Bool, maximumBytes: Int = 96_000) -> Self {
        var captured: [DiffDocument] = []
        var pieces: [String] = []
        var remaining = maximumBytes
        var incomplete = partial || documents.contains(where: { $0.isBinary || $0.isTruncated })
        for document in documents {
            let header = "File: \(document.path)\n"
            guard remaining > header.utf8.count else {
                incomplete = true
                break
            }
            let budget = remaining - header.utf8.count
            var patch = document.patch
            if patch.utf8.count > budget {
                let prefix = String(decoding: patch.utf8.prefix(budget), as: UTF8.self)
                patch = prefix.lastIndex(of: "\n").map { String(prefix[..<$0]) } ?? ""
                incomplete = true
            }
            let piece = header + patch
            captured.append(DiffDocument(path: document.path, patch: patch))
            pieces.append(piece)
            remaining -= piece.utf8.count + 2
            if incomplete && patch != document.patch { break }
        }
        if captured.count < documents.count { incomplete = true }
        return Self(documents: captured, text: pieces.joined(separator: "\n\n"), partial: incomplete)
    }
}

struct ReviewGuideReference: Identifiable {
    let path: String
    let firstLine: Int
    let lastLine: Int
    let side: String
    let match: DiffSearchMatch
    var id: String { "\(path):\(side):\(firstLine):\(lastLine)" }
}

enum ReviewGuideReferences {
    static func valid(in text: String, documents: [DiffDocument]) -> [ReviewGuideReference] {
        var references: [ReviewGuideReference] = []
        var seen = Set<String>()
        for document in documents {
            let escaped = NSRegularExpression.escapedPattern(for: document.path)
            guard
                let regex = try? NSRegularExpression(
                    pattern: #"(?<![A-Za-z0-9_./-])"# + escaped + #"(?:[:#]L?)(\d+)(?:[-–]L?(\d+))?(?!\d)"#)
            else { continue }
            let value = text as NSString
            for found in regex.matches(in: text, range: NSRange(location: 0, length: value.length)) {
                guard let start = Int(value.substring(with: found.range(at: 1))), start > 0 else { continue }
                let endRange = found.range(at: 2)
                let end = endRange.location == NSNotFound ? start : Int(value.substring(with: endRange)) ?? -1
                guard end >= start, end - start <= 200 else { continue }
                for side in ["RIGHT", "LEFT"] {
                    let selected = document.lines.filter { line in
                        let number = side == "RIGHT" ? line.newLine : line.oldLine
                        return number.map { (start...end).contains($0) } == true
                    }
                    guard selected.count == end - start + 1, let line = selected.first else { continue }
                    let reference = ReviewGuideReference(
                        path: document.path, firstLine: start, lastLine: end, side: side,
                        match: DiffSearchMatch(
                            path: document.path, lineIndex: line.index,
                            range: NSRange(location: 0, length: (DiffDocument.source(line) as NSString).length)))
                    if seen.insert(reference.id).inserted { references.append(reference) }
                    break
                }
            }
        }
        return references
    }
}
