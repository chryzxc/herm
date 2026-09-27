import AppKit
import SwiftUI

/// Identity for a completed render. The source text remains owned by
/// `ChatMessage`/`StreamingText`; this key only identifies a presentation
/// projection and its theme.
struct MarkdownRenderKey: Hashable, Sendable {
    let messageID: UUID
    let contentRevision: Int
    let themeRevision: Int
    /// Distinguishes markdown runs split around inline attachments in one message.
    var segment: Int = 0
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
        let cacheKey = "\(key.messageID.uuidString):\(key.contentRevision):\(key.themeRevision):\(key.segment)" as NSString
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

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: NativeMarkdownDocumentContainerView,
        context: Context
    ) -> CGSize? {
        NativeMarkdownDocumentSizing.size(for: proposal, view: nsView)
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

/// Answers SwiftUI's width proposal with the document's exact height at that
/// width. Without this, SwiftUI falls back to the NSView's intrinsic size,
/// which can only be computed at the view's previous width.
@MainActor
enum NativeMarkdownDocumentSizing {
    static let fallbackWidth: CGFloat = 600

    static func size(for proposal: ProposedViewSize, view: NativeMarkdownDocumentContainerView) -> CGSize {
        let width: CGFloat
        if let proposed = proposal.width, proposed.isFinite, proposed > 1 {
            width = proposed
        } else if view.bounds.width > 1 {
            width = view.bounds.width
        } else {
            width = fallbackWidth
        }
        return CGSize(width: width, height: view.measuredHeight(forWidth: width))
    }
}

enum MarkdownRenderDocumentBuilder {
    static func sections(for chunks: [StreamingPresentationChunk]) -> [MarkdownRenderSection] {
        var offset = 0
        var result: [MarkdownRenderSection] = []
        result.reserveCapacity(chunks.count)
        func append(id: Int, text: String, kind: MarkdownRenderSectionKind, continuation: MarkdownContinuationContext) {
            guard !text.isEmpty else { return }
            let start = offset
            offset += text.utf8.count
            result.append(MarkdownRenderSection(
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
                let continuation = MarkdownContinuationContext.fencedCode(marker: marker, length: length, language: language)
                if let split = closingSplit(of: chunk.text, fence: fence) {
                    // Promotion inside a fence can carry the closing fence and
                    // the prose after it; that prose must not render as code.
                    append(id: primaryID, text: split.code, kind: .code(language: language), continuation: continuation)
                    let remainder = classify(split.remainder)
                    append(id: remainderID, text: split.remainder, kind: remainder.kind, continuation: remainder.continuation)
                } else {
                    append(id: primaryID, text: chunk.text, kind: .code(language: language), continuation: continuation)
                }
            case .list(let marker, _):
                append(id: primaryID, text: chunk.text, kind: .list(marker: marker), continuation: chunkContext(chunk.context))
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

    private static func classify(_ text: String) -> (kind: MarkdownRenderSectionKind, continuation: MarkdownContinuationContext) {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
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

/// A native section that reports its exact height for a proposed width. The
/// document container lays sections out by frame instead of asking AutoLayout
/// to solve a stack of text views, so a long message costs one TextKit layout
/// per section per width rather than a constraint solve per layout query.
@MainActor
protocol NativeMarkdownMeasurableSection: NSView {
    func measuredHeight(forWidth width: CGFloat) -> CGFloat
}

/// Small memo of measured heights. SwiftUI probes a few widths during one
/// layout pass; TextKit relayout is paid only for a width not seen since the
/// content last changed.
struct NativeMarkdownHeightCache {
    private var entries: [(width: CGFloat, height: CGFloat)] = []

    func height(forWidth width: CGFloat) -> CGFloat? {
        entries.first { abs($0.width - width) <= 0.5 }?.height
    }

    mutating func store(_ height: CGFloat, forWidth width: CGFloat) {
        entries.removeAll { abs($0.width - width) <= 0.5 }
        entries.append((width, height))
        if entries.count > 4 { entries.removeFirst() }
    }

    mutating func removeAll() { entries.removeAll() }
}

@MainActor
final class NativeMarkdownDocumentContainerView: NSView {
    /// Matches the block spacing of the SwiftUI `MarkdownMessageView`, so a
    /// message crossing the native threshold keeps the same rhythm.
    static let sectionSpacing: CGFloat = 8

    private struct Entry {
        let id: Int
        let view: any NativeMarkdownMeasurableSection
        let spacingBefore: CGFloat
    }

    private var sectionViews: [Int: any NativeMarkdownMeasurableSection] = [:]
    private var entries: [Entry] = []
    private var source = ""
    // SwiftUI consults sizing on every layout pass while the row is mounted.
    // The solved frames stay valid until the content or the width changes.
    private(set) var cachedIntrinsicHeight: CGFloat?
    private(set) var cachedSolveWidth: CGFloat = -1
    private var cachedFrames: [CGRect] = []

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        let width = bounds.width
        guard width > 1 else {
            // Never lay out long text at a zero width: TextKit would wrap
            // every character onto its own line.
            return NSSize(width: NSView.noIntrinsicMetric, height: cachedIntrinsicHeight ?? 0)
        }
        return NSSize(width: NSView.noIntrinsicMetric, height: measuredHeight(forWidth: width))
    }

    func measuredHeight(forWidth proposedWidth: CGFloat) -> CGFloat {
        let width = max(1, proposedWidth)
        if let cached = cachedIntrinsicHeight, abs(cachedSolveWidth - width) <= 0.5 {
            return cached
        }
        var frames: [CGRect] = []
        frames.reserveCapacity(entries.count)
        var y: CGFloat = 0
        var hasVisibleSection = false
        for entry in entries {
            let height = entry.view.measuredHeight(forWidth: width)
            guard height > 0 else {
                frames.append(CGRect(x: 0, y: y, width: width, height: 0))
                continue
            }
            if hasVisibleSection { y += entry.spacingBefore }
            frames.append(CGRect(x: 0, y: y, width: width, height: height))
            y += height
            hasVisibleSection = true
        }
        let height = ceil(y)
        cachedSolveWidth = width
        cachedIntrinsicHeight = height
        cachedFrames = frames
        return height
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(frame.width - newSize.width) > 0.5
        super.setFrameSize(newSize)
        if widthChanged {
            needsLayout = true
            invalidateIntrinsicContentSize()
        }
    }

    override func layout() {
        super.layout()
        guard bounds.width > 1 else { return }
        _ = measuredHeight(forWidth: bounds.width)
        for (entry, frame) in zip(entries, cachedFrames) {
            let isEmpty = frame.height <= 0
            if entry.view.isHidden != isEmpty { entry.view.isHidden = isEmpty }
            if entry.view.frame != frame { entry.view.frame = frame }
        }
    }

    func apply(document: MarkdownRenderDocument) {
        source = document.source
        var retained: [Int: any NativeMarkdownMeasurableSection] = [:]
        var next: [Entry] = []
        next.reserveCapacity(document.sections.count)
        var previousSource: String?
        for section in document.sections {
            let view: any NativeMarkdownMeasurableSection
            if retained[section.id] == nil,
               let existing = sectionViews[section.id],
               Self.isCompatible(existing, with: section) {
                view = existing
            } else {
                view = Self.makeView(for: section)
                addSubview(view)
            }
            Self.update(view, with: section)
            retained[section.id] = view
            next.append(Entry(
                id: section.id,
                view: view,
                spacingBefore: previousSource.map { Self.spacing(after: $0, before: section) } ?? 0
            ))
            previousSource = section.source
        }
        let kept = Set(next.map { ObjectIdentifier($0.view) })
        for view in sectionViews.values where !kept.contains(ObjectIdentifier(view)) {
            view.removeFromSuperview()
        }
        sectionViews = retained
        entries = next
        cachedIntrinsicHeight = nil
        cachedSolveWidth = -1
        cachedFrames = []
        needsLayout = true
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
        entries.removeAll(keepingCapacity: true)
        source = ""
        cachedIntrinsicHeight = nil
        cachedSolveWidth = -1
        cachedFrames = []
        invalidateIntrinsicContentSize()
    }

    @objc func copy(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(source, forType: .string)
    }

    /// The opening section's code joined with the continuation sections that
    /// extend it, so Copy yields the whole block while it streams.
    func codeBlockText(startingAt codeView: NativeMarkdownCodeView) -> String {
        guard let index = entries.firstIndex(where: { $0.view === codeView }) else { return codeView.codeBody }
        var parts = [codeView.codeBody]
        for entry in entries[(index + 1)...] {
            guard let next = entry.view as? NativeMarkdownCodeView, !next.opensBlock else { break }
            parts.append(next.codeBody)
        }
        return parts.joined(separator: "\n")
    }

    /// Sections carry their source whitespace. A streaming section can end
    /// mid-paragraph; only a completed line boundary opens block spacing.
    private static func spacing(after previousSource: String, before section: MarkdownRenderSection) -> CGFloat {
        if case .code = section.kind,
           let firstLine = section.source.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first,
           MarkdownFence(opening: String(firstLine)) == nil {
            // A promoted code continuation extends the block above it.
            return 0
        }
        return previousSource.hasSuffix("\n") ? sectionSpacing : 0
    }

    private static func makeView(for section: MarkdownRenderSection) -> any NativeMarkdownMeasurableSection {
        if case .code = section.kind { return NativeMarkdownCodeView() }
        return NativeMarkdownTextSectionView()
    }

    private static func isCompatible(_ view: any NativeMarkdownMeasurableSection, with section: MarkdownRenderSection) -> Bool {
        if case .code = section.kind { return view is NativeMarkdownCodeView }
        return view is NativeMarkdownTextSectionView
    }

    private static func update(_ view: any NativeMarkdownMeasurableSection, with section: MarkdownRenderSection) {
        switch view {
        case let codeView as NativeMarkdownCodeView:
            if case .code(let language) = section.kind {
                codeView.update(code: section.source, language: language)
            }
        case let textView as NativeMarkdownTextSectionView:
            textView.update(markdown: section.source, kind: section.kind)
        default:
            break
        }
    }
}

/// Theme colors resolved once per section render instead of once per run.
@MainActor
struct NativeMarkdownPalette {
    let primary: NSColor
    let secondary: NSColor
    let metadata: NSColor
    let accent: NSColor
    let border: NSColor
    let surface: NSColor

    init() {
        primary = NSColor(Color.dockMarkdownText)
        secondary = NSColor(Color.dockSecondaryText)
        metadata = NSColor(Color.dockMetadataText)
        accent = NSColor(Color.dockAccent)
        border = NSColor(Color.dockBorder)
        surface = NSColor(Color.dockSurface4)
    }
}

/// Styled section text survives row eviction. Scrolling back through history
/// remounts rows; reusing their attributed strings leaves only TextKit layout
/// on the main thread instead of a full inline Markdown parse per section.
@MainActor
enum NativeMarkdownAttributedOutputCache {
    private final class Entry {
        let output: NativeMarkdownAttributedTextBuilder.Output
        init(_ output: NativeMarkdownAttributedTextBuilder.Output) { self.output = output }
    }

    private static let cache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.countLimit = 2_000
        cache.totalCostLimit = 48 * 1024 * 1024
        return cache
    }()

    static func output(
        markdown: String,
        kind: MarkdownRenderSectionKind,
        themeRevision: Int,
        build: () -> NativeMarkdownAttributedTextBuilder.Output
    ) -> NativeMarkdownAttributedTextBuilder.Output {
        let key = "\(themeRevision)|\(kind)|\(markdown)" as NSString
        if let entry = cache.object(forKey: key) { return entry.output }
        let output = build()
        cache.setObject(Entry(output), forKey: key, cost: max(1, markdown.utf8.count * 4))
        return output
    }
}

/// Builds the AppKit presentation of Markdown with the same block grammar and
/// typography as the SwiftUI `MarkdownMessageView`, so long (native) and short
/// (SwiftUI) messages read identically.
@MainActor
enum NativeMarkdownAttributedTextBuilder {
    struct Output {
        let string: NSAttributedString
        let quoteRanges: [NSRange]
    }

    static let bodySize: CGFloat = 14
    static let codeSize: CGFloat = 12.5
    static let tableSize: CGFloat = 12.5
    static let listIndent: CGFloat = 22
    static let quoteIndent: CGFloat = 12

    static func document(_ markdown: String, palette: NativeMarkdownPalette) -> Output {
        let blocks = MarkdownMessageView.renderBlocks(for: markdown)
        let result = NSMutableAttributedString()
        var quoteRanges: [NSRange] = []
        for (index, block) in blocks.enumerated() {
            let spacingBefore: CGFloat = index == 0 ? 0 : NativeMarkdownDocumentContainerView.sectionSpacing
            let start = result.length
            switch block {
            case .heading(let level, let text):
                let style = paragraphStyle(spacingBefore: index == 0 ? 0 : spacingBefore + 2)
                result.append(inline(text, font: .systemFont(ofSize: headingSize(level), weight: .semibold), color: palette.primary, palette: palette, style: style))
            case .paragraph(let text):
                let style = paragraphStyle(spacingBefore: spacingBefore, lineSpacing: 3)
                result.append(inline(text, font: .systemFont(ofSize: bodySize), color: palette.primary, palette: palette, style: style))
            case .listItem(let text, let marker):
                let style = paragraphStyle(spacingBefore: spacingBefore, lineSpacing: 3)
                style.headIndent = listIndent
                style.tabStops = [NSTextTab(textAlignment: .left, location: listIndent)]
                style.defaultTabInterval = listIndent
                result.append(NSAttributedString(string: "\(marker)\t", attributes: [
                    .font: NSFont.systemFont(ofSize: bodySize, weight: .medium),
                    .foregroundColor: palette.accent,
                    .paragraphStyle: style
                ]))
                result.append(inline(text, font: .systemFont(ofSize: bodySize), color: palette.primary, palette: palette, style: style))
            case .quote(let text):
                let style = paragraphStyle(spacingBefore: spacingBefore, lineSpacing: 3)
                style.headIndent = quoteIndent
                style.firstLineHeadIndent = quoteIndent
                result.append(inline(text, font: .systemFont(ofSize: bodySize), color: palette.secondary, palette: palette, style: style))
                quoteRanges.append(NSRange(location: start, length: result.length - start))
            case .code(let code, let language):
                result.append(codeBlock(code, language: language, spacingBefore: spacingBefore, palette: palette))
            case .tableRow(let columns):
                let style = paragraphStyle(spacingBefore: spacingBefore)
                for (column, value) in columns.enumerated() {
                    if column > 0 {
                        result.append(NSAttributedString(string: "  │  ", attributes: [
                            .font: NSFont.systemFont(ofSize: tableSize),
                            .foregroundColor: palette.metadata,
                            .paragraphStyle: style
                        ]))
                    }
                    result.append(inline(value, font: .systemFont(ofSize: tableSize), color: palette.primary, palette: palette, style: style))
                }
            }
            if index < blocks.count - 1 {
                let attributes = result.length > start
                    ? result.attributes(at: result.length - 1, effectiveRange: nil)
                    : [:]
                result.append(NSAttributedString(string: "\n", attributes: attributes))
            }
        }
        return Output(string: result, quoteRanges: quoteRanges)
    }

    static func code(_ code: String, palette: NativeMarkdownPalette) -> NSAttributedString {
        NSAttributedString(string: code, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: codeSize, weight: .regular),
            .foregroundColor: palette.primary
        ])
    }

    static func isPureTable(_ markdown: String) -> Bool {
        var sawRow = false
        for line in markdown.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            guard trimmed.hasPrefix("|"), trimmed.hasSuffix("|") else { return false }
            sawRow = true
        }
        return sawRow
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
        !cells.isEmpty && cells.allSatisfy { cell in
            cell.contains("-") && cell.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }

    static func table(_ markdown: String, palette: NativeMarkdownPalette) -> Output {
        var rows: [[String]] = []
        var hasHeader = false
        for line in markdown.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let cells = tableCells(trimmed)
            if isSeparatorRow(cells) {
                if rows.count == 1 { hasHeader = true }
                continue
            }
            rows.append(cells)
        }
        guard !rows.isEmpty else { return Output(string: NSAttributedString(), quoteRanges: []) }
        let columns = max(1, rows.map(\.count).max() ?? 1)
        let table = NSTextTable()
        table.numberOfColumns = columns
        table.layoutAlgorithm = .automaticLayoutAlgorithm
        table.collapsesBorders = true
        table.hidesEmptyCells = false
        table.setContentWidth(100, type: .percentageValueType)
        let result = NSMutableAttributedString()
        for (rowIndex, row) in rows.enumerated() {
            let isHeader = hasHeader && rowIndex == 0
            for column in 0..<columns {
                let block = NSTextTableBlock(table: table, startingRow: rowIndex, rowSpan: 1, startingColumn: column, columnSpan: 1)
                block.setWidth(4, type: .absoluteValueType, for: .padding, edge: .minY)
                block.setWidth(4, type: .absoluteValueType, for: .padding, edge: .maxY)
                block.setWidth(8, type: .absoluteValueType, for: .padding, edge: .minX)
                block.setWidth(8, type: .absoluteValueType, for: .padding, edge: .maxX)
                block.setWidth(0.5, type: .absoluteValueType, for: .border, edge: .maxY)
                block.setBorderColor(palette.border)
                if isHeader { block.backgroundColor = palette.surface }
                let style = NSMutableParagraphStyle()
                style.textBlocks = [block]
                let value = column < row.count ? row[column] : ""
                let font: NSFont = isHeader
                    ? .systemFont(ofSize: tableSize, weight: .semibold)
                    : .systemFont(ofSize: tableSize)
                // An empty cell still needs one character to own its block.
                let parsed = value.isEmpty ? AttributedString(" ") : inlineMarkdown(value)
                let cell = NSMutableAttributedString(attributedString: inline(parsed, font: font, color: palette.primary, palette: palette, style: style))
                cell.append(NSAttributedString(string: "\n", attributes: [.font: font, .paragraphStyle: style]))
                result.append(cell)
            }
        }
        // The final paragraph terminates at the end of the text; a trailing
        // newline would add an empty line fragment below the table.
        if result.length > 0 { result.deleteCharacters(in: NSRange(location: result.length - 1, length: 1)) }
        return Output(string: result, quoteRanges: [])
    }

    /// Markdown here includes agent output and third-party GitHub PR/issue
    /// bodies, so a link like `file:///…/Evil.app` or a custom app scheme must
    /// never become clickable. Unsafe links keep their text, lose the link.
    static let safeLinkSchemes: Set<String> = ["http", "https", "mailto"]

    static func inlineMarkdown(_ value: String) -> AttributedString {
        var parsed = (try? AttributedString(
            markdown: value,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(value)
        for run in parsed.runs {
            guard let link = run.link else { continue }
            if !safeLinkSchemes.contains(link.scheme?.lowercased() ?? "") {
                parsed[run.range].link = nil
            }
        }
        return parsed
    }

    /// Converts Foundation inline presentation intents to AppKit fonts. An
    /// `AttributedString` carries bold/italic/code as intents, which NSTextView
    /// does not render on its own.
    static func inline(
        _ value: AttributedString,
        font baseFont: NSFont,
        color: NSColor,
        palette: NativeMarkdownPalette,
        style: NSParagraphStyle
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for run in value.runs {
            let text = String(value[run.range].characters)
            guard !text.isEmpty else { continue }
            let intent = run.inlinePresentationIntent ?? []
            var font = baseFont
            if intent.contains(.code) {
                font = .monospacedSystemFont(ofSize: baseFont.pointSize - 1, weight: .regular)
            }
            var traits = font.fontDescriptor.symbolicTraits
            if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
            if intent.contains(.emphasized) { traits.insert(.italic) }
            if traits != font.fontDescriptor.symbolicTraits {
                font = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(traits), size: font.pointSize) ?? font
            }
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: style
            ]
            if intent.contains(.strikethrough) {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if intent.contains(.code) {
                attributes[.backgroundColor] = palette.surface
            }
            if let link = run.link {
                attributes[.link] = link
                attributes[.foregroundColor] = palette.accent
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            result.append(NSAttributedString(string: text, attributes: attributes))
        }
        return result
    }

    private static func codeBlock(
        _ code: String,
        language: String?,
        spacingBefore: CGFloat,
        palette: NativeMarkdownPalette
    ) -> NSAttributedString {
        let block = NSTextBlock()
        block.backgroundColor = palette.surface
        block.setBorderColor(palette.border)
        block.setWidth(0.5, type: .absoluteValueType, for: .border)
        block.setWidth(8, type: .absoluteValueType, for: .padding, edge: .minX)
        block.setWidth(8, type: .absoluteValueType, for: .padding, edge: .maxX)
        block.setWidth(6, type: .absoluteValueType, for: .padding, edge: .minY)
        block.setWidth(6, type: .absoluteValueType, for: .padding, edge: .maxY)
        block.setWidth(spacingBefore, type: .absoluteValueType, for: .margin, edge: .minY)
        let style = NSMutableParagraphStyle()
        style.textBlocks = [block]
        let result = NSMutableAttributedString()
        if let language, !language.isEmpty {
            result.append(NSAttributedString(string: language.uppercased() + "\n", attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
                .foregroundColor: palette.secondary,
                .paragraphStyle: style
            ]))
        }
        result.append(NSAttributedString(string: code.isEmpty ? " " : code, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: codeSize, weight: .regular),
            .foregroundColor: palette.primary,
            .paragraphStyle: style
        ]))
        return result
    }

    private static func paragraphStyle(spacingBefore: CGFloat, lineSpacing: CGFloat = 0) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = spacingBefore
        style.lineSpacing = lineSpacing
        return style
    }

    private static func headingSize(_ level: Int) -> CGFloat {
        level == 1 ? 18 : level == 2 ? 16 : level == 3 ? 14.5 : 14
    }
}

@MainActor
final class NativeMarkdownTextSectionView: NSTextView, NativeMarkdownMeasurableSection {
    private var renderedMarkdown: String?
    private var renderedKind: MarkdownRenderSectionKind?
    private var renderedThemeRevision: Int?
    private var heights = NativeMarkdownHeightCache()
    private var quoteRanges: [NSRange] = []
    private var quoteBarColor: NSColor = .separatorColor
    /// Code presentation keeps its natural line width and scrolls
    /// horizontally inside `NativeMarkdownCodeView`.
    var wrapsToWidth = true

    init() {
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        // Width is assigned explicitly per measurement. Tracking the view
        // width would relayout the text for every SwiftUI probe.
        container.widthTracksTextView = false
        container.lineFragmentPadding = 0
        let layout = NSLayoutManager()
        let storage = NSTextStorage()
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        super.init(frame: .zero, textContainer: container)
        isEditable = false
        isSelectable = true
        isRichText = true
        drawsBackground = false
        isVerticallyResizable = false
        isHorizontallyResizable = false
        textContainerInset = .zero
        allowsUndo = false
        isAutomaticSpellingCorrectionEnabled = false
        isAutomaticTextCompletionEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(markdown: String, kind: MarkdownRenderSectionKind) {
        // A theme change keeps the same markdown but changes every color, so
        // the rendered theme revision is part of what makes the text current.
        let themeRevision = DockThemeRuntime.revision
        guard renderedMarkdown != markdown || renderedKind != kind || renderedThemeRevision != themeRevision else { return }
        renderedMarkdown = markdown
        renderedKind = kind
        renderedThemeRevision = themeRevision
        let palette = NativeMarkdownPalette()
        linkTextAttributes = [.foregroundColor: palette.accent, .underlineStyle: NSUnderlineStyle.single.rawValue]
        quoteBarColor = palette.border
        let output = NativeMarkdownAttributedOutputCache.output(
            markdown: markdown,
            kind: kind,
            themeRevision: themeRevision
        ) {
            switch kind {
            case .code:
                return .init(string: NativeMarkdownAttributedTextBuilder.code(markdown, palette: palette), quoteRanges: [])
            case .table where NativeMarkdownAttributedTextBuilder.isPureTable(markdown):
                return NativeMarkdownAttributedTextBuilder.table(markdown, palette: palette)
            default:
                return NativeMarkdownAttributedTextBuilder.document(markdown, palette: palette)
            }
        }
        quoteRanges = output.quoteRanges
        textStorage?.setAttributedString(output.string)
        heights.removeAll()
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    func measuredHeight(forWidth width: CGFloat) -> CGFloat {
        if let cached = heights.height(forWidth: width) { return cached }
        guard let textContainer, let layoutManager, (textStorage?.length ?? 0) > 0 else {
            heights.store(0, forWidth: width)
            return 0
        }
        if wrapsToWidth { setContainerWidth(width) }
        layoutManager.ensureLayout(for: textContainer)
        let height = ceil(layoutManager.usedRect(for: textContainer).height)
        heights.store(height, forWidth: width)
        return height
    }

    /// The unwrapped text extent, used by horizontally scrolling code.
    func naturalContentSize() -> NSSize {
        guard let textContainer, let layoutManager, (textStorage?.length ?? 0) > 0 else { return .zero }
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        return NSSize(width: ceil(used.width), height: ceil(used.height))
    }

    override var intrinsicContentSize: NSSize {
        guard bounds.width > 1 else { return NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
        return NSSize(width: NSView.noIntrinsicMetric, height: measuredHeight(forWidth: bounds.width))
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if wrapsToWidth, newSize.width > 1 { setContainerWidth(newSize.width) }
    }

    override func draw(_ dirtyRect: NSRect) {
        if !quoteRanges.isEmpty, let layoutManager, let textContainer {
            quoteBarColor.setFill()
            let origin = textContainerOrigin
            for range in quoteRanges {
                let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
                NSRect(x: origin.x, y: rect.minY + origin.y, width: 2, height: rect.height).fill()
            }
        }
        super.draw(dirtyRect)
    }

    private func setContainerWidth(_ width: CGFloat) {
        guard let textContainer, abs(textContainer.containerSize.width - width) > 0.5 else { return }
        textContainer.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
    }
}

/// Code keeps its line structure and scrolls horizontally. Vertical wheel
/// gestures always belong to the transcript, so a pointer resting on a code
/// block never stalls conversation scrolling.
@MainActor
final class NativeMarkdownHorizontalScrollView: NSScrollView {
    private var forwardsCurrentGesture = false

    override func scrollWheel(with event: NSEvent) {
        let beginsGesture = event.phase.contains(.began) || event.phase.contains(.mayBegin)
        let isDiscreteWheel = event.phase.isEmpty && event.momentumPhase.isEmpty
        if beginsGesture || isDiscreteWheel {
            let canScrollHorizontally = (documentView?.frame.width ?? 0) > contentSize.width + 0.5
            forwardsCurrentGesture = !canScrollHorizontally
                || abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX)
        }
        if forwardsCurrentGesture {
            nextResponder?.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

@MainActor
final class NativeMarkdownCodeView: NSView, NativeMarkdownMeasurableSection {
    private static let horizontalPadding: CGFloat = 10
    private static let verticalPadding: CGFloat = 8
    private static let headerRowHeight: CGFloat = 28
    private static let labelFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    private static let copyFont = NSFont.systemFont(ofSize: 12, weight: .medium)

    private let languageLabel = NSTextField(labelWithString: "")
    private let copyButton = NSButton(title: "Copy", target: nil, action: nil)
    private let headerDivider = NSView()
    private let scrollView = NativeMarkdownHorizontalScrollView()
    private let textView = NativeMarkdownTextSectionView()
    private var renderedCode: String?
    private var renderedLanguage: String?
    private var renderedThemeRevision: Int?
    private var contentSize: NSSize = .zero
    private var copyResetTask: Task<Void, Never>?
    /// Code without its fences, used when the block is copied.
    private(set) var codeBody = ""
    /// False for a streaming continuation of a block opened by an earlier section.
    private(set) var opensBlock = false

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0.5
        layer?.masksToBounds = true
        languageLabel.font = Self.labelFont
        languageLabel.lineBreakMode = .byTruncatingTail
        copyButton.isBordered = false
        copyButton.bezelStyle = .inline
        copyButton.font = Self.copyFont
        copyButton.target = self
        copyButton.action = #selector(copyCode(_:))
        copyButton.toolTip = "Copy code"
        copyButton.setAccessibilityLabel("Copy code")
        headerDivider.wantsLayer = true
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.verticalScrollElasticity = .none
        textView.wrapsToWidth = false
        textView.textContainerInset = NSSize(width: Self.horizontalPadding, height: Self.verticalPadding)
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scrollView.documentView = textView
        addSubview(languageLabel)
        addSubview(copyButton)
        addSubview(headerDivider)
        addSubview(scrollView)
        setHeaderHidden(true)
    }

    convenience init() { self.init(frame: .zero) }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { copyResetTask?.cancel() }

    private var headerHeight: CGFloat {
        opensBlock ? Self.headerRowHeight : 0
    }

    private func setHeaderHidden(_ hidden: Bool) {
        languageLabel.isHidden = hidden
        copyButton.isHidden = hidden
        headerDivider.isHidden = hidden
    }

    func measuredHeight(forWidth width: CGFloat) -> CGFloat {
        // Code does not wrap, so its height is independent of the width.
        ceil(max(24, headerHeight + contentSize.height + Self.verticalPadding * 2))
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: measuredHeight(forWidth: bounds.width))
    }

    override func layout() {
        super.layout()
        let header = headerHeight
        if opensBlock {
            let buttonSize = copyButton.intrinsicContentSize
            let buttonWidth = ceil(buttonSize.width) + 12
            copyButton.frame = NSRect(
                x: max(0, bounds.width - buttonWidth - 4),
                y: 0,
                width: buttonWidth,
                height: header
            )
            let labelHeight = ceil(Self.labelFont.ascender - Self.labelFont.descender)
            languageLabel.frame = NSRect(
                x: Self.horizontalPadding,
                y: floor((header - labelHeight) / 2),
                width: max(0, copyButton.frame.minX - Self.horizontalPadding - 8),
                height: labelHeight
            )
            headerDivider.frame = NSRect(x: 0, y: header - 0.5, width: bounds.width, height: 0.5)
        }
        let scrollFrame = NSRect(x: 0, y: header, width: bounds.width, height: max(0, bounds.height - header))
        if scrollView.frame != scrollFrame { scrollView.frame = scrollFrame }
        let documentFrame = NSRect(
            x: 0,
            y: 0,
            width: max(scrollFrame.width, contentSize.width + Self.horizontalPadding * 2),
            height: contentSize.height + Self.verticalPadding * 2
        )
        if textView.frame != documentFrame { textView.frame = documentFrame }
    }

    private static func isBareFence(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let marker = trimmed.first, marker == "`" || marker == "~", trimmed.count >= 3 else { return false }
        return trimmed.allSatisfy { $0 == marker }
    }

    @objc private func copyCode(_ sender: Any?) {
        // A streamed block can span several sections; copy the whole block.
        let text = (superview as? NativeMarkdownDocumentContainerView)?.codeBlockText(startingAt: self) ?? codeBody
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        setCopyTitle("Copied")
        copyResetTask?.cancel()
        copyResetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            self?.setCopyTitle("Copy")
        }
    }

    private func setCopyTitle(_ title: String) {
        copyButton.attributedTitle = NSAttributedString(
            string: title,
            attributes: [.font: Self.copyFont, .foregroundColor: NativeMarkdownPalette().secondary]
        )
        needsLayout = true
    }

    func update(code: String, language: String?) {
        let themeRevision = DockThemeRuntime.revision
        guard renderedCode != code || renderedLanguage != language || renderedThemeRevision != themeRevision else { return }
        renderedCode = code
        renderedLanguage = language
        renderedThemeRevision = themeRevision
        let palette = NativeMarkdownPalette()
        layer?.backgroundColor = palette.surface.cgColor
        layer?.borderColor = palette.border.cgColor
        headerDivider.layer?.backgroundColor = palette.border.cgColor
        languageLabel.textColor = palette.metadata
        setCopyTitle("Copy")
        let lines = code.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var start = 0
        var end = lines.count
        while end > start, lines[end - 1].trimmingCharacters(in: .whitespaces).isEmpty { end -= 1 }
        // A streaming continuation has no opening fence; its header already
        // appeared on the section that opened the block.
        var opensBlock = false
        if end > start, let fence = MarkdownFence(opening: lines[start]) {
            opensBlock = true
            start += 1
            if end > start, fence.isClosed(by: lines[end - 1]) { end -= 1 }
        } else if end > start, Self.isBareFence(lines[end - 1]) {
            end -= 1
        }
        let body = start < end ? lines[start..<end].joined(separator: "\n") : ""
        self.opensBlock = opensBlock
        codeBody = body
        languageLabel.stringValue = opensBlock ? (language ?? "").lowercased() : ""
        setHeaderHidden(!opensBlock)
        textView.update(markdown: body, kind: .code(language: language))
        contentSize = textView.naturalContentSize()
        needsLayout = true
        invalidateIntrinsicContentSize()
    }
}
