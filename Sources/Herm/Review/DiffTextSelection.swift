import Foundation

/// Maps visual alignment rows back to source text, excluding synthetic placeholders.
enum DiffTextSelection {
    static func source(lines: [DiffLine?], range: NSRange) -> String {
        var offset = 0
        var result = ""
        for (index, line) in lines.enumerated() {
            let text = line.map(DiffDocument.source) ?? ""
            let rendered = text + (index + 1 < lines.count ? "\n" : "")
            let length = (rendered as NSString).length
            let intersection = NSIntersectionRange(range, NSRange(location: offset, length: length))
            if let line, [.context, .addition, .deletion].contains(line.kind), intersection.length > 0 {
                result += (rendered as NSString).substring(
                    with: NSRange(location: intersection.location - offset, length: intersection.length))
            }
            offset += length
        }
        return result
    }
    static func rowRange(in text: String, selection: NSRange) -> ClosedRange<Int> {
        let source = text as NSString
        let start = min(max(0, selection.location), source.length)
        let end = min(source.length, max(start, NSMaxRange(selection) - (selection.length > 0 ? 1 : 0)))
        return source.substring(to: start).filter { $0 == "\n" }
            .count...source.substring(to: end).filter { $0 == "\n" }.count
    }
}
