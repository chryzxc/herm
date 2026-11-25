import Foundation

extension RichDocument {
    var hasVoiceVisuals: Bool { segments.contains(where: \.showsInVoiceGlance) }
}

extension RichDocument.Segment {
    /// Safe siblings still render when the reply also contains a form, action or live widget.
    var showsInVoiceGlance: Bool {
        switch self {
        case .diagram: true
        case .surface(let surface, _):
            surface.kind == .native && surface.blocks?.contains(where: \.type.isVisual) == true
        case .markdown, .unavailable, .pending, .preview: false
        }
    }
}

extension RichBlock.Kind {
    /// The block only works through a click or typing. Exhaustive so a new kind
    /// has to decide whether voice may preview it.
    var asksForInput: Bool {
        switch self {
        case .form, .checklist, .command, .record: true
        case .text, .table, .sources, .gallery, .chart, .section, .metrics, .comparison, .timeline, .graph, .tree,
            .imageComparison, .code, .findings, .workflow, .callout, .facts, .faq, .breakdown, .map:
            false
        }
    }

    /// Something to look at. Text, callouts and Q&A are spoken and a section only
    /// groups, so none is a reason to open the preview on its own.
    var isVisual: Bool {
        switch self {
        case .text, .section, .callout, .faq: false
        default: !asksForInput
        }
    }
}

/// Memoized `hasVoiceVisuals` for voice surfaces that ask on every render.
@MainActor
enum VoicePassiveVisual {
    private static var cache: [String: RichVoicePreview] = [:]

    /// A reply can already provide real data as a Markdown table, without a herm-ui block.
    /// Project the first complete rectangular table without touching the chat or fenced code.
    static func tablePreview(_ text: String) -> String? {
        guard text.utf8.count <= 65_536, text.contains("|"), !RichDocument.mentionsSurface(text) else { return nil }
        let lines = text.components(separatedBy: .newlines)
        var fence: MarkdownFence?
        for index in lines.indices {
            let line = lines[index]
            if let open = fence {
                if open.isClosed(by: line) { fence = nil }
                continue
            }
            if let opening = MarkdownFence(opening: line) {
                fence = opening
                continue
            }
            guard line.contains("|"), index + 2 < lines.count else { continue }
            let columns = MarkdownTableSyntax.tableCells(line)
            let separator = MarkdownTableSyntax.tableCells(lines[index + 1])
            guard (2...20).contains(columns.count), columns.count == separator.count,
                MarkdownTableSyntax.isSeparatorRow(separator)
            else { continue }
            let rows = lines.dropFirst(index + 2).prefix { $0.contains("|") }.prefix(100)
                .map(MarkdownTableSyntax.tableCells)
            guard !rows.isEmpty, rows.allSatisfy({ $0.count == columns.count }) else { continue }
            if let preview = table(title: "Results", columns: columns, rows: rows) { return preview }
        }
        return nil
    }

    static func table(title: String, columns: [String], rows: [[String]]) -> String? {
        let block = RichBlock(type: .table, columns: columns, rows: rows)
        let surface = RichSurface(
            version: 1, id: "voice-table", title: title, fallback: title, kind: .native, blocks: [block])
        guard surface.validate(), let data = try? JSONEncoder().encode(surface) else { return nil }
        return "```herm-ui\n" + String(decoding: data, as: UTF8.self) + "\n```"
    }

    static func contains(_ text: String) -> Bool { preview(text)?.isVisual == true }

    static func preview(_ text: String) -> RichVoicePreview? {
        guard RichDocument.mentionsSurface(text) else { return nil }
        if let hit = cache[text] { return hit }
        let result = RichVoicePreview(RichDocument(text))
        if text.utf8.count <= 2 * RichDocument.maximumBytes {
            if cache.count >= 8 { cache.removeAll() }
            cache[text] = result
        }
        return result
    }
}
