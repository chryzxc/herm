import SwiftUI

/// Presentation of completed assistant Markdown. These blocks have no artifact identity or host actions.
enum RichMarkdownPart: Equatable, Sendable {
    case text(String)
    case table(RichMarkdownTable)
    case callout(RichCallout)
    case facts(RichFacts)

    static func isCandidate(_ source: String) -> Bool {
        var source = source
        return source.withUTF8 { bytes in
            bytes.count <= 65_536
                && (memmem(bytes.baseAddress, bytes.count, "[!", 2) != nil
                    || memmem(bytes.baseAddress, bytes.count, ":**", 3) != nil
                    || memmem(bytes.baseAddress, bytes.count, "**:", 3) != nil
                    || (memmem(bytes.baseAddress, bytes.count, "|", 1) != nil
                        && memmem(bytes.baseAddress, bytes.count, "---", 3) != nil))
        }
    }

    /// Reuse the section parser so fenced examples, ordinary quotes and surrounding prose keep their meaning.
    static func project(_ sections: [MarkdownRenderSection]) -> [Self] {
        var parts: [Self] = []
        var markdown = ""
        func flush() {
            let text = markdown.trimmingCharacters(in: .newlines)
            if !text.isEmpty { parts.append(.text(text)) }
            markdown = ""
        }
        for section in sections {
            if Task.isCancelled { return [] }
            switch section.kind {
            case .table:
                if let table = RichMarkdownTable(section.source) {
                    flush()
                    parts.append(.table(table))
                    continue
                }
            case .list:
                if let facts = facts(from: section.source) {
                    flush()
                    parts.append(.facts(facts))
                    continue
                }
            case .quote:
                if let callout = callout(from: section.source) {
                    flush()
                    parts.append(.callout(callout))
                    continue
                }
            default: break
            }
            markdown += section.source
        }
        guard !parts.isEmpty else { return [] }
        flush()
        return parts
    }

    fileprivate static func lines(in source: String) -> [String] {
        var lines = source.components(separatedBy: "\n")
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        return lines
    }

    private static func facts(from source: String) -> RichFacts? {
        let lines = RichMarkdownPart.lines(in: source)
        guard (2...100).contains(lines.count) else { return nil }
        var items: [RichFacts.Item] = []
        for (index, line) in lines.enumerated() {
            guard let match = line.wholeMatch(of: /[ ]{0,3}[-+*] \*\*([^*]+?)(?::\*\*|\*\*:)[ \t]+(.+)/)
            else { return nil }
            items.append(.init(id: String(index), label: String(match.1), value: String(match.2)))
        }
        let facts = RichFacts(items: items)
        return facts.validate() ? facts : nil
    }

    private static func callout(from source: String) -> RichCallout? {
        let lines = RichMarkdownPart.lines(in: source)
        let quoted = lines.compactMap { line -> String? in
            let indent = line.prefix(while: { $0 == " " })
            let rest = line.dropFirst(indent.count)
            guard indent.count <= 3, rest.first == ">" else { return nil }
            let content = rest.dropFirst()
            return String(content.first == " " ? content.dropFirst() : content)
        }
        guard quoted.count == lines.count, let header = quoted.first?.trimmingCharacters(in: .whitespaces),
            let tone = RichCallout.Tone.allCases.first(where: {
                header.uppercased() == "[!\($0.rawValue.uppercased())]"
            })
        else { return nil }
        let callout = RichCallout(tone: tone, body: quoted.dropFirst().joined(separator: "\n"))
        return callout.validate() ? callout : nil
    }
}

struct RichMarkdownTable: Equatable, Sendable {
    let dataset: RichDataset
    enum ColumnAlignment: Sendable { case leading, center, trailing }
    let alignments: [ColumnAlignment?]
    let cells: [[AttributedString]]

    init?(_ source: String) {
        let lines = RichMarkdownPart.lines(in: source)
        guard (3...1_002).contains(lines.count),
            lines.allSatisfy({ !$0.hasPrefix("    ") && !$0.hasPrefix("\t") })
        else { return nil }
        let columns = MarkdownTableSyntax.tableCells(lines[0])
        let separator = MarkdownTableSyntax.tableCells(lines[1])
        guard (1...20).contains(columns.count), columns.count == separator.count,
            columns.allSatisfy({ !$0.isEmpty }),
            separator.allSatisfy({ $0.wholeMatch(of: /:?-{3,}:?/) != nil })
        else { return nil }

        let rows = lines.dropFirst(2).map(MarkdownTableSyntax.tableCells)
        guard rows.allSatisfy({ $0.count == columns.count }) else { return nil }
        let headers = columns.map(MarkdownInlineParser.parse)
        // A linked header already has a primary action. Preserve it in the ordinary Markdown table.
        guard headers.allSatisfy({ !$0.runs.contains { $0.link != nil } }) else { return nil }
        alignments = separator.map {
            if $0.hasPrefix(":") { return $0.hasSuffix(":") ? .center : .leading }
            return $0.hasSuffix(":") ? .trailing : nil
        }
        cells = rows.map { $0.map(MarkdownInlineParser.parse) }
        dataset = RichDataset.displayTable(
            id: "markdown", columns: headers.map { String($0.characters) },
            rows: cells.map { $0.map { String($0.characters) } })
    }
}

struct RichMarkdownReply: View {
    let source: String
    @State private var parts: [RichMarkdownPart]?

    /// Paging a completed reply back into view should use its final layout on the first frame.
    private final class Entry {
        let parts: [RichMarkdownPart]
        init(_ parts: [RichMarkdownPart]) { self.parts = parts }
    }
    private static let cache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.countLimit = 64
        cache.totalCostLimit = 8 * 1_024 * 1_024
        return cache
    }()

    init(source: String) {
        self.source = source
        _parts = State(initialValue: Self.cache.object(forKey: source as NSString)?.parts)
    }

    var body: some View {
        Group {
            if let parts, !parts.isEmpty {
                VStack(alignment: .leading, spacing: DockSpacing.group) {
                    ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                        switch part {
                        case .text(let text): MarkdownMessageView(markdown: text).equatable()
                        case .callout(let callout): RichCalloutView(callout: callout)
                        case .table(let table): RichMarkdownTableView(table: table)
                        case .facts(let facts): RichFactsView(facts: facts, inlineMarkdown: true)
                        }
                    }
                }
            } else {
                MarkdownMessageView(markdown: source).equatable()
            }
        }
        .task {
            guard parts == nil else { return }
            let key = MarkdownMessageView.renderKey(for: source)
            let cached = MarkdownRenderDocumentCache.cached(source: source, key: key)
            let projected = await Self.project(source, key: key, cached: cached)
            guard !Task.isCancelled else { return }
            Self.cache.setObject(Entry(projected), forKey: source as NSString, cost: max(1, source.utf8.count * 8))
            parts = projected
        }
    }

    private nonisolated static func project(
        _ source: String, key: MarkdownRenderKey, cached: MarkdownRenderDocument?
    ) async -> [RichMarkdownPart] {
        RichMarkdownPart.project((cached ?? MarkdownRenderDocumentBuilder.build(source: source, key: key)).sections)
    }
}
