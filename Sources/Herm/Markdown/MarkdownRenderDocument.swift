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
    @Environment(\.conversationScrollController) private var scrollController
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
        view.scrollController = scrollController
        view.markdownOpenURL = context.environment.markdownOpenURL
        view.keepsAccessibilitySectionsMounted = voiceOverEnabled || switchControlEnabled
        view.setBodyStyle(size: DockWorkspaceScale.points(bodySize, scale: workspaceScale), weight: bodyWeight)
        context.coordinator.update(
            view, source: source, key: key, sections: streamingSections, cacheResult: cacheResult)
        return view
    }

    func updateNSView(_ nsView: NativeMarkdownDocumentContainerView, context: Context) {
        nsView.scrollController = scrollController
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
            let prepared = cacheResult ? view.scrollController?.preparedPage?.documents[key] : nil
            let document: MarkdownRenderDocument
            if let prepared, prepared.source == source {
                document = prepared
            } else {
                document = MarkdownRenderDocumentCache.document(for: source, key: key, cacheResult: cacheResult)
            }
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
    private static let tracksPerformance =
        ProcessInfo.processInfo.environment["HERM_CHAT_PROFILE"] == "1"
        || ProcessInfo.processInfo.environment["HERM_SCROLL_PROFILE"] == "1"
        || ProcessInfo.processInfo.environment["HERMES_DOCK_DEBUG_LOGS"] == "1"
        || ProcessInfo.processInfo.arguments.contains("--perf-trace")
    private(set) static var totalViewportSectionVisits = 0
    private(set) static var totalViewportMountChanges = 0
    private(set) static var totalForegroundMeasurements = 0
    private(set) static var maxInactiveViews = 0
    struct MeasurementContext: Equatable {
        let width: CGFloat
        let bodySize: CGFloat
        let bodyWeight: NSFont.Weight
        let themeRevision: Int
        let mentionRevision: Int
        let themeID: DockThemeID
    }
    weak var scrollController: ConversationScrollController?
    var retainsStreamingMeasurements = false
    var markdownOpenURL = OpenURLAction {
        InAppBrowser.open($0)
        return .handled
    }
    /// Matches the block spacing of the SwiftUI `MarkdownMessageView`, so a
    /// message crossing the native threshold keeps the same rhythm.
    static let sectionSpacing: CGFloat = 8

    private final class Entry {
        var section: MarkdownRenderSection
        var view: (any NativeMarkdownMeasurableSection)?
        var spacingBefore: CGFloat
        var heights = NativeMarkdownHeightCache()
        var horizontalOffset: CGFloat = 0
        let estimatedCost: Int

        init(section: MarkdownRenderSection, view: (any NativeMarkdownMeasurableSection)?, spacingBefore: CGFloat) {
            self.section = section
            self.view = view
            self.spacingBefore = spacingBefore
            estimatedCost = section.source.utf8.count * 4
        }
    }

    private lazy var textMeasurer = NativeMarkdownTextSectionView()
    private lazy var codeMeasurer = NativeMarkdownCodeView()
    private var entries: [Entry] = []
    var instantiatedSectionCount: Int { entries.filter { $0.view != nil }.count }
    /// Section views in the viewport band, in document order. Pooled views
    /// stay hidden subviews, so `subviews` is not the mounted set.
    var mountedSectionViews: [NSView] { mountedIndices.sorted().compactMap { entries[$0].view } }
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
    private var mountedIndices: Set<Int> = []
    private var inactiveIndices: [Int] = []
    private var viewIndices: [ObjectIdentifier: Int] = [:]
    private var lastMountedRange: Range<Int>?
    private var lastKeepAll = false
    private var lastFocusedIndex: Int?
    private(set) var viewportUpdateCount = 0
    private(set) var viewportSectionVisits = 0
    private(set) var viewportMountChanges = 0
    /// All mounted documents in one scroller share the clip's notification registration.
    @MainActor private final class ClipViewport {
        private static let byClip = NSMapTable<NSClipView, ClipViewport>.weakToWeakObjects()
        let documents = NSHashTable<NativeMarkdownDocumentContainerView>.weakObjects()
        nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

        static func forClip(_ clip: NSClipView) -> ClipViewport {
            if let viewport = byClip.object(forKey: clip) { return viewport }
            let viewport = ClipViewport(clip: clip)
            byClip.setObject(viewport, forKey: clip)
            return viewport
        }

        private init(clip: NSClipView) {
            clip.postsBoundsChangedNotifications = true
            clip.postsFrameChangedNotifications = true
            for name in [NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification] {
                observers.append(
                    NotificationCenter.default.addObserver(forName: name, object: clip, queue: .main) {
                        [weak self, weak clip] _ in
                        MainActor.assumeIsolated {
                            guard let self, let clip else { return }
                            let bounds = clip.bounds
                            let keyboardAccess = NSApp?.isFullKeyboardAccessEnabled == true
                            for document in self.documents.allObjects {
                                document.clipViewportDidChange(bounds, keyboardAccess: keyboardAccess)
                            }
                        }
                    })
            }
        }

        deinit {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
        }
    }

    private var clipViewport: ClipViewport?
    private weak var observedClipView: NSClipView?
    private var frameInClip: NSRect?
    private var observedAncestors: [ObjectIdentifier] = []
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
        frameInClip = nil
        let clip = window == nil ? nil : enclosingScrollView?.contentView
        if observedClipView !== clip {
            clipViewport?.documents.remove(self)
            clipViewport = clip.map(ClipViewport.forClip)
            clipViewport?.documents.add(self)
            observedClipView = clip
        }
        needsLayout = true
        // SwiftUI detaches and reattaches platform views as rows scroll past.
        // Keep the observers across that instead of rebuilding them each time;
        // updateMountedSections ignores notifications while detached.
        guard let clip else { return }
        var chain: [NSView] = []
        var ancestor: NSView? = self
        while let view = ancestor, view !== clip {
            chain.append(view)
            ancestor = view.superview
        }
        let ids = chain.map(ObjectIdentifier.init)
        guard ids != observedAncestors else { return }
        for observer in viewportObservers { NotificationCenter.default.removeObserver(observer) }
        viewportObservers.removeAll()
        observedAncestors = ids
        // A preceding row can move this message into view without scrolling.
        for view in chain {
            view.postsBoundsChangedNotifications = true
            view.postsFrameChangedNotifications = true
            for name in [NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification] {
                viewportObservers.append(
                    NotificationCenter.default.addObserver(
                        forName: name, object: view, queue: .main
                    ) { [weak self] _ in
                        MainActor.assumeIsolated {
                            guard let self else { return }
                            self.frameInClip = nil
                            self.viewportDidChange(
                                keepAll: self.keepsAccessibilitySectionsMounted || self.fullKeyboardAccess)
                        }
                    })
            }
        }
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
        scrollController?.markdownMeasurementContext = MeasurementContext(
            width: width, bodySize: bodySize, bodyWeight: bodyWeight,
            themeRevision: DockThemeRuntime.revision, mentionRevision: BotMentions.revision,
            themeID: DockThemeRuntime.current)
        if let cached = cachedIntrinsicHeight, cachedSolveWidth == width {
            return cached
        }
        var frames = cachedSolveWidth == width ? cachedFrames : []
        frames.reserveCapacity(entries.count)
        var y = frames.last?.maxY ?? 0
        var hasVisibleSection = y > 0
        for entry in entries.dropFirst(frames.count) {
            let sharesHeight = !isStreamingDocument || (retainsStreamingMeasurements && entry.section.id >= 0)
            let height: CGFloat
            let measurementWidth: CGFloat
            if case .code = entry.section.kind { measurementWidth = 0 } else { measurementWidth = width }
            let sharedKey = NativeMarkdownCompletedHeightCache.Key(
                source: entry.section.source, kind: entry.section.kind, width: measurementWidth,
                bodySize: bodySize, bodyWeight: bodyWeight.rawValue,
                themeRevision: DockThemeRuntime.revision, mentionRevision: BotMentions.revision,
                themeID: DockThemeRuntime.current)
            if let cached = entry.heights.height(forWidth: measurementWidth) {
                height = cached
            } else if sharesHeight,
                let cached = scrollController?.preparedPage?.measurements[sharedKey]
                    ?? NativeMarkdownCompletedHeightCache.measurement(for: sharedKey)
            {
                height = cached.height
                entry.heights.store(height, forWidth: measurementWidth)
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
                if Self.tracksPerformance { Self.totalForegroundMeasurements += 1 }
                entry.heights.store(height, forWidth: measurementWidth)
                if sharesHeight {
                    NativeMarkdownCompletedHeightCache.store(
                        height, for: sharedKey, codeSize: (measuringView as? NativeMarkdownCodeView)?.contentSize)
                }
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
        lastMountedRange = nil
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
        updateMountedSections(keepAll: keepsAccessibilitySectionsMounted || fullKeyboardAccess)
    }

    private var fullKeyboardAccess: Bool { NSApp?.isFullKeyboardAccessEnabled == true }

    private func clipViewportDidChange(_ clipBounds: NSRect, keyboardAccess: Bool) {
        let keepAll = keepsAccessibilitySectionsMounted || keyboardAccess
        // Clip scrolling keeps the document's frame in clip coordinates unchanged.
        if let frameInClip, let lastMountedRange, keepAll == lastKeepAll {
            if lastMountedRange.isEmpty, viewIndices.isEmpty, !clipBounds.intersects(frameInClip) { return }
            if lastMountedRange == entries.indices, clipBounds.contains(frameInClip) { return }
        }
        viewportDidChange(keepAll: keepAll)
    }

    /// A scroll tick or an ancestor move changes what is visible, not how this
    /// document is laid out. Mounting the newly visible sections directly keeps
    /// the scroll's display cycle from queueing a layout pass per frame; the
    /// layout pass is only needed when the solved geometry is out of date.
    private func viewportDidChange(keepAll: Bool) {
        let start = HermPerformanceRecorder.active ? CACurrentMediaTime() : 0
        defer { if start > 0 { HermPerformanceRecorder.recordWork("markdown.viewport", since: start) } }
        guard bounds.width > 1, cachedSolveWidth == bounds.width, entries.count == cachedFrames.count else {
            needsLayout = true
            return
        }
        updateMountedSections(keepAll: keepAll)
    }

    private func updateMountedSections(keepAll: Bool) {
        guard entries.count == cachedFrames.count,
            window != nil || keepsAccessibilitySectionsMounted
        else { return }
        viewportUpdateCount += 1
        if frameInClip == nil, let clip = observedClipView { frameInClip = convert(bounds, to: clip) }
        let visible = visibleRect
        // Keep a viewport of buffer without making offscreen text views take
        // part in every AppKit layout, hit-test, and cursor-rect update.
        let viewport: NSRect? = observedClipView.map { clip in
            visible.isEmpty ? .zero : visible.insetBy(dx: 0, dy: -clip.bounds.height)
        }
        let range = keepAll || viewport == nil ? entries.indices : sectionRange(intersecting: viewport!)
        if range == entries.indices, lastMountedRange == range, lastKeepAll == keepAll { return }
        var focused = viewIndices.isEmpty ? nil : window?.firstResponder as? NSView
        var focusedIndex: Int?
        while let view = focused, view !== self {
            if let index = viewIndices[ObjectIdentifier(view)] {
                focusedIndex = index
                break
            }
            focused = view.superview
        }
        if range == lastMountedRange, keepAll == lastKeepAll, focusedIndex == lastFocusedIndex { return }
        // Unmount only past a wider band, so scrolling back and forth near the
        // edge does not remove, re-add, and redraw the same text views.
        let retained: Range<Int> =
            keepAll || viewport == nil || visible.isEmpty
            ? range : sectionRange(intersecting: viewport!.insetBy(dx: 0, dy: -observedClipView!.bounds.height))
        let carried = lastKeepAll ? [] : mountedIndices.filter(retained.contains)
        let framesChanged = lastMountedRange == nil
        let previouslyMounted = mountedIndices
        lastMountedRange = range
        lastKeepAll = keepAll
        lastFocusedIndex = focusedIndex
        var desired = Set(range).union(carried)
        if let focusedIndex { desired.insert(focusedIndex) }
        for index in mountedIndices.subtracting(desired) {
            guard let view = entries[index].view else { continue }
            if let code = view as? NativeMarkdownCodeView { entries[index].horizontalOffset = code.horizontalOffset }
            // Hide rather than remove: a pooled view keeps its drawn layer, so
            // scrolling back shows it without a re-add, window attach, or redraw.
            // Hidden views skip hit testing, cursor rects, display and accessibility.
            view.isHidden = true
            inactiveIndices.removeAll { $0 == index }
            inactiveIndices.append(index)
            viewportMountChanges += 1
            if Self.tracksPerformance { Self.totalViewportMountChanges += 1 }
        }
        mountedIndices = desired
        inactiveIndices.removeAll(where: desired.contains)
        var nextMounted: NSView?
        for index in desired.sorted().reversed() {
            if !framesChanged, previouslyMounted.contains(index), let view = entries[index].view {
                nextMounted = view
                continue
            }
            viewportSectionVisits += 1
            if Self.tracksPerformance { Self.totalViewportSectionVisits += 1 }
            let entry = entries[index]
            let frame = cachedFrames[index]
            let view: any NativeMarkdownMeasurableSection
            var created = false
            if let existing = entry.view {
                view = existing
            } else {
                view = Self.makeView(for: entry.section)
                let preparedSize: NSSize?
                if !isStreamingDocument, case .code = entry.section.kind {
                    let context = MeasurementContext(
                        width: bounds.width, bodySize: bodySize, bodyWeight: bodyWeight,
                        themeRevision: DockThemeRuntime.revision, mentionRevision: BotMentions.revision,
                        themeID: DockThemeRuntime.current)
                    let key = Self.measurementKey(for: entry.section, context: context)
                    preparedSize =
                        scrollController?.preparedPage?.measurements[key]?.codeSize
                        ?? NativeMarkdownCompletedHeightCache.codeSize(for: key)
                } else {
                    preparedSize = nil
                }
                Self.update(
                    view, with: entry.section, bodySize: bodySize, bodyWeight: bodyWeight,
                    preparedCodeSize: preparedSize)
                entry.view = view
                viewIndices[ObjectIdentifier(view)] = index
                if let code = view as? NativeMarkdownCodeView {
                    code.onInteractionEnded = { [weak self] in self?.trimInactiveSections() }
                }
                created = true
            }
            if view.superview !== self {
                if let nextMounted {
                    addSubview(view, positioned: .below, relativeTo: nextMounted)
                } else {
                    addSubview(view)
                }
                viewportMountChanges += 1
                if Self.tracksPerformance { Self.totalViewportMountChanges += 1 }
            }
            nextMounted = view
            if view.isHidden != (frame.height <= 0) { view.isHidden = frame.height <= 0 }
            if view.frame != frame { view.frame = frame }
            if created, let code = view as? NativeMarkdownCodeView {
                code.restoreHorizontalOffset(entry.horizontalOffset)
            }
        }
        if !keepAll { trimInactiveSections() }
    }

    private func sectionRange(intersecting viewport: CGRect) -> Range<Int> {
        guard !viewport.isEmpty else { return 0..<0 }
        var lower = 0
        var upper = cachedFrames.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if cachedFrames[middle].maxY <= viewport.minY { lower = middle + 1 } else { upper = middle }
        }
        let start = lower
        upper = cachedFrames.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if cachedFrames[middle].minY < viewport.maxY { lower = middle + 1 } else { upper = middle }
        }
        return start..<lower
    }

    private func trimInactiveSections() {
        var bytes = inactiveIndices.reduce(0) { $0 + entries[$1].estimatedCost }
        var count = inactiveIndices.count
        for index in inactiveIndices {
            guard count > 8 || bytes > 256 * 1024 else { break }
            guard let view = entries[index].view, !Self.hasSelectionOrInteraction(view) else { continue }
            bytes -= entries[index].estimatedCost
            count -= 1
            viewIndices.removeValue(forKey: ObjectIdentifier(view))
            view.removeFromSuperview()
            entries[index].view = nil
        }
        inactiveIndices.removeAll { entries[$0].view == nil }
        if Self.tracksPerformance { Self.maxInactiveViews = max(Self.maxInactiveViews, inactiveIndices.count) }
    }

    private static func hasSelectionOrInteraction(_ view: NSView) -> Bool {
        if let text = view as? NSTextView, text.selectedRange().length > 0 { return true }
        if let code = view as? NativeMarkdownCodeView, code.hasActiveInteraction { return true }
        return view.subviews.contains { hasSelectionOrInteraction($0) }
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
        let finishingStream = isStreamingDocument
        isStreamingDocument = false
        applyProjection(document, finishingStream: finishingStream)
    }

    private func applyProjection(_ document: MarkdownRenderDocument, finishingStream: Bool = false) {
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
        var previous =
            finishingStream
            ? [:] : Dictionary(entries.map { ($0.section.id, $0) }, uniquingKeysWith: { first, _ in first })
        var streamed =
            finishingStream
            ? Dictionary(entries.map { ($0.section.sourceRange, $0) }, uniquingKeysWith: { first, _ in first }) : [:]
        var next: [Entry] = []
        next.reserveCapacity(document.sections.count)
        var prefix = 0
        var previousSource: String?
        for section in document.sections {
            let existing =
                finishingStream
                ? streamed.removeValue(forKey: section.sourceRange).flatMap { entry in
                    entry.section.kind == section.kind && entry.section.source == section.source ? entry : nil
                } : previous.removeValue(forKey: section.id)
            let spacing = previousSource.map { Self.spacing(after: $0, before: section) } ?? 0
            let entry: Entry
            if let existing, canReuseHeights, finishingStream || existing.section == section {
                if prefix == next.count, prefix < entries.count, entries[prefix] === existing,
                    spacing == existing.spacingBefore
                {
                    prefix += 1
                }
                entry = existing
                entry.section = section
                entry.spacingBefore = spacing
            } else {
                let view = existing?.view.flatMap { Self.isCompatible($0, with: section) ? $0 : nil }
                if let view { Self.update(view, with: section, bodySize: bodySize, bodyWeight: bodyWeight) }
                entry = Entry(section: section, view: view, spacingBefore: spacing)
                entry.horizontalOffset = existing?.horizontalOffset ?? 0
            }
            next.append(entry)
            previousSource = section.source
        }
        let kept = Set(next.compactMap { $0.view.map(ObjectIdentifier.init) })
        for entry in entries {
            if let view = entry.view, !kept.contains(ObjectIdentifier(view)) { view.removeFromSuperview() }
        }
        let mountedViews = Set(mountedIndices.compactMap { entries[$0].view.map(ObjectIdentifier.init) })
        let isMounted = { (index: Int) in next[index].view.map { mountedViews.contains(ObjectIdentifier($0)) } ?? false
        }
        entries = next
        mountedIndices = Set(next.indices.filter(isMounted))
        inactiveIndices = next.indices.filter { next[$0].view != nil && !isMounted($0) }
        viewIndices = Dictionary(
            uniqueKeysWithValues: next.indices.compactMap { index in
                next[index].view.map { (ObjectIdentifier($0), index) }
            })
        lastMountedRange = nil
        cachedIntrinsicHeight = nil
        if cachedFrames.count > prefix { cachedFrames.removeLast(cachedFrames.count - prefix) }
        needsLayout = true
        invalidateIntrinsicContentSize()
    }

    func applyStreaming(sections: [MarkdownRenderSection], source: String, retained: Int = -1) {
        if retained >= 0, isStreamingDocument, renderedThemeRevision == DockThemeRuntime.revision,
            renderedMentionRevision == BotMentions.revision, retained == entries.count - 1,
            sections.count == entries.count, let section = sections.last, let old = entries.last,
            old.section.id == section.id, old.view.map({ Self.isCompatible($0, with: section) }) ?? true
        {
            self.source = source
            if section == old.section { return }
            if let view = old.view { Self.update(view, with: section, bodySize: bodySize, bodyWeight: bodyWeight) }
            let spacing = retained > 0 ? Self.spacing(after: entries[retained - 1].section.source, before: section) : 0
            let entry = Entry(section: section, view: old.view, spacingBefore: spacing)
            entry.horizontalOffset = old.horizontalOffset
            entries[retained] = entry
            renderedSections = sections
            if cachedFrames.count > retained { cachedFrames.removeLast() }
            cachedIntrinsicHeight = nil
            lastMountedRange = nil
            needsLayout = true
            invalidateIntrinsicContentSize()
            return
        }
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
        mountedIndices.removeAll()
        inactiveIndices.removeAll()
        viewIndices.removeAll()
        lastMountedRange = nil
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
        bodyWeight: NSFont.Weight, preparedCodeSize: NSSize? = nil
    ) {
        switch view {
        case let codeView as NativeMarkdownCodeView:
            if case .code(let language) = section.kind {
                codeView.update(
                    code: section.source, language: language, bodySize: bodySize, preparedSize: preparedCodeSize)
            }
        case let textView as NativeMarkdownTextSectionView:
            textView.update(markdown: section.source, kind: section.kind, bodySize: bodySize, bodyWeight: bodyWeight)
        default:
            break
        }
    }

    static func warmHeight(
        for section: MarkdownRenderSection, context: MeasurementContext,
        textMeasurer: NativeMarkdownTextSectionView, codeMeasurer: NativeMarkdownCodeView
    ) {
        let key = measurementKey(for: section, context: context)
        guard NativeMarkdownCompletedHeightCache.height(for: key) == nil else { return }
        let view: any NativeMarkdownMeasurableSection
        if case .code = section.kind { view = codeMeasurer } else { view = textMeasurer }
        update(view, with: section, bodySize: context.bodySize, bodyWeight: context.bodyWeight)
        NativeMarkdownCompletedHeightCache.store(
            view.measuredHeight(forWidth: context.width), for: key,
            codeSize: (view as? NativeMarkdownCodeView)?.contentSize)
    }

    static func measurementKey(for section: MarkdownRenderSection, context: MeasurementContext)
        -> NativeMarkdownCompletedHeightCache.Key
    {
        let width: CGFloat
        if case .code = section.kind { width = 0 } else { width = context.width }
        return NativeMarkdownCompletedHeightCache.Key(
            source: section.source, kind: section.kind, width: width,
            bodySize: context.bodySize, bodyWeight: context.bodyWeight.rawValue,
            themeRevision: context.themeRevision, mentionRevision: context.mentionRevision, themeID: context.themeID)
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
        let scale = bodySize / NativeMarkdownAttributedTextBuilder.bodySize
        return scale == 1 ? compactSize : (compactSize * scale).rounded()
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
        let blocks =
            MarkdownPreparedBlockCache.blocks(for: markdown)
            ?? MarkdownRenderDocumentBuilder.preparedBlocks(for: markdown)
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
    static func inlineMarkdown(_ value: String) -> AttributedString {
        MarkdownInlineParser.parse(value)
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
        return palette.rendersBotMentions ? BotMentions.pilled(result, textScale: palette.bodySize / bodySize) : result
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
extension NSTextView {
    func addMarkdownLinkCursorRects() {
        for rect in markdownLinkRects() { addCursorRect(rect, cursor: .pointingHand) }
    }

    /// Line rects of the links in `characterRange` (all text when nil), in
    /// view coordinates. Finding them lays out the text around each link, so
    /// callers that reset often should limit the range and cache.
    func markdownLinkRects(in characterRange: NSRange? = nil) -> [CGRect] {
        guard let storage = textStorage, let layoutManager, let textContainer else { return [] }
        let origin = textContainerOrigin
        var rects: [CGRect] = []
        let all = NSRange(location: 0, length: storage.length)
        let searched = characterRange.map { NSIntersectionRange($0, all) } ?? all
        storage.enumerateAttribute(.link, in: searched) { value, range, _ in
            guard value != nil else { return }
            let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            layoutManager.enumerateEnclosingRects(
                forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                in: textContainer
            ) { rect, _ in
                rects.append(rect.offsetBy(dx: origin.x, dy: origin.y))
            }
        }
        return rects
    }

    /// Cursor rects only run in the key window, and Herm's panel is
    /// non-activating, so read-only markdown also tracks the mouse directly:
    /// hand over links, I-beam over text, arrow again on exit.
    func installMarkdownCursorTracking() {
        guard !trackingAreas.contains(where: { $0.owner === self && $0.options.contains(.activeAlways) }) else {
            return
        }
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                owner: self))
    }

    /// Claims the cursor only when this view is what the mouse is actually
    /// over; neighbouring SwiftUI buttons inside its tracking rect keep theirs.
    func claimsMarkdownCursor(for event: NSEvent) -> Bool {
        guard let hit = window?.contentView?.hitTest(event.locationInWindow), hit === self || hit.isDescendant(of: self)
        else {
            DockPointerCursor.textExited(self)
            return false
        }
        DockPointerCursor.textEntered(self)
        return true
    }

    func markdownCursor(for event: NSEvent) -> NSCursor {
        guard let layoutManager, let textContainer, let storage = textStorage, storage.length > 0 else { return .arrow }
        let local = convert(event.locationInWindow, from: nil)
        let point = NSPoint(x: local.x - textContainerOrigin.x, y: local.y - textContainerOrigin.y)
        let glyph = layoutManager.glyphIndex(for: point, in: textContainer)
        let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
        guard rect.contains(point) else { return .iBeam }
        let index = layoutManager.characterIndexForGlyph(at: glyph)
        guard index < storage.length else { return .iBeam }
        return storage.attribute(.link, at: index, effectiveRange: nil) != nil ? .pointingHand : .iBeam
    }
}

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
        // Mounting a section during scroll then lays out only the text it draws
        // instead of the whole section; height measurement still lays out all.
        layout.allowsNonContiguousLayout = true
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
        let stylingStarted = DispatchTime.now().uptimeNanoseconds
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
        hasLinks = false
        output.string.enumerateAttribute(.link, in: NSRange(location: 0, length: output.string.length)) {
            value, _, stop in
            if value != nil {
                hasLinks = true
                stop.pointee = true
            }
        }
        // A reused measurement view must not inherit the previous block's font.
        typingAttributes = output.string.length > 0 ? output.string.attributes(at: 0, effectiveRange: nil) : [:]
        defaultParagraphStyle = typingAttributes[.paragraphStyle] as? NSParagraphStyle
        let installStarted = DispatchTime.now().uptimeNanoseconds
        textStorage?.setAttributedString(output.string)
        textRevision &+= 1
        let installed = DispatchTime.now().uptimeNanoseconds
        DebugLog.writePerformance(
            "markdown_text_update styling_ms=\(Double(installStarted - stylingStarted) / 1_000_000) install_ms=\(Double(installed - installStarted) / 1_000_000) utf16=\(output.string.length)"
        )
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
    /// AppKit resets cursor rects whenever an ancestor moves, which is every
    /// transcript scroll tick. Layout is non-contiguous, so only links in the
    /// visible text are measured; measuring all of them would lay out the
    /// whole section. The rects are kept until the text, geometry or visible
    /// text changes.
    override func resetCursorRects() {
        super.resetCursorRects()
        guard hasLinks else { return }
        let start = HermPerformanceRecorder.active ? CACurrentMediaTime() : 0
        defer { if start > 0 { HermPerformanceRecorder.recordWork("markdown.linkCursorRects", since: start) } }
        let visible = visibleRect
        guard !visible.isEmpty, let layoutManager, let textContainer else { return }
        let origin = textContainerOrigin
        let glyphs = layoutManager.glyphRange(
            forBoundingRect: visible.offsetBy(dx: -origin.x, dy: -origin.y), in: textContainer)
        let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let key = LinkRectKey(
            textRevision: textRevision, containerSize: textContainer.size, origin: origin, characters: characters)
        if linkRects?.key != key {
            linkRectComputationCount += 1
            linkRects = (key, markdownLinkRects(in: characters))
        }
        for rect in linkRects?.rects ?? [] where rect.intersects(visible) {
            addCursorRect(rect, cursor: .pointingHand)
        }
    }

    private struct LinkRectKey: Equatable {
        var textRevision: Int
        var containerSize: NSSize
        var origin: NSPoint
        var characters: NSRange
    }
    private var textRevision = 0
    private var hasLinks = false
    private var linkRects: (key: LinkRectKey, rects: [CGRect])?
    private(set) var linkRectComputationCount = 0

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        installMarkdownCursorTracking()
    }

    override func mouseMoved(with event: NSEvent) {
        // NSTextView's own handling sets an I-beam, so it only runs when the
        // text (not a neighbouring button) is what the mouse is over.
        // Mid-scroll moves only chase text sliding under a still pointer;
        // the claim below re-hit-tests the whole window.
        guard !DockScrollActivity.isScrolling(at: event.timestamp), claimsMarkdownCursor(for: event) else { return }
        super.mouseMoved(with: event)
        markdownCursor(for: event).set()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        DockPointerCursor.textExited(self)
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

    /// A preparation view keeps its TextKit state between slices; displayed views never use this path.
    func beginIncrementalLayout(forWidth width: CGFloat) {
        isMeasuringHeight = true
        if wrapsToWidth { setContainerWidth(width) }
    }

    func advanceIncrementalLayout(from offset: Int, limit: Int = 2_048) -> Int {
        let length = textStorage?.length ?? 0
        let end = min(length, offset + limit)
        if end > offset {
            layoutManager?.ensureLayout(forCharacterRange: NSRange(location: offset, length: end - offset))
        }
        return end
    }

    var incrementalTextLength: Int { textStorage?.length ?? 0 }

    func finishIncrementalLayout(forWidth width: CGFloat) -> NSSize {
        defer {
            isMeasuringHeight = false
            if wrapsToWidth, bounds.width > 1 { setContainerWidth(bounds.width) }
        }
        guard let textContainer, let layoutManager else { return .zero }
        let used = layoutManager.usedRect(for: textContainer)
        let size = NSSize(width: ceil(used.width), height: ceil(used.height))
        heights.store(size.height, forWidth: width)
        return size
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
    /// What a tile depends on. AppKit marks every nested scroll view for
    /// layout when its position in the window moves, so each transcript scroll
    /// tick re-tiled every code block although none of these had changed.
    struct TileInputs: Equatable {
        var size: NSSize
        var documentSize: NSSize
        var scrollerStyle: NSScroller.Style
        var insetTop: CGFloat
        var insetLeft: CGFloat
        var insetBottom: CGFloat
        var insetRight: CGFloat
        var inWindow: Bool
    }

    private var forwardsCurrentGesture = false
    private var tiledInputs: TileInputs?
    private(set) var tileCount = 0

    private var tileInputs: TileInputs {
        TileInputs(
            size: bounds.size, documentSize: documentView?.frame.size ?? .zero, scrollerStyle: scrollerStyle,
            insetTop: contentInsets.top, insetLeft: contentInsets.left, insetBottom: contentInsets.bottom,
            insetRight: contentInsets.right, inWindow: window != nil)
    }

    override func layout() {
        let inputs = tileInputs
        guard inputs != tiledInputs else { return }
        super.layout()
        tiledInputs = tileInputs
    }

    override func tile() {
        tileCount += 1
        super.tile()
        tiledInputs = nil
    }

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
    private let languageLabel = NSTextField(labelWithString: "")
    private let copyButton = NativeMarkdownCopyButton()
    private let headerDivider = NSView()
    private let scrollView = NativeMarkdownHorizontalScrollView()
    private let textView = NativeMarkdownTextSectionView()
    private var renderedCode: String?
    private var renderedLanguage: String?
    private var renderedThemeRevision: Int?
    private(set) var contentSize: NSSize = .zero
    private var copyResetTask: Task<Void, Never>?
    var onInteractionEnded: (() -> Void)?
    private var pendingHorizontalOffset: CGFloat?
    var horizontalOffset: CGFloat { scrollView.contentView.bounds.origin.x }
    var hasActiveInteraction: Bool { copyResetTask != nil || textView.selectedRange().length > 0 }

    func restoreHorizontalOffset(_ offset: CGFloat) {
        pendingHorizontalOffset = offset
        needsLayout = true
    }
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
        // The copy icon swaps to a drawn check on click, like DockCopyButton.
        copyButton.configure(
            iconSize: 13, color: NativeMarkdownPalette().secondary, confirmationColor: NSColor(Color.dockSuccess))
        copyButton.onCopy = { [weak self] in self?.copyCode(nil) }
        headerDivider.wantsLayer = true
        // Safe-area insets track window geometry, so every outer scroll tick
        // would re-tile this nested scroll view.
        scrollView.automaticallyAdjustsContentInsets = false
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
            let buttonWidth: CGFloat = 28
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
        if let offset = pendingHorizontalOffset {
            pendingHorizontalOffset = nil
            scrollView.contentView.scroll(
                to: NSPoint(x: min(max(0, offset), max(0, documentFrame.width - scrollFrame.width)), y: 0))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    private static func isBareFence(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let marker = trimmed.first, marker == "`" || marker == "~", trimmed.count >= 3 else { return false }
        return trimmed.allSatisfy { $0 == marker }
    }

    private func copyCode(_ sender: Any?) {
        // A streamed block can span several sections; copy the whole block.
        let text = (superview as? NativeMarkdownDocumentContainerView)?.codeBlockText(startingAt: self) ?? codeBody
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copyResetTask?.cancel()
        copyResetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(NativeMarkdownCopyButton.confirmationInterval))
            guard !Task.isCancelled else { return }
            self?.copyButton.setConfirmation(false)
            self?.copyResetTask = nil
            self?.onInteractionEnded?()
        }
    }

    func update(
        code: String, language: String?, bodySize: CGFloat = DockTypography.size(.conversation),
        preparedSize: NSSize? = nil, deferMeasurement: Bool = false
    ) {
        let sizeChanged = self.bodySize != bodySize
        self.bodySize = bodySize
        languageLabel.font = labelFont
        let themeRevision = DockThemeRuntime.revision
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
        copyButton.configure(iconSize: 13, color: palette.secondary, confirmationColor: NSColor(Color.dockSuccess))
        let (body, opensBlock) = Self.parsedCode(code)
        self.opensBlock = opensBlock
        codeBody = body
        languageLabel.stringValue = opensBlock ? (language ?? "").lowercased() : ""
        setHeaderHidden(!opensBlock)
        textView.update(markdown: body, kind: .code(language: language), bodySize: bodySize)
        contentSize = preparedSize ?? (deferMeasurement ? .zero : textView.naturalContentSize())
        needsLayout = true
        invalidateIntrinsicContentSize()
    }

    func beginIncrementalLayout() { textView.beginIncrementalLayout(forWidth: 0) }
    var incrementalTextLength: Int { textView.incrementalTextLength }
    func advanceIncrementalLayout(from offset: Int) -> Int { textView.advanceIncrementalLayout(from: offset) }
    func finishIncrementalLayout() {
        contentSize = textView.finishIncrementalLayout(forWidth: 0)
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
