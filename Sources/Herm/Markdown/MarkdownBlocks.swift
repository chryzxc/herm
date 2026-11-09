import SwiftUI

/// Theme-independent Markdown preparation can run away from the UI actor.
enum MarkdownPreparedBlock: Sendable {
    case heading(level: Int, text: AttributedString)
    case paragraph(AttributedString)
    case listItem(text: AttributedString, marker: String)
    case code(String, language: String?)
    case quote(AttributedString)
    case tableRow([AttributedString])
}

enum MarkdownInlineParser {
    static let safeLinkSchemes: Set<String> = ["http", "https", "mailto"]

    static func parse(_ value: String) -> AttributedString {
        let value = value.replacingOccurrences(
            of: #"\*\*(https?://[^\s*<>]+)\*\*"#, with: "**<$1>**", options: .regularExpression)
        var parsed =
            (try? AttributedString(
                markdown: value, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            )) ?? AttributedString(value)
        for run in parsed.runs {
            guard let link = run.link else { continue }
            if !safeLinkSchemes.contains(link.scheme?.lowercased() ?? "") { parsed[run.range].link = nil }
        }
        return parsed
    }
}

@MainActor
enum MarkdownPreparedBlockCache {
    private final class Entry {
        let blocks: [MarkdownPreparedBlock]
        init(_ blocks: [MarkdownPreparedBlock]) { self.blocks = blocks }
    }
    private static let cache: NSCache<NSString, Entry> = {
        let result = NSCache<NSString, Entry>()
        result.countLimit = 2_000
        result.totalCostLimit = 16 * 1024 * 1024
        return result
    }()
    static func blocks(for source: String) -> [MarkdownPreparedBlock]? {
        cache.object(forKey: source as NSString)?.blocks
    }
    static func insert(_ blocks: [MarkdownPreparedBlock], for source: String) {
        cache.setObject(Entry(blocks), forKey: source as NSString, cost: max(1, source.utf8.count * 4))
    }
}

@MainActor
extension MarkdownRenderDocumentBuilder {
    enum RenderBlock: Equatable {
        case heading(level: Int, text: AttributedString)
        case paragraph(AttributedString)
        case listItem(text: AttributedString, marker: String)
        case code(String, language: String?)
        case quote(AttributedString)
        case tableRow([AttributedString])
    }

    static func renderBlocks(for markdown: String) -> [RenderBlock] {
        renderBlocks(from: preparedBlocks(for: markdown))
    }

    nonisolated static func preparedBlocks(for markdown: String) -> [MarkdownPreparedBlock] {
        parseBlocks(markdown).map { block in
            switch block {
            case .heading(let level, let text): return .heading(level: level, text: MarkdownInlineParser.parse(text))
            case .paragraph(let text): return .paragraph(MarkdownInlineParser.parse(text))
            case .listItem(let text, let marker):
                return .listItem(text: MarkdownInlineParser.parse(text), marker: marker)
            case .code(let code, let language): return .code(code, language: language)
            case .quote(let text): return .quote(MarkdownInlineParser.parse(text))
            case .tableRow(let columns): return .tableRow(columns.map(MarkdownInlineParser.parse))
            }
        }
    }
    /// Line-level parse output before inline Markdown is rendered.
    private enum ParsedBlock: Sendable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case listItem(text: String, marker: String)
        case code(String, language: String?)
        case quote(String)
        case tableRow([String])
    }

    nonisolated private static func parseBlocks(_ markdown: String) -> [ParsedBlock] {
        var result: [ParsedBlock] = []
        var code: [String] = []
        var language: String?
        var fence: MarkdownFence?
        var paragraph: [String] = []
        func flushParagraph() {
            let text = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            paragraph.removeAll()
            if !text.isEmpty { result.append(.paragraph(text)) }
        }
        func flushCode() {
            result.append(.code(code.joined(separator: "\n"), language: language))
            code.removeAll()
            language = nil
        }
        let lines = markdown.components(separatedBy: "\n")
        var skippedJSONLines = 0
        var inTable = false
        for (index, line) in lines.enumerated() {
            if index < skippedJSONLines { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if fence == nil, let json = Self.unmarkedJSONObject(in: lines, startingAt: index) {
                flushParagraph()
                result.append(.code(json.text, language: "json"))
                skippedJSONLines = json.nextLineIndex
                continue
            }
            if let active = fence {
                if active.isClosed(by: line) {
                    flushCode()
                    fence = nil
                } else {
                    code.append(line)
                }
                continue
            }
            if let opening = MarkdownFence(opening: line) {
                flushParagraph()
                fence = opening
                language = opening.language
                continue
            }
            let cells = NativeMarkdownAttributedTextBuilder.tableCells(trimmed)
            if (inTable && cells.count > 1) || NativeMarkdownAttributedTextBuilder.isTableStart(lines, at: index) {
                inTable = true
                flushParagraph()
                if !NativeMarkdownAttributedTextBuilder.isSeparatorRow(cells) {
                    result.append(.tableRow(cells))
                }
                continue
            }
            inTable = false
            if let level = Self.headingLevel(trimmed) {
                flushParagraph()
                result.append(
                    .heading(
                        level: level,
                        text: String(trimmed.drop(while: { $0 == "#" }).drop(while: { $0 == " " }))))
                continue
            }
            if let item = Self.orderedListItem(trimmed) {
                flushParagraph()
                // Honor the authored marker. The former synthesized counter reset on
                // prose/blank lines, incorrectly rendering valid `4.` and `5.` as 1.
                result.append(.listItem(text: item.content, marker: item.marker))
                continue
            }
            if let item = Self.unorderedListItem(trimmed) {
                flushParagraph()
                result.append(.listItem(text: item.content, marker: "•"))
                continue
            }
            if trimmed.hasPrefix(">") {
                flushParagraph()
                let content = String(trimmed.dropFirst().trimmingCharacters(in: .whitespaces))
                if !content.isEmpty { result.append(.quote(content)) }
                continue
            }
            if trimmed.isEmpty {
                flushParagraph()
                continue
            }
            paragraph.append(line)
        }
        if fence != nil { flushCode() } else { flushParagraph() }
        return result
    }

    /// Hermes status messages can contain a prose summary followed by a raw
    /// JSON result. JSON is only Markdown when fenced, but its object syntax is
    /// unambiguous and should still be readable as structured output instead
    /// of flowing through a proportional prose paragraph.
    nonisolated private static func unmarkedJSONObject(
        in lines: [String], startingAt start: Int
    ) -> (text: String, nextLineIndex: Int)? {
        guard lines[start].trimmingCharacters(in: .whitespaces).hasPrefix("{") else {
            return nil
        }

        // A JSON object can only parse where braces balance outside string
        // literals, so track depth in a single pass and attempt the validating
        // JSONSerialization call only at those boundaries instead of re-parsing
        // the whole growing candidate after every accumulated line.
        var candidate = ""
        var candidateBytes = 0
        var depth = 0
        var inString = false
        var escaped = false
        let lastLine = min(lines.count, start + MarkdownJSONScanPolicy.maxScanLines)
        for end in start..<lastLine {
            let line = lines[end]
            if !candidate.isEmpty {
                candidate.append("\n")
                candidateBytes += 1
            }
            candidate.append(line)
            candidateBytes += line.utf8.count
            if candidateBytes > MarkdownJSONScanPolicy.maxScanBytes { return nil }
            for character in line {
                if inString {
                    if escaped {
                        escaped = false
                    } else if character == "\\" {
                        escaped = true
                    } else if character == "\"" {
                        inString = false
                    }
                    continue
                }
                switch character {
                case "\"": inString = true
                case "{": depth += 1
                case "}":
                    depth -= 1
                    if depth < 0 { return nil }
                default: continue
                }
            }
            guard depth == 0 else { continue }
            guard let data = candidate.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: data),
                object is [String: Any]
            else {
                continue
            }
            return (candidate, end + 1)
        }
        return nil
    }

    static func codeBlockLanguages(in markdown: String) -> [String?] {
        parseBlocks(markdown).compactMap { block in
            guard case .code(_, let language) = block else { return nil }
            return language
        }
    }
    static func orderedListMarkers(in markdown: String) -> [String] {
        parseBlocks(markdown).compactMap { block in
            guard case .listItem(_, let marker) = block, marker != "•" else { return nil }
            return marker
        }
    }
    private static func renderBlocks(from parsed: [MarkdownPreparedBlock]) -> [RenderBlock] {
        parsed.map { block in
            switch block {
            case .heading(let level, let text):
                return .heading(level: level, text: MarkdownMessageView.linkAffordances(in: text))
            case .paragraph(let text): return .paragraph(MarkdownMessageView.linkAffordances(in: text))
            case .listItem(let text, let marker):
                return .listItem(text: MarkdownMessageView.linkAffordances(in: text), marker: marker)
            case .code(let code, let language): return .code(code, language: language)
            case .quote(let text): return .quote(MarkdownMessageView.linkAffordances(in: text))
            case .tableRow(let columns): return .tableRow(columns.map { MarkdownMessageView.linkAffordances(in: $0) })
            }
        }
    }
}
