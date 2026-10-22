import Foundation

enum MarkdownRenderDocumentBuilder {
    static func sections(for chunks: [StreamingPresentationChunk]) -> [MarkdownRenderSection] {
        var offset = 0
        var result: [MarkdownRenderSection] = []
        result.reserveCapacity(chunks.count)
        func append(id: Int, text: String, kind: MarkdownRenderSectionKind, continuation: MarkdownContinuationContext) {
            guard !text.isEmpty else { return }
            let start = offset
            offset += text.utf8.count
            result.append(
                MarkdownRenderSection(
                    id: id,
                    sourceRange: start..<offset,
                    source: text,
                    kind: kind,
                    continuation: continuation
                ))
        }
        for chunk in chunks {
            // Every chunk owns two section identities so a chunk that splits
            // never collides with a neighbour. The mutable tail uses Int.max,
            // which wraps to negative identities that stable chunks never use.
            let primaryID = chunk.id &* 2
            let remainderID = primaryID &+ 1
            switch chunk.context {
            case .fencedCode(let marker, let length, let language):
                let fence = MarkdownFence(marker: marker, length: length, language: language)
                let continuation = MarkdownContinuationContext.fencedCode(
                    marker: marker, length: length, language: language)
                if let split = closingSplit(of: chunk.text, fence: fence) {
                    // Promotion inside a fence can carry the closing fence and
                    // the prose after it; that prose must not render as code.
                    append(id: primaryID, text: split.code, kind: .code(language: language), continuation: continuation)
                    let remainder = classify(split.remainder)
                    append(
                        id: remainderID, text: split.remainder, kind: remainder.kind,
                        continuation: remainder.continuation)
                } else {
                    append(id: primaryID, text: chunk.text, kind: .code(language: language), continuation: continuation)
                }
            case .list(let marker, _):
                append(
                    id: primaryID, text: chunk.text, kind: .list(marker: marker),
                    continuation: chunkContext(chunk.context))
            case .quote:
                append(id: primaryID, text: chunk.text, kind: .quote, continuation: chunkContext(chunk.context))
            case .table:
                append(id: primaryID, text: chunk.text, kind: .table, continuation: .table)
            case .markdown, .paragraph, .inline:
                let classified = classify(chunk.text)
                append(id: primaryID, text: chunk.text, kind: classified.kind, continuation: classified.continuation)
            }
        }
        return result
    }

    private static func classify(_ text: String) -> (
        kind: MarkdownRenderSectionKind, continuation: MarkdownContinuationContext
    ) {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if MarkdownTableSyntax.isPureTable(text) { return (.table, .table) }
        if let level = headingLevel(line) {
            return (.heading(level: level), .markdown)
        }
        if let item = unorderedListItem(line) ?? orderedListItem(line) {
            return (.list(marker: item.marker), .list(marker: item.marker, indentation: 0))
        }
        if line.hasPrefix(">") {
            return (.quote, .quote(depth: line.prefix(while: { $0 == ">" }).count))
        }
        return (.prose, .paragraph)
    }

    /// Splits a fenced continuation at its closing fence line. The closing
    /// line stays with the code so the section sources still join to the
    /// original chunk text.
    private static func closingSplit(of text: String, fence: MarkdownFence) -> (code: String, remainder: String)? {
        var lineStart = text.startIndex
        while lineStart < text.endIndex {
            let newline = text[lineStart...].firstIndex(of: "\n")
            let lineEnd = newline ?? text.endIndex
            if fence.isClosed(by: String(text[lineStart..<lineEnd])) {
                let splitIndex = newline.map { text.index(after: $0) } ?? text.endIndex
                let remainder = String(text[splitIndex...])
                guard !remainder.isEmpty else { return nil }
                return (String(text[..<splitIndex]), remainder)
            }
            guard let newline else { break }
            lineStart = text.index(after: newline)
        }
        return nil
    }

    static func build(source: String, key: MarkdownRenderKey) -> MarkdownRenderDocument {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var sections: [MarkdownRenderSection] = []
        var offset = 0
        var index = 0
        var paragraph = ""
        var paragraphStart = 0
        // Consecutive list/quote lines share one section view. One NSTextView
        // per line made AutoLayout solve cost scale with line count (252
        // sections for one compaction message).
        var listBuffer = ""
        var listStart = 0
        var listMarker: String?
        var listIndentation = 0
        var quoteBuffer = ""
        var quoteStart = 0
        var quoteDepth = 0

        func appendSection(
            _ text: String, kind: MarkdownRenderSectionKind, context: MarkdownContinuationContext, start: Int
        ) {
            guard !text.isEmpty else { return }
            sections.append(
                MarkdownRenderSection(
                    id: sections.count,
                    sourceRange: start..<(start + text.utf8.count),
                    source: text,
                    kind: kind,
                    continuation: context
                ))
        }

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            appendSection(paragraph, kind: .prose, context: .paragraph, start: paragraphStart)
            paragraph = ""
        }

        func flushList() {
            guard let marker = listMarker else { return }
            appendSection(
                listBuffer,
                kind: .list(marker: marker),
                context: .list(marker: marker, indentation: listIndentation),
                start: listStart
            )
            listBuffer = ""
            listMarker = nil
        }

        func flushQuote() {
            guard !quoteBuffer.isEmpty else { return }
            appendSection(quoteBuffer, kind: .quote, context: .quote(depth: quoteDepth), start: quoteStart)
            quoteBuffer = ""
        }

        func flushBlocks() {
            flushParagraph()
            flushList()
            flushQuote()
        }

        func preserveWhitespace(_ whitespace: String, start: Int) {
            guard !whitespace.isEmpty else { return }
            if let last = sections.last,
                last.sourceRange.upperBound == start
            {
                sections[sections.count - 1] = MarkdownRenderSection(
                    id: last.id,
                    sourceRange: last.sourceRange.lowerBound..<(start + whitespace.utf8.count),
                    source: last.source + whitespace,
                    kind: last.kind,
                    continuation: last.continuation
                )
            } else {
                appendSection(whitespace, kind: .prose, context: .markdown, start: start)
            }
        }

        while index < lines.count {
            let line = lines[index]
            let rawLine = line + (index < lines.count - 1 ? "\n" : "")
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if let fence = MarkdownFence(opening: line) {
                flushBlocks()
                let start = offset
                var code = rawLine
                var cursor = index + 1
                var closed = false
                while cursor < lines.count {
                    let codeLine = lines[cursor]
                    let codeRaw = codeLine + (cursor < lines.count - 1 ? "\n" : "")
                    code += codeRaw
                    if fence.isClosed(by: codeLine) {
                        closed = true
                        cursor += 1
                        break
                    }
                    cursor += 1
                }
                appendSection(
                    code,
                    kind: .code(language: fence.language),
                    context: .fencedCode(marker: fence.marker, length: fence.length, language: fence.language),
                    start: start
                )
                let consumed = code.utf8.count
                offset += consumed
                index = cursor
                if !closed { break }
                continue
            }

            if trimmed.isEmpty {
                if !paragraph.isEmpty {
                    paragraph += rawLine
                    flushParagraph()
                } else {
                    // A blank line ends a buffered list/quote block; flushing
                    // first keeps section order aligned with source order.
                    flushList()
                    flushQuote()
                    preserveWhitespace(rawLine, start: offset)
                    offset += rawLine.utf8.count
                }
                index += 1
                continue
            }

            if MarkdownTableSyntax.isTableStart(lines, at: index) {
                flushBlocks()
                let start = offset
                var table = rawLine
                var cursor = index + 1
                while cursor < lines.count {
                    let next = lines[cursor]
                    let nextTrimmed = next.trimmingCharacters(in: .whitespaces)
                    guard
                        MarkdownTableSyntax.tableCells(nextTrimmed).count > 1
                            || (nextTrimmed.hasPrefix("|") && nextTrimmed.hasSuffix("|"))
                    else { break }
                    table += next + (cursor < lines.count - 1 ? "\n" : "")
                    cursor += 1
                }
                appendSection(table, kind: .table, context: .table, start: start)
                offset += table.utf8.count
                index = cursor
                continue
            }

            if let heading = headingLevel(trimmed) {
                flushBlocks()
                appendSection(rawLine, kind: .heading(level: heading), context: .markdown, start: offset)
            } else if let item = unorderedListItem(trimmed) ?? orderedListItem(trimmed) {
                flushParagraph()
                flushQuote()
                let indentation = line.prefix(while: { $0 == " " }).count
                // Ordered markers are unique per line ("1.", "2.", …); merge
                // by list class so numbered items share one section.
                let markerClass = item.marker.hasSuffix(".") ? "1." : item.marker
                if let marker = listMarker, marker == markerClass, indentation == listIndentation {
                    listBuffer += rawLine
                } else {
                    flushList()
                    listMarker = markerClass
                    listIndentation = indentation
                    listStart = offset
                    listBuffer = rawLine
                }
            } else if trimmed.hasPrefix(">") {
                flushParagraph()
                flushList()
                let depth = trimmed.prefix(while: { $0 == ">" }).count
                if quoteBuffer.isEmpty {
                    quoteStart = offset
                    quoteDepth = depth
                }
                quoteBuffer += rawLine
            } else {
                flushBlocks()
                if paragraph.isEmpty { paragraphStart = offset }
                paragraph += rawLine
            }

            offset += rawLine.utf8.count
            index += 1
        }
        flushBlocks()
        return MarkdownRenderDocument(key: key, source: source, sections: sections)
    }

    static func headingLevel(_ line: String) -> Int? {
        let count = line.prefix(while: { $0 == "#" }).count
        guard count > 0, count <= 6, line.dropFirst(count).first == " " else { return nil }
        return count
    }

    private static func chunkContext(_ context: StreamingChunkContext) -> MarkdownContinuationContext {
        switch context {
        case .markdown: return .markdown
        case .paragraph: return .paragraph
        case .list(let marker, let indentation): return .list(marker: marker, indentation: indentation)
        case .quote(let depth): return .quote(depth: depth)
        case .table: return .table
        case .inline(let delimiter, let base): return .inline(delimiter: delimiter, base: chunkContext(base))
        case .fencedCode(let marker, let length, let language):
            return .fencedCode(marker: marker, length: length, language: language)
        }
    }

    static func unorderedListItem(_ line: String) -> (marker: String, content: String)? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            return (String(marker.first!), String(line.dropFirst(2)))
        }
        return nil
    }

    static func orderedListItem(_ line: String) -> (marker: String, content: String)? {
        guard let dot = line.firstIndex(of: "."), dot > line.startIndex,
            line[..<dot].allSatisfy(\.isNumber), line.index(after: dot) < line.endIndex,
            line[line.index(after: dot)] == " "
        else { return nil }
        return (String(line[...dot]), String(line[line.index(dot, offsetBy: 2)...]))
    }
}

/// Shared table recognition for pure parsing and native styling.
enum MarkdownTableSyntax {
    static func isTableStart(_ lines: [String], at index: Int) -> Bool {
        let row = lines[index].trimmingCharacters(in: .whitespaces)
        let cells = tableCells(row)
        if row.hasPrefix("|"), row.hasSuffix("|") { return true }
        guard cells.count > 1 else { return false }
        guard index + 1 < lines.count else { return false }
        let separator = tableCells(lines[index + 1])
        return separator.count == cells.count && isSeparatorRow(separator)
    }

    static func isPureTable(_ markdown: String) -> Bool {
        let lines = markdown.split(separator: "\n").map(String.init).filter {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }
        guard !lines.isEmpty, isTableStart(lines, at: 0) else { return false }
        return lines.allSatisfy { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return tableCells(trimmed).count > 1 || (trimmed.hasPrefix("|") && trimmed.hasSuffix("|"))
        }
    }

    /// Splits a table row on unescaped pipes, keeping empty cells so columns
    /// stay aligned (`| a || c |` is three cells, not two).
    static func tableCells(_ line: String) -> [String] {
        var body = Substring(line.trimmingCharacters(in: .whitespaces))
        if body.hasPrefix("|") { body = body.dropFirst() }
        if body.hasSuffix("|"), !body.hasSuffix("\\|") { body = body.dropLast() }
        var cells: [String] = []
        var current = ""
        var escaped = false
        for character in body {
            if escaped {
                escaped = false
                if character == "|" { current.removeLast() }
                current.append(character)
                continue
            }
            if character == "\\" {
                escaped = true
                current.append(character)
            } else if character == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    static func isSeparatorRow(_ cells: [String]) -> Bool {
        !cells.isEmpty
            && cells.allSatisfy { cell in
                cell.contains("-") && cell.allSatisfy { $0 == "-" || $0 == ":" }
            }
    }

}
