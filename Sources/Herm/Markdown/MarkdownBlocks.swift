import SwiftUI

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

    static func renderBlocks(for markdown: String) -> [RenderBlock] { renderBlocks(from: parseBlocks(markdown)) }
    /// Line-level parse output before inline Markdown is rendered.
    private enum ParsedBlock {
        case heading(level: Int, text: String)
        case paragraph(String)
        case listItem(text: String, marker: String)
        case code(String, language: String?)
        case quote(String)
        case tableRow([String])
    }

    private static func parseBlocks(_ markdown: String) -> [ParsedBlock] {
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
    private static func unmarkedJSONObject(
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
    private static func renderBlocks(from parsed: [ParsedBlock]) -> [RenderBlock] {
        parsed.map { block in
            switch block {
            case .heading(let level, let text): return .heading(level: level, text: inlineMarkdown(text))
            case .paragraph(let text): return .paragraph(inlineMarkdown(text))
            case .listItem(let text, let marker): return .listItem(text: inlineMarkdown(text), marker: marker)
            case .code(let code, let language): return .code(code, language: language)
            case .quote(let text): return .quote(inlineMarkdown(text))
            case .tableRow(let columns): return .tableRow(columns.map(inlineMarkdown))
            }
        }
    }

    private static func inlineMarkdown(_ value: String) -> AttributedString {
        MarkdownMessageView.linkAffordances(in: NativeMarkdownAttributedTextBuilder.inlineMarkdown(value))
    }
}
