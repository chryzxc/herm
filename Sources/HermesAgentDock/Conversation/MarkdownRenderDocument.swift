import AppKit
import SwiftUI

/// Identity for a completed render. The source text remains owned by
/// `ChatMessage`/`StreamingText`; this key only identifies a presentation
/// projection and its theme.
struct MarkdownRenderKey: Hashable, Sendable {
    let messageID: UUID
    let contentRevision: Int
    let themeRevision: Int
}

indirect enum MarkdownContinuationContext: Equatable, Sendable {
    case markdown
    case paragraph
    case list(marker: String, indentation: Int)
    case quote(depth: Int)
    case table
    case fencedCode(marker: Character, length: Int, language: String?)
    case inline(delimiter: String, base: MarkdownContinuationContext)
}

enum MarkdownRenderSectionKind: Equatable, Sendable {
    case prose
    case heading(level: Int)
    case list(marker: String)
    case quote
    case code(language: String?)
    case table
}

struct MarkdownRenderSection: Identifiable, Equatable, Sendable {
    let id: Int
    let sourceRange: Range<Int>
    let source: String
    let kind: MarkdownRenderSectionKind
    let continuation: MarkdownContinuationContext

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.sourceRange == rhs.sourceRange && lhs.source == rhs.source
            && lhs.kind == rhs.kind && lhs.continuation == rhs.continuation
    }
}

struct MarkdownRenderDocument: Equatable, Sendable {
    let key: MarkdownRenderKey
    let source: String
    let sections: [MarkdownRenderSection]

    var cost: Int {
        source.utf8.count + sections.reduce(0) { $0 + $1.source.utf8.count }
    }
}

@MainActor
enum MarkdownRenderDocumentCache {
    private static let cache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.totalCostLimit = 32 * 1024 * 1024
        cache.countLimit = 600
        return cache
    }()

    private final class Entry {
        let document: MarkdownRenderDocument
        init(_ document: MarkdownRenderDocument) { self.document = document }
    }

    static func document(for source: String, key: MarkdownRenderKey) -> MarkdownRenderDocument {
        let cacheKey = "\(key.messageID.uuidString):\(key.contentRevision):\(key.themeRevision)" as NSString
        if let entry = cache.object(forKey: cacheKey) {
            DebugLog.writePerformance("markdown_document_cache_hit bytes=\(source.utf8.count)")
            return entry.document
        }
        DebugLog.writePerformance("markdown_document_cache_miss bytes=\(source.utf8.count)")
        let started = DispatchTime.now().uptimeNanoseconds
        let document = MarkdownRenderDocumentBuilder.build(source: source, key: key)
        cache.setObject(Entry(document), forKey: cacheKey, cost: max(document.cost, 1))
        let duration = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        DebugLog.writePerformance("markdown_document_parse bytes=\(source.utf8.count) sections=\(document.sections.count) duration_ms=\(String(format: "%.2f", duration))")
        return document
    }
}

/// Persistent AppKit host for a long message. SwiftUI owns the row and the
/// transcript scroll view; this host owns only the block projections and their
/// intrinsic measurement. A coordinator keeps the same container alive while
/// the source revision changes (including the streaming-to-completed handoff).
@MainActor
struct NativeMarkdownDocumentHost: NSViewRepresentable, Equatable {
    let source: String
    let key: MarkdownRenderKey
    let streamingSections: [MarkdownRenderSection]?

    init(source: String, key: MarkdownRenderKey, streamingSections: [MarkdownRenderSection]? = nil) {
        self.source = source
        self.key = key
        self.streamingSections = streamingSections
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.source == rhs.source && lhs.key == rhs.key && lhs.streamingSections == rhs.streamingSections
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NativeMarkdownDocumentContainerView {
        let view = NativeMarkdownDocumentContainerView()
        context.coordinator.update(view, source: source, key: key, sections: streamingSections)
        return view
    }

    func updateNSView(_ nsView: NativeMarkdownDocumentContainerView, context: Context) {
        context.coordinator.update(nsView, source: source, key: key, sections: streamingSections)
    }

    @MainActor
    final class Coordinator {
        private var renderedKey: MarkdownRenderKey?
        private var renderedSource: String?

        func update(
            _ view: NativeMarkdownDocumentContainerView,
            source: String,
            key: MarkdownRenderKey,
            sections: [MarkdownRenderSection]?
        ) {
            if let sections {
                view.applyStreaming(sections: sections, source: source)
                renderedKey = key
                renderedSource = source
                return
            }
            guard renderedKey != key || renderedSource != source else { return }
            let started = DispatchTime.now().uptimeNanoseconds
            let document = MarkdownRenderDocumentCache.document(for: source, key: key)
            view.apply(document: document)
            renderedKey = key
            renderedSource = source
            let duration = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            DebugLog.writePerformance("markdown_native_host_update sections=\(document.sections.count) duration_ms=\(String(format: "%.2f", duration))")
        }
    }
}

enum MarkdownRenderDocumentBuilder {
    static func sections(for chunks: [StreamingPresentationChunk]) -> [MarkdownRenderSection] {
        var offset = 0
        return chunks.map { chunk in
            let kind: MarkdownRenderSectionKind
            let continuation: MarkdownContinuationContext
            switch chunk.context {
            case .fencedCode(let marker, let length, let language):
                kind = .code(language: language)
                continuation = .fencedCode(marker: marker, length: length, language: language)
            case .list(let marker, _):
                kind = .list(marker: marker)
                continuation = chunkContext(chunk.context)
            case .quote:
                kind = .quote
                continuation = chunkContext(chunk.context)
            case .table:
                kind = .table
                continuation = .table
            case .markdown, .paragraph, .inline:
                let line = chunk.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if let level = headingLevel(line) {
                    kind = .heading(level: level)
                    continuation = .markdown
                } else if let item = unorderedListItem(line) ?? orderedListItem(line) {
                    kind = .list(marker: item.marker)
                    continuation = .list(marker: item.marker, indentation: 0)
                } else if line.hasPrefix(">") {
                    kind = .quote
                    continuation = .quote(depth: line.prefix(while: { $0 == ">" }).count)
                } else {
                    kind = .prose
                    continuation = .paragraph
                }
            }
            let start = offset
            offset += chunk.text.utf8.count
            return MarkdownRenderSection(
                id: chunk.id,
                sourceRange: start..<offset,
                source: chunk.text,
                kind: kind,
                continuation: continuation
            )
        }
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

        func appendSection(_ text: String, kind: MarkdownRenderSectionKind, context: MarkdownContinuationContext, start: Int) {
            guard !text.isEmpty else { return }
            sections.append(MarkdownRenderSection(
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
               last.sourceRange.upperBound == start {
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

            if trimmed.hasPrefix("|") && trimmed.hasSuffix("|") {
                flushBlocks()
                let start = offset
                var table = rawLine
                var cursor = index + 1
                while cursor < lines.count {
                    let next = lines[cursor]
                    let nextTrimmed = next.trimmingCharacters(in: .whitespaces)
                    guard nextTrimmed.hasPrefix("|") && nextTrimmed.hasSuffix("|") else { break }
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

    private static func headingLevel(_ line: String) -> Int? {
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
        case .fencedCode(let marker, let length, let language): return .fencedCode(marker: marker, length: length, language: language)
        }
    }

    private static func unorderedListItem(_ line: String) -> (marker: String, content: String)? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            return (String(marker.first!), String(line.dropFirst(2)))
        }
        return nil
    }

    private static func orderedListItem(_ line: String) -> (marker: String, content: String)? {
        guard let dot = line.firstIndex(of: "."), dot > line.startIndex,
              line[..<dot].allSatisfy(\.isNumber), line.index(after: dot) < line.endIndex,
              line[line.index(after: dot)] == " " else { return nil }
        return (String(line[...dot]), String(line[line.index(dot, offsetBy: 2)...]))
    }
}

@MainActor
final class NativeMarkdownDocumentContainerView: NSView {
    private let stack = NSStackView()
    private var sectionViews: [Int: NSView] = [:]
    private var source = ""
    // SwiftUI consults intrinsic sizing on every layout pass while the row
    // is mounted. `stack.fittingSize` re-solves AutoLayout over every section
    // view per consultation — for a 250-section document that measured
    // ~15.6 ms per call, an entire frame budget spent per layout query. The
    // cached solve is valid until the content or the solve width changes.
    private(set) var cachedIntrinsicHeight: CGFloat?
    private(set) var cachedSolveWidth: CGFloat = -1

    override var intrinsicContentSize: NSSize {
        let width = bounds.width
        if let cached = cachedIntrinsicHeight, abs(cachedSolveWidth - width) <= 0.5 {
            return NSSize(width: NSView.noIntrinsicMetric, height: cached)
        }
        let height = stack.fittingSize.height
        cachedSolveWidth = width
        cachedIntrinsicHeight = max(0, height)
        return NSSize(width: NSView.noIntrinsicMetric, height: max(0, height))
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        stack.orientation = .vertical
        stack.alignment = .leading
        // Sections carry their source whitespace. A non-zero stack spacing
        // would synthesize characters at streaming boundaries.
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(document: MarkdownRenderDocument) {
        source = document.source
        let wanted = Set(document.sections.map(\.id))
        for id in sectionViews.keys.filter({ !wanted.contains($0) }) {
            sectionViews[id]?.removeFromSuperview()
            sectionViews[id] = nil
        }
        for section in document.sections {
            let existing = sectionViews[section.id]
            let view: NSView
            if let existing, isCompatible(existing, with: section) {
                view = existing
            } else {
                existing?.removeFromSuperview()
                view = makeView(for: section)
                sectionViews[section.id] = view
            }
            if !stack.arrangedSubviews.contains(where: { $0 === view }) { stack.addArrangedSubview(view) }
            update(view, with: section)
        }
        let ordered = document.sections.compactMap { sectionViews[$0.id] }
        if stack.arrangedSubviews.count != ordered.count
            || zip(stack.arrangedSubviews, ordered).contains(where: { $0 !== $1 }) {
            for view in stack.arrangedSubviews { stack.removeArrangedSubview(view) }
            for view in ordered { stack.addArrangedSubview(view) }
        }
        cachedIntrinsicHeight = nil
        invalidateIntrinsicContentSize()
    }

    func applyStreaming(sections: [MarkdownRenderSection], source: String) {
        apply(document: MarkdownRenderDocument(
            key: MarkdownRenderKey(messageID: UUID(), contentRevision: 0, themeRevision: DockThemeRuntime.revision),
            source: source,
            sections: sections
        ))
    }

    func reset() {
        for view in sectionViews.values { view.removeFromSuperview() }
        sectionViews.removeAll(keepingCapacity: true)
        stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0) }
        source = ""
        cachedIntrinsicHeight = nil
        invalidateIntrinsicContentSize()
    }

    @objc func copy(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(source, forType: .string)
    }

    private func makeView(for section: MarkdownRenderSection) -> NSView {
        switch section.kind {
        case .code: return NativeMarkdownCodeView()
        case .table: return NativeMarkdownTableView()
        default: return NativeMarkdownTextSectionView()
        }
    }

    private func isCompatible(_ view: NSView, with section: MarkdownRenderSection) -> Bool {
        switch (view, section.kind) {
        case (_ as NativeMarkdownCodeView, .code), (_ as NativeMarkdownTableView, .table),
             (_ as NativeMarkdownTextSectionView, .prose), (_ as NativeMarkdownTextSectionView, .heading),
             (_ as NativeMarkdownTextSectionView, .list), (_ as NativeMarkdownTextSectionView, .quote):
            return true
        default: return false
        }
    }

    private func update(_ view: NSView, with section: MarkdownRenderSection) {
        switch (view, section.kind) {
        case let (textView as NativeMarkdownTextSectionView, _):
            textView.update(markdown: section.source, kind: section.kind)
        case let (codeView as NativeMarkdownCodeView, .code(language)):
            codeView.update(code: section.source, language: language)
        case let (tableView as NativeMarkdownTableView, .table):
            tableView.update(markdown: section.source)
        default: break
        }
    }
}

@MainActor
final class NativeMarkdownTextSectionView: NSTextView {
    private var renderedMarkdown: String?
    private var renderedKind: MarkdownRenderSectionKind?

    init() {
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        let layout = NSLayoutManager()
        let storage = NSTextStorage()
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        super.init(frame: .zero, textContainer: container)
        isEditable = false
        isSelectable = true
        isRichText = true
        drawsBackground = false
        isVerticallyResizable = true
        isHorizontallyResizable = false
        textContainerInset = .zero
        textContainer?.widthTracksTextView = true
        textContainer?.lineFragmentPadding = 0
        linkTextAttributes = [.foregroundColor: NSColor(Color.dockAccent), .underlineStyle: NSUnderlineStyle.single.rawValue]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(markdown: String, kind: MarkdownRenderSectionKind) {
        guard renderedMarkdown != markdown || renderedKind != kind else { return }
        renderedMarkdown = markdown
        renderedKind = kind
        if case .code = kind {
            let attributed = NSAttributedString(string: markdown, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular),
                .foregroundColor: NSColor(Color.dockPrimaryText)
            ])
            if textStorage?.string != attributed.string || textStorage?.length != attributed.length {
                textStorage?.setAttributedString(attributed)
                invalidateIntrinsicContentSize()
            }
            return
        }
        let text: String
        switch kind {
        case .heading: text = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        case .list: text = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        case .quote: text = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        default: text = markdown
        }
        let parsed = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        var styled = MarkdownMessageView.linkAffordances(in: parsed)
        for run in styled.runs where run.link == nil { styled[run.range].foregroundColor = Color.dockPrimaryText }
        let attributed = NSAttributedString(styled)
        if textStorage?.string != attributed.string || textStorage?.length != attributed.length {
            textStorage?.setAttributedString(attributed)
            invalidateIntrinsicContentSize()
        }
    }

    override var intrinsicContentSize: NSSize {
        guard let textContainer, let layoutManager else { return NSSize(width: NSView.noIntrinsicMetric, height: 0) }
        layoutManager.ensureLayout(for: textContainer)
        return NSSize(width: NSView.noIntrinsicMetric, height: ceil(layoutManager.usedRect(for: textContainer).height))
    }
}

@MainActor
final class NativeMarkdownCodeView: NSScrollView {
    private let textView = NativeMarkdownTextSectionView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        drawsBackground = false
        hasHorizontalScroller = true
        hasVerticalScroller = false
        autohidesScrollers = true
        documentView = textView
        textView.isHorizontallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.minSize = .zero
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        let height = max(24, textView.intrinsicContentSize.height + 12)
        return NSSize(width: NSView.noIntrinsicMetric, height: height)
    }

    func update(code: String, language: String?) {
        let prefix = language.map { "\($0.uppercased())\n" } ?? ""
        let lines = code.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let body: String
        if !lines.isEmpty, MarkdownFence(opening: lines[0]) != nil {
            let end = lines.count > 1 && MarkdownFence(opening: lines[0])?.isClosed(by: lines[lines.count - 1]) == true
                ? lines.count - 1
                : lines.count
            body = lines.dropFirst().prefix(end - 1).joined(separator: "\n")
        } else {
            body = code
        }
        textView.update(markdown: prefix + body, kind: .code(language: language))
        if let textContainer = textView.textContainer, let layoutManager = textView.layoutManager {
            let contentWidth = layoutManager.usedRect(for: textContainer).width
            textView.frame.size.width = max(bounds.width, ceil(contentWidth) + 12)
        }
        invalidateIntrinsicContentSize()
    }
}

@MainActor
final class NativeMarkdownTableView: NSGridView {
    private var renderedMarkdown: String?

    func update(markdown: String) {
        guard renderedMarkdown != markdown else { return }
        renderedMarkdown = markdown
        subviews.forEach { $0.removeFromSuperview() }
        let rows = markdown.split(separator: "\n", omittingEmptySubsequences: true).filter { !$0.contains("---") }
        let cells = rows.map { row in
            row.split(separator: "|").map { value in
                let cell = NSTextField(labelWithString: String(value).trimmingCharacters(in: .whitespaces))
                cell.isSelectable = true
                cell.font = .systemFont(ofSize: 12.5)
                cell.textColor = NSColor(Color.dockPrimaryText)
                cell.lineBreakMode = .byWordWrapping
                cell.maximumNumberOfLines = 0
                cell.setAccessibilityRole(.staticText)
                return cell
            }
        }
        guard !cells.isEmpty else { return }
        let columns = cells.map(\.count).max() ?? 0
        let padded = cells.map { row in row + Array(repeating: NSTextField(labelWithString: ""), count: max(0, columns - row.count)) }
        let grid = NSGridView(views: padded)
        grid.rowSpacing = 4
        grid.columnSpacing = 12
        grid.translatesAutoresizingMaskIntoConstraints = false
        addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: trailingAnchor),
            grid.topAnchor.constraint(equalTo: topAnchor),
            grid.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
}
