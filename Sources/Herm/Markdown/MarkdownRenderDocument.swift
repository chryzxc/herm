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

enum MarkdownRenderSectionKind: Hashable, Sendable {
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

    private(set) static var parseCount = 0
    private(set) static var prefetchedDocuments = 0

    private static func cacheKey(_ key: MarkdownRenderKey) -> NSString {
        "\(key.messageID.uuidString):\(key.contentRevision):\(key.themeRevision):\(key.segment)" as NSString
    }

    static func cached(source: String, key: MarkdownRenderKey) -> MarkdownRenderDocument? {
        guard let entry = cache.object(forKey: cacheKey(key)), entry.document.source == source else { return nil }
        return entry.document
    }

    static func insert(_ document: MarkdownRenderDocument, prefetched: Bool = false) {
        if prefetched { prefetchedDocuments += 1 }
        cache.setObject(Entry(document), forKey: cacheKey(document.key), cost: max(document.cost, 1))
    }

    static func document(for source: String, key: MarkdownRenderKey, cacheResult: Bool = true) -> MarkdownRenderDocument
    {
        if cacheResult, let document = cached(source: source, key: key) {
            DebugLog.writePerformance("markdown_document_cache_hit bytes=\(source.utf8.count)")
            return document
        }
        DebugLog.writePerformance("markdown_document_cache_miss bytes=\(source.utf8.count)")
        let started = DispatchTime.now().uptimeNanoseconds
        parseCount += 1
        let document = MarkdownRenderDocumentBuilder.build(source: source, key: key)
        if cacheResult { insert(document) }
        let duration = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        DebugLog.writePerformance(
            "markdown_document_parse bytes=\(source.utf8.count) sections=\(document.sections.count) duration_ms=\(String(format: "%.2f", duration))"
        )
        return document
    }
}

/// Persistent AppKit host for a long message. SwiftUI owns the row and the
/// transcript scroll view; this host owns only the block projections and their
/// intrinsic measurement. A coordinator keeps the same container alive while
/// the source revision changes (including the streaming-to-completed handoff).
@MainActor
struct NativeMarkdownDocumentHost: NSViewRepresentable, Equatable {
    @Environment(\.dockWorkspaceScale) private var workspaceScale
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.accessibilitySwitchControlEnabled) private var switchControlEnabled
    let source: String
    let key: MarkdownRenderKey
    let streamingSections: [MarkdownRenderSection]?
    let cacheResult: Bool
    var bodySize: CGFloat = DockTypography.size(.conversation)
    var bodyWeight: NSFont.Weight = .regular

    init(
        source: String, key: MarkdownRenderKey, streamingSections: [MarkdownRenderSection]? = nil,
        bodySize: CGFloat = DockTypography.size(.conversation), bodyWeight: NSFont.Weight = .regular,
        cacheResult: Bool = true
    ) {
        self.cacheResult = cacheResult
        self.source = source
        self.key = key
        self.streamingSections = streamingSections
        self.bodySize = bodySize
        self.bodyWeight = bodyWeight
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.source == rhs.source && lhs.key == rhs.key && lhs.streamingSections == rhs.streamingSections
            && lhs.bodySize == rhs.bodySize && lhs.bodyWeight == rhs.bodyWeight && lhs.cacheResult == rhs.cacheResult
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NativeMarkdownDocumentContainerView {
        let view = NativeMarkdownDocumentContainerView()
        view.markdownOpenURL = context.environment.markdownOpenURL
        view.keepsAccessibilitySectionsMounted = voiceOverEnabled || switchControlEnabled
        view.setBodyStyle(size: DockWorkspaceScale.points(bodySize, scale: workspaceScale), weight: bodyWeight)
        context.coordinator.update(
            view, source: source, key: key, sections: streamingSections, cacheResult: cacheResult)
        return view
    }

    func updateNSView(_ nsView: NativeMarkdownDocumentContainerView, context: Context) {
        nsView.markdownOpenURL = context.environment.markdownOpenURL
        nsView.keepsAccessibilitySectionsMounted = voiceOverEnabled || switchControlEnabled
        nsView.setBodyStyle(size: DockWorkspaceScale.points(bodySize, scale: workspaceScale), weight: bodyWeight)
        context.coordinator.update(
            nsView, source: source, key: key, sections: streamingSections, cacheResult: cacheResult)
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
        private var renderedMentionRevision = -1
        private var renderedCacheResult: Bool?

        func update(
            _ view: NativeMarkdownDocumentContainerView,
            source: String,
            key: MarkdownRenderKey,
            sections: [MarkdownRenderSection]?, cacheResult: Bool = true
        ) {
            if let sections {
                view.applyStreaming(sections: sections, source: source)
                renderedCacheResult = nil
                renderedKey = key
                renderedSource = source
                return
            }
            guard
                renderedKey != key || renderedSource != source || renderedMentionRevision != BotMentions.revision
                    || renderedCacheResult != cacheResult
            else { return }
            let started = DispatchTime.now().uptimeNanoseconds
            let document = MarkdownRenderDocumentCache.document(for: source, key: key, cacheResult: cacheResult)
            if cacheResult {
                view.apply(document: document)
            } else {
                view.applyStreaming(sections: document.sections, source: source)
            }
            renderedCacheResult = cacheResult
            renderedKey = key
            renderedSource = source
            renderedMentionRevision = BotMentions.revision
            let duration = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            DebugLog.writePerformance(
                "markdown_native_host_update sections=\(document.sections.count) duration_ms=\(String(format: "%.2f", duration))"
            )
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
        entries.first { $0.width == width }?.height
    }

    mutating func store(_ height: CGFloat, forWidth width: CGFloat) {
        entries.removeAll { $0.width == width }
        entries.append((width, height))
        if entries.count > 4 { entries.removeFirst() }
    }

    mutating func removeAll() { entries.removeAll() }
}

@MainActor
final class NativeMarkdownDocumentContainerView: NSView, MarkdownLinkHost {
    var markdownOpenURL = OpenURLAction {
        InAppBrowser.open($0)
        return .handled
    }
    /// Matches the block spacing of the SwiftUI `MarkdownMessageView`, so a
    /// message crossing the native threshold keeps the same rhythm.
    static let sectionSpacing: CGFloat = 8

    private final class Entry {
        let section: MarkdownRenderSection
        var view: (any NativeMarkdownMeasurableSection)?
        var spacingBefore: CGFloat
        var heights = NativeMarkdownHeightCache()

        init(section: MarkdownRenderSection, view: (any NativeMarkdownMeasurableSection)?, spacingBefore: CGFloat) {
            self.section = section
            self.view = view
            self.spacingBefore = spacingBefore
        }
    }

    private lazy var textMeasurer = NativeMarkdownTextSectionView()
    private lazy var codeMeasurer = NativeMarkdownCodeView()
    private var entries: [Entry] = []
    var instantiatedSectionCount: Int { entries.filter { $0.view != nil }.count }
    private var source = ""
    private var renderedSections: [MarkdownRenderSection] = []
    private var isStreamingDocument = false
    private(set) var sectionMeasurementCount = 0
    private var renderedThemeRevision = -1
    private var renderedMentionRevision = -1
    // SwiftUI consults sizing on every layout pass while the row is mounted.
    // The solved frames stay valid until the content or the width changes.
    private(set) var cachedIntrinsicHeight: CGFloat?
    private(set) var cachedSolveWidth: CGFloat = -1
    private var cachedFrames: [CGRect] = []
    private weak var observedClipView: NSClipView?
    nonisolated(unsafe) private var viewportObservers: [NSObjectProtocol] = []
    var keepsAccessibilitySectionsMounted = false {
        didSet {
            if oldValue != keepsAccessibilitySectionsMounted { needsLayout = true }
        }
    }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeViewport()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        observeViewport()
    }

    private func observeViewport() {
        let clip = window == nil ? nil : enclosingScrollView?.contentView
        for observer in viewportObservers { NotificationCenter.default.removeObserver(observer) }
        viewportObservers.removeAll()
        observedClipView = clip
        if let clip {
            // A preceding row can move this message into view without scrolling.
            var ancestor: NSView? = self
            while let view = ancestor {
                view.postsBoundsChangedNotifications = true
                view.postsFrameChangedNotifications = true
                for name in [NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification] {
                    viewportObservers.append(
                        NotificationCenter.default.addObserver(
                            forName: name, object: view, queue: .main
                        ) { [weak self] _ in
                            MainActor.assumeIsolated { self?.updateMountedSections() }
                        })
                }
                if view === clip { break }
                ancestor = view.superview
            }
        }
        needsLayout = true
    }

    deinit {
        for observer in viewportObservers { NotificationCenter.default.removeObserver(observer) }
    }

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
        if let cached = cachedIntrinsicHeight, cachedSolveWidth == width {
            return cached
        }
        var frames: [CGRect] = []
        frames.reserveCapacity(entries.count)
        var y: CGFloat = 0
        var hasVisibleSection = false
        for entry in entries {
            let height: CGFloat
            let sharedKey = NativeMarkdownCompletedHeightCache.Key(
                source: entry.section.source, kind: entry.section.kind, width: width,
                bodySize: bodySize, bodyWeight: bodyWeight.rawValue,
                themeRevision: DockThemeRuntime.revision, mentionRevision: BotMentions.revision,
                themeID: DockThemeRuntime.current)
            if let cached = entry.heights.height(forWidth: width) {
                height = cached
            } else if !isStreamingDocument, let cached = NativeMarkdownCompletedHeightCache.height(for: sharedKey) {
                height = cached
                entry.heights.store(height, forWidth: width)
            } else {
                let measuringView: any NativeMarkdownMeasurableSection
                if let view = entry.view {
                    measuringView = view
                } else if case .code = entry.section.kind {
                    measuringView = codeMeasurer
                } else {
                    measuringView = textMeasurer
                }
                Self.update(measuringView, with: entry.section, bodySize: bodySize, bodyWeight: bodyWeight)
                height = measuringView.measuredHeight(forWidth: width)
                sectionMeasurementCount += 1
                entry.heights.store(height, forWidth: width)
                if !isStreamingDocument { NativeMarkdownCompletedHeightCache.store(height, for: sharedKey) }
            }
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
        let widthChanged = frame.width != newSize.width
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
        updateMountedSections()
    }

    private func updateMountedSections() {
        guard entries.count == cachedFrames.count,
            window != nil || keepsAccessibilitySectionsMounted
        else { return }
        let visible = visibleRect
        // Keep a viewport of buffer without making offscreen text views take
        // part in every AppKit layout, hit-test, and cursor-rect update.
        let viewport: NSRect? = observedClipView.map { clip in
            visible.isEmpty ? .zero : visible.insetBy(dx: 0, dy: -clip.bounds.height)
        }
        let keepAll = keepsAccessibilitySectionsMounted || NSApp?.isFullKeyboardAccessEnabled == true
        let focused = window?.firstResponder as? NSView
        var nextMounted: NSView?
        for (entry, frame) in zip(entries, cachedFrames).reversed() {
            let containsFocus =
                entry.view.flatMap { view in
                    focused.map { $0 === view || $0.isDescendant(of: view) }
                } ?? false
            let shouldMount = keepAll || containsFocus || (viewport.map { frame.intersects($0) } ?? true)
            guard shouldMount else {
                entry.view?.removeFromSuperview()
                continue
            }
            let view: any NativeMarkdownMeasurableSection
            if let existing = entry.view {
                view = existing
            } else {
                view = Self.makeView(for: entry.section)
                Self.update(view, with: entry.section, bodySize: bodySize, bodyWeight: bodyWeight)
                entry.view = view
            }
            if view.superview !== self {
                if let nextMounted {
                    addSubview(view, positioned: .below, relativeTo: nextMounted)
                } else {
                    addSubview(view)
                }
            }
            nextMounted = view
            let isEmpty = frame.height <= 0
            if view.isHidden != isEmpty { view.isHidden = isEmpty }
            if view.frame != frame { view.frame = frame }
        }
    }

    private var bodySize: CGFloat = DockTypography.size(.conversation)
    private var bodyWeight: NSFont.Weight = .regular
    func setBodyStyle(size: CGFloat, weight: NSFont.Weight) {
        guard bodySize != size || bodyWeight != weight else { return }
        bodySize = size
        bodyWeight = weight
        renderedThemeRevision = -1
        applyProjection(
            MarkdownRenderDocument(
                key: MarkdownRenderKey(messageID: UUID(), contentRevision: 0, themeRevision: DockThemeRuntime.revision),
                source: source, sections: renderedSections))
    }

    func apply(document: MarkdownRenderDocument) {
        isStreamingDocument = false
        applyProjection(document)
    }

    private func applyProjection(_ document: MarkdownRenderDocument) {
        source = document.source
        let themeRevision = DockThemeRuntime.revision
        let mentionRevision = BotMentions.revision
        guard
            renderedSections != document.sections || renderedThemeRevision != themeRevision
                || renderedMentionRevision != mentionRevision
        else { return }
        let canReuseHeights = renderedThemeRevision == themeRevision && renderedMentionRevision == mentionRevision
        renderedSections = document.sections
        renderedThemeRevision = themeRevision
        renderedMentionRevision = mentionRevision
        var previous = Dictionary(entries.map { ($0.section.id, $0) }, uniquingKeysWith: { first, _ in first })
        var next: [Entry] = []
        next.reserveCapacity(document.sections.count)
        var previousSource: String?
        for section in document.sections {
            let existing = previous.removeValue(forKey: section.id)
            let spacing = previousSource.map { Self.spacing(after: $0, before: section) } ?? 0
            let entry: Entry
            if let existing, canReuseHeights, existing.section == section {
                entry = existing
                entry.spacingBefore = spacing
            } else {
                let view = existing?.view.flatMap { Self.isCompatible($0, with: section) ? $0 : nil }
                if let view { Self.update(view, with: section, bodySize: bodySize, bodyWeight: bodyWeight) }
                entry = Entry(section: section, view: view, spacingBefore: spacing)
            }
            next.append(entry)
            previousSource = section.source
        }
        let kept = Set(next.compactMap { $0.view.map(ObjectIdentifier.init) })
        for entry in entries {
            if let view = entry.view, !kept.contains(ObjectIdentifier(view)) { view.removeFromSuperview() }
        }
        entries = next
        cachedIntrinsicHeight = nil
        cachedSolveWidth = -1
        cachedFrames = []
        needsLayout = true
        invalidateIntrinsicContentSize()
    }

    func applyStreaming(sections: [MarkdownRenderSection], source: String) {
        isStreamingDocument = true
        applyProjection(
            MarkdownRenderDocument(
                key: MarkdownRenderKey(messageID: UUID(), contentRevision: 0, themeRevision: DockThemeRuntime.revision),
                source: source,
                sections: sections
            ))
    }

    func reset() {
        for entry in entries { entry.view?.removeFromSuperview() }
        entries.removeAll(keepingCapacity: true)
        source = ""
        renderedSections = []
        renderedThemeRevision = -1
        renderedMentionRevision = -1
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
        var code = entries[index].section.source
        for entry in entries[(index + 1)...] {
            guard case .code = entry.section.kind else { break }
            let next = NativeMarkdownCodeView.parsedCode(entry.section.source)
            guard !next.opensBlock else { break }
            code.append(entry.section.source)
        }
        return NativeMarkdownCodeView.parsedCode(code).body
    }

    /// Sections carry their source whitespace. A streaming section can end
    /// mid-paragraph; only a completed line boundary opens block spacing.
    private static func spacing(after previousSource: String, before section: MarkdownRenderSection) -> CGFloat {
        if case .code = section.kind,
            let firstLine = section.source.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first,
            MarkdownFence(opening: String(firstLine)) == nil
        {
            // A promoted code continuation extends the block above it.
            return 0
        }
        return previousSource.hasSuffix("\n") ? sectionSpacing : 0
    }

    private static func makeView(for section: MarkdownRenderSection) -> any NativeMarkdownMeasurableSection {
        if case .code = section.kind { return NativeMarkdownCodeView() }
        return NativeMarkdownTextSectionView()
    }

    private static func isCompatible(_ view: any NativeMarkdownMeasurableSection, with section: MarkdownRenderSection)
        -> Bool
    {
        if case .code = section.kind { return view is NativeMarkdownCodeView }
        return view is NativeMarkdownTextSectionView
    }

    private static func update(
        _ view: any NativeMarkdownMeasurableSection, with section: MarkdownRenderSection, bodySize: CGFloat,
        bodyWeight: NSFont.Weight
    ) {
        switch view {
        case let codeView as NativeMarkdownCodeView:
            if case .code(let language) = section.kind {
                codeView.update(code: section.source, language: language, bodySize: bodySize)
            }
        case let textView as NativeMarkdownTextSectionView:
            textView.update(markdown: section.source, kind: section.kind, bodySize: bodySize, bodyWeight: bodyWeight)
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

    let bodySize: CGFloat
    let bodyWeight: NSFont.Weight
    var rendersBotMentions = true
    func fontSize(_ compactSize: CGFloat) -> CGFloat {
        DockWorkspaceScale.points(compactSize, scale: bodySize / NativeMarkdownAttributedTextBuilder.bodySize)
    }
    init(bodySize: CGFloat = DockTypography.size(.conversation), bodyWeight: NSFont.Weight = .regular) {
        self.bodySize = bodySize
        self.bodyWeight = bodyWeight
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
        bodySize: CGFloat = DockTypography.size(.conversation),
        bodyWeight: NSFont.Weight = .regular,
        build: () -> NativeMarkdownAttributedTextBuilder.Output
    ) -> NativeMarkdownAttributedTextBuilder.Output {
        let key =
            "\(themeRevision)|\(bodySize)|\(bodyWeight.rawValue)|\(BotMentions.revision)|\(kind)|\(markdown)"
            as NSString
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

    /// Marks inline icons so text-offset consumers can strip them.
    static let fileIconKey = NSAttributedString.Key("herm.fileIcon")
    static let bodySize: CGFloat = DockTypography.size(.conversation)
    static let codeSize: CGFloat = DockTypography.size(.code)
    static let listIndent: CGFloat = 22
    static let quoteIndent: CGFloat = 12

    static func document(_ markdown: String, palette: NativeMarkdownPalette) -> Output {
        let key = MarkdownRenderKey(messageID: UUID(), contentRevision: 0, themeRevision: 0)
        let sections = MarkdownRenderDocumentBuilder.build(source: markdown, key: key).sections
        guard sections.contains(where: { $0.kind == .table }) else {
            return ordinaryDocument(markdown, palette: palette)
        }
        let result = NSMutableAttributedString()
        var quoteRanges: [NSRange] = []
        for section in sections {
            let output =
                section.kind == .table
                ? table(section.source, palette: palette)
                : ordinaryDocument(section.source, palette: palette)
            guard output.string.length > 0 else { continue }
            if result.length > 0 {
                let attributes = result.attributes(at: result.length - 1, effectiveRange: nil)
                result.append(NSAttributedString(string: "\n", attributes: attributes))
            }
            let offset = result.length
            result.append(output.string)
            quoteRanges += output.quoteRanges.map { NSRange(location: offset + $0.location, length: $0.length) }
        }
        return Output(string: result, quoteRanges: quoteRanges)
    }

    private static func ordinaryDocument(_ markdown: String, palette: NativeMarkdownPalette) -> Output {
        let blocks = MarkdownRenderDocumentBuilder.renderBlocks(for: markdown)
        let result = NSMutableAttributedString()
        var quoteRanges: [NSRange] = []
        for (index, block) in blocks.enumerated() {
            let spacingBefore: CGFloat = index == 0 ? 0 : NativeMarkdownDocumentContainerView.sectionSpacing
            let start = result.length
            switch block {
            case .heading(let level, let text):
                let style = paragraphStyle(spacingBefore: index == 0 ? 0 : spacingBefore + 2)
                result.append(
                    inline(
                        text,
                        font: DockSkinPresentation.nativeFont(
                            size: palette.fontSize(headingSize(level)), weight: .semibold), color: palette.primary,
                        palette: palette, style: style))
            case .paragraph(let text):
                let style = paragraphStyle(spacingBefore: spacingBefore, lineSpacing: 3)
                result.append(
                    inline(
                        text, font: DockSkinPresentation.nativeFont(size: palette.bodySize, weight: palette.bodyWeight),
                        color: palette.primary, palette: palette, style: style))
            case .listItem(let text, let marker):
                let style = paragraphStyle(spacingBefore: spacingBefore, lineSpacing: 3)
                style.headIndent = listIndent
                style.tabStops = [NSTextTab(textAlignment: .left, location: listIndent)]
                style.defaultTabInterval = listIndent
                result.append(
                    NSAttributedString(
                        string: "\(marker)\t",
                        attributes: [
                            .font: DockSkinPresentation.nativeFont(size: palette.bodySize, weight: .medium),
                            .foregroundColor: palette.accent,
                            .paragraphStyle: style,
                        ]))
                result.append(
                    inline(
                        text, font: DockSkinPresentation.nativeFont(size: palette.bodySize, weight: palette.bodyWeight),
                        color: palette.primary, palette: palette, style: style))
            case .quote(let text):
                let style = paragraphStyle(spacingBefore: spacingBefore, lineSpacing: 3)
                style.headIndent = quoteIndent
                style.firstLineHeadIndent = quoteIndent
                result.append(
                    inline(
                        text, font: DockSkinPresentation.nativeFont(size: palette.bodySize, weight: palette.bodyWeight),
                        color: palette.secondary, palette: palette, style: style))
                quoteRanges.append(NSRange(location: start, length: result.length - start))
            case .code(let code, let language):
                result.append(codeBlock(code, language: language, spacingBefore: spacingBefore, palette: palette))
            case .tableRow(let columns):
                let style = paragraphStyle(spacingBefore: spacingBefore)
                for (column, value) in columns.enumerated() {
                    if column > 0 {
                        result.append(
                            NSAttributedString(
                                string: "  │  ",
                                attributes: [
                                    .font: DockSkinPresentation.nativeFont(size: palette.bodySize),
                                    .foregroundColor: palette.metadata,
                                    .paragraphStyle: style,
                                ]))
                    }
                    result.append(
                        inline(
                            value, font: DockSkinPresentation.nativeFont(size: palette.bodySize),
                            color: palette.primary, palette: palette, style: style))
                }
            }
            if index < blocks.count - 1 {
                let attributes =
                    result.length > start
                    ? result.attributes(at: result.length - 1, effectiveRange: nil)
                    : [:]
                result.append(NSAttributedString(string: "\n", attributes: attributes))
            }
        }
        return Output(string: result, quoteRanges: quoteRanges)
    }

    static func code(_ code: String, palette: NativeMarkdownPalette) -> NSAttributedString {
        NSAttributedString(
            string: code,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: palette.fontSize(codeSize), weight: .regular),
                .foregroundColor: palette.primary,
            ])
    }

    nonisolated static func isTableStart(_ lines: [String], at index: Int) -> Bool {
        MarkdownTableSyntax.isTableStart(lines, at: index)
    }

    nonisolated static func isPureTable(_ markdown: String) -> Bool {
        MarkdownTableSyntax.isPureTable(markdown)
    }

    nonisolated static func tableCells(_ line: String) -> [String] {
        MarkdownTableSyntax.tableCells(line)
    }

    nonisolated static func isSeparatorRow(_ cells: [String]) -> Bool {
        MarkdownTableSyntax.isSeparatorRow(cells)
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
                let block = NSTextTableBlock(
                    table: table, startingRow: rowIndex, rowSpan: 1, startingColumn: column, columnSpan: 1)
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
                let font: NSFont =
                    isHeader
                    ? DockSkinPresentation.nativeFont(size: palette.bodySize, weight: .semibold)
                    : DockSkinPresentation.nativeFont(size: palette.bodySize)
                // An empty cell still needs one character to own its block.
                let parsed = value.isEmpty ? AttributedString(" ") : inlineMarkdown(value)
                let cell = NSMutableAttributedString(
                    attributedString: inline(parsed, font: font, color: palette.primary, palette: palette, style: style)
                )
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
        // The autolinker swallows the closing `**` of a bold bare URL; angle brackets end the URL there.
        let value = value.replacingOccurrences(
            of: #"\*\*(https?://[^\s*<>]+)\*\*"#, with: "**<$1>**", options: .regularExpression)
        var parsed =
            (try? AttributedString(
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
        var previousLink: URL?
        for run in value.runs {
            let rawText = String(value[run.range].characters)
            let text = run.link.map { MarkdownWebsiteIcon.label(rawText, for: $0) } ?? rawText
            guard !text.isEmpty else { continue }
            defer { previousLink = run.link }
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
                .paragraphStyle: style,
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
            var inlineAttachment: NSTextAttachment?
            if let link = run.link, link != previousLink {
                inlineAttachment = MarkdownWebsiteIcon.attachment(
                    for: link, size: baseFont.pointSize - 1, color: palette.primary)
            }
            if inlineAttachment == nil, run.link.flatMap(MarkdownWebsiteIcon.host(for:)) == nil,
                run.link != nil || intent.contains(.code),
                let icon = ArtifactFileIcon.inlineImage(forPath: text, size: baseFont.pointSize - 1)
            {
                let attachment = NSTextAttachment()
                attachment.image = icon
                attachment.bounds = CGRect(x: 0, y: -2, width: icon.size.width, height: icon.size.height)
                inlineAttachment = attachment
            }
            if let attachment = inlineAttachment {
                let iconString = NSMutableAttributedString(attachment: attachment)
                iconString.append(NSAttributedString(string: "\u{2009}"))
                var iconAttributes = attributes
                iconAttributes[.underlineStyle] = nil
                iconAttributes[fileIconKey] = true
                iconString.addAttributes(iconAttributes, range: NSRange(location: 0, length: iconString.length))
                result.append(iconString)
            }
            let start = result.length
            result.append(NSAttributedString(string: text, attributes: attributes))
            guard run.link == nil, !intent.contains(.code) else { continue }
            for range in SlashCommandTokens.ranges(in: text) {
                result.addAttributes(
                    [
                        .font: NSFont.monospacedSystemFont(ofSize: baseFont.pointSize - 1, weight: .semibold),
                        .foregroundColor: palette.accent,
                        .backgroundColor: palette.accent.withAlphaComponent(0.16),
                    ], range: NSRange(location: start + range.location, length: range.length))
            }
        }
        return palette.rendersBotMentions ? BotMentions.pilled(result) : result
    }

    private static func codeBlock(
        _ code: String,
        language: String?,
        spacingBefore: CGFloat,
        palette: NativeMarkdownPalette
    ) -> NSAttributedString {
        let block = NSTextBlock()
        // Without an explicit width the block shrinks to one character.
        block.setValue(100, type: .percentageValueType, for: .width)
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
            result.append(
                NSAttributedString(
                    string: language.uppercased() + "\n",
                    attributes: [
                        .font: NSFont.monospacedSystemFont(
                            ofSize: palette.fontSize(DockTypography.size(.control)), weight: .medium),
                        .foregroundColor: palette.secondary,
                        .paragraphStyle: style,
                    ]))
        }
        result.append(
            NSAttributedString(
                string: code.isEmpty ? " " : code,
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: palette.fontSize(codeSize), weight: .regular),
                    .foregroundColor: palette.primary,
                    .paragraphStyle: style,
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
        DockTypography.markdownHeadingSize(level)
    }
}

@MainActor
final class NativeMarkdownTextSectionView: NSTextView, NativeMarkdownMeasurableSection {
    var markdownOpenURL: OpenURLAction?
    private var renderedMarkdown: String?
    private var renderedKind: MarkdownRenderSectionKind?
    private var renderedMentionRevision: Int?
    private var renderedThemeRevision: Int?
    private var heights = NativeMarkdownHeightCache()
    private var isMeasuringHeight = false
    private var quoteRanges: [NSRange] = []
    private var quoteBarColor: NSColor = .separatorColor
    /// Code presentation keeps its natural line width and scrolls
    /// horizontally inside `NativeMarkdownCodeView`.
    var wrapsToWidth = true

    init() {
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
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
        // Proposals own the width; apply this after NSTextView's resizing setup.
        container.widthTracksTextView = false
        NotificationCenter.default.addObserver(
            self, selector: #selector(websiteIconLoaded), name: MarkdownWebsiteIcon.didLoad, object: nil)
    }

    @objc private func websiteIconLoaded() {
        guard let textStorage else { return }
        layoutManager?.invalidateDisplay(forCharacterRange: NSRange(location: 0, length: textStorage.length))
        needsDisplay = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var renderedBodySize: CGFloat?
    private var renderedBodyWeight: NSFont.Weight?
    func update(
        markdown: String, kind: MarkdownRenderSectionKind, bodySize: CGFloat = DockTypography.size(.conversation),
        bodyWeight: NSFont.Weight = .regular
    ) {
        // A theme change keeps the same markdown but changes every color, so
        // the rendered theme revision is part of what makes the text current.
        let themeRevision = DockThemeRuntime.revision
        guard
            renderedMarkdown != markdown || renderedKind != kind || renderedThemeRevision != themeRevision
                || renderedMentionRevision != BotMentions.revision || renderedBodySize != bodySize
                || renderedBodyWeight != bodyWeight
        else { return }
        renderedBodySize = bodySize
        renderedBodyWeight = bodyWeight
        renderedMentionRevision = BotMentions.revision
        renderedMarkdown = markdown
        renderedKind = kind
        renderedThemeRevision = themeRevision
        let palette = NativeMarkdownPalette(bodySize: bodySize, bodyWeight: bodyWeight)
        linkTextAttributes = [.foregroundColor: palette.accent, .underlineStyle: NSUnderlineStyle.single.rawValue]
        quoteBarColor = palette.border
        let output = NativeMarkdownAttributedOutputCache.output(
            markdown: markdown,
            kind: kind,
            themeRevision: themeRevision, bodySize: bodySize, bodyWeight: bodyWeight
        ) {
            switch kind {
            case .code:
                return .init(
                    string: NativeMarkdownAttributedTextBuilder.code(markdown, palette: palette), quoteRanges: [])
            case .table where NativeMarkdownAttributedTextBuilder.isPureTable(markdown):
                return NativeMarkdownAttributedTextBuilder.table(markdown, palette: palette)
            default:
                return NativeMarkdownAttributedTextBuilder.document(markdown, palette: palette)
            }
        }
        quoteRanges = output.quoteRanges
        // A reused measurement view must not inherit the previous block's font.
        typingAttributes = output.string.length > 0 ? output.string.attributes(at: 0, effectiveRange: nil) : [:]
        defaultParagraphStyle = typingAttributes[.paragraphStyle] as? NSParagraphStyle
        textStorage?.setAttributedString(output.string)
        heights.removeAll()
        invalidateIntrinsicContentSize()
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    override func clicked(onLink link: Any, at charIndex: Int) {
        guard let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:)) else { return }
        if let markdownOpenURL { markdownOpenURL(url) } else { openMarkdownLink(url, from: self) }
    }

    /// NSTextView's own link cursor is lost when hosted in SwiftUI, so the
    /// pointing hand is registered explicitly over each link's line rects.
    override func resetCursorRects() {
        super.resetCursorRects()
        guard let storage = textStorage, let layoutManager, let textContainer else { return }
        let origin = textContainerOrigin
        storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard value != nil else { return }
            let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            layoutManager.enumerateEnclosingRects(
                forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                in: textContainer
            ) { rect, _ in
                self.addCursorRect(rect.offsetBy(dx: origin.x, dy: origin.y), cursor: .pointingHand)
            }
        }
    }

    func measuredHeight(forWidth width: CGFloat) -> CGFloat {
        if let cached = heights.height(forWidth: width) { return cached }
        guard let textContainer, let layoutManager, (textStorage?.length ?? 0) > 0 else {
            heights.store(0, forWidth: width)
            return 0
        }
        // Sizing probes must not leave displayed text wrapped at a trial width.
        let displayedWidth = bounds.width
        isMeasuringHeight = true
        defer {
            isMeasuringHeight = false
            if wrapsToWidth, displayedWidth > 1 { setContainerWidth(displayedWidth) }
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

    /// Tight width of the text when wrapped at `width`. `usedRect` can report
    /// the full container width, so measure the attributed string directly.
    func usedWidth(forWidth width: CGFloat) -> CGFloat {
        guard let storage = textStorage, storage.length > 0 else { return 0 }
        let rect = storage.boundingRect(
            with: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return min(width, ceil(rect.width) + 1)
    }

    override var intrinsicContentSize: NSSize {
        guard bounds.width > 1 else { return NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
        return NSSize(width: NSView.noIntrinsicMetric, height: measuredHeight(forWidth: bounds.width))
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // TextKit calls back here while measuring; keep the trial width intact.
        if !isMeasuringHeight, wrapsToWidth, newSize.width > 1 { setContainerWidth(newSize.width) }
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
        guard let textContainer, textContainer.containerSize.width != width else { return }
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
            forwardsCurrentGesture =
                !canScrollHorizontally
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
    private var bodySize: CGFloat = DockTypography.size(.conversation)
    private var labelFont: NSFont {
        .monospacedSystemFont(
            ofSize: NativeMarkdownPalette(bodySize: bodySize).fontSize(DockTypography.size(.machineMetadata)),
            weight: .regular)
    }
    private var copyFont: NSFont {
        DockSkinPresentation.nativeFont(
            size: NativeMarkdownPalette(bodySize: bodySize).fontSize(DockTypography.size(.control)), weight: .medium)
    }

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
        languageLabel.font = labelFont
        languageLabel.lineBreakMode = .byTruncatingTail
        copyButton.isBordered = false
        copyButton.bezelStyle = .inline
        copyButton.font = copyFont
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
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
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
            let labelHeight = ceil(labelFont.ascender - labelFont.descender)
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
            attributes: [.font: copyFont, .foregroundColor: NativeMarkdownPalette().secondary]
        )
        needsLayout = true
    }

    func update(code: String, language: String?, bodySize: CGFloat = DockTypography.size(.conversation)) {
        let sizeChanged = self.bodySize != bodySize
        self.bodySize = bodySize
        languageLabel.font = labelFont
        let themeRevision = DockThemeRuntime.revision
        copyButton.font = copyFont
        layer?.cornerRadius = DockLayout.controlRadius
        guard
            sizeChanged || renderedCode != code || renderedLanguage != language
                || renderedThemeRevision != themeRevision
        else { return }
        renderedCode = code
        renderedLanguage = language
        renderedThemeRevision = themeRevision
        let palette = NativeMarkdownPalette()
        layer?.backgroundColor = palette.surface.cgColor
        layer?.borderColor = palette.border.cgColor
        headerDivider.layer?.backgroundColor = palette.border.cgColor
        languageLabel.textColor = palette.metadata
        setCopyTitle("Copy")
        let (body, opensBlock) = Self.parsedCode(code)
        self.opensBlock = opensBlock
        codeBody = body
        languageLabel.stringValue = opensBlock ? (language ?? "").lowercased() : ""
        setHeaderHidden(!opensBlock)
        textView.update(markdown: body, kind: .code(language: language), bodySize: bodySize)
        contentSize = textView.naturalContentSize()
        needsLayout = true
        invalidateIntrinsicContentSize()
    }

    static func parsedCode(_ code: String) -> (body: String, opensBlock: Bool) {
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
        return (body, opensBlock)
    }
}
