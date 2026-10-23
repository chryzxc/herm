import AppKit
import SwiftUI

/// Where a review popover points: a range of the rendered document, either a
/// fresh selection or an existing note's highlight.
struct AnnotationAnchor: Equatable {
    let range: NSRange
    let annotationID: UUID?
}

/// A highlighted passage in the rendered document. Numbered highlights also
/// get a marker in the right margin.
struct AnnotationHighlight: Equatable {
    enum Style { case draft, sent, active }
    let id: UUID
    let range: NSRange
    let style: Style
    var number: Int?
}

/// Read-only document in one native text view, so a selection can span
/// blocks, ends reliably on mouse-up, and maps to an on-screen rect. Notes are
/// drawn as temporary highlights and edited in a popover anchored to the text.
struct AnnotatableDocumentView<Editor: View>: NSViewRepresentable {
    @Environment(\.dockWorkspaceScale) private var workspaceScale
    let text: String
    let isMarkdown: Bool
    let highlights: [AnnotationHighlight]
    @Binding var anchor: AnnotationAnchor?
    let onSelect: (NSRange, String) -> Void
    let onOpenAnnotation: (UUID, NSRange) -> Void
    /// The popover closed without the editor resolving it (click-away, Esc).
    let onDismiss: () -> Void
    /// Reports the rendered string so the pane can locate quotes in it.
    let onRendered: (String) -> Void
    @ViewBuilder let editor: () -> Editor

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        let textView = ReviewTextView()
        textView.autoresizingMask = [.width]
        textView.coordinator = context.coordinator
        scrollView.documentView = textView
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let textView = coordinator.textView else { return }
        let revision = DockThemeRuntime.revision
        if coordinator.renderedText != text || coordinator.renderedTheme != revision
            || coordinator.renderedMarkdown != isMarkdown || coordinator.renderedScale != workspaceScale
        {
            coordinator.renderedText = text
            coordinator.renderedTheme = revision
            coordinator.renderedMarkdown = isMarkdown
            coordinator.renderedScale = workspaceScale
            textView.textStorage?.setAttributedString(
                Self.attributed(text, isMarkdown: isMarkdown, scale: workspaceScale))
            coordinator.forceHighlightRefresh()
            let rendered = textView.string
            DispatchQueue.main.async { onRendered(rendered) }
        }
        coordinator.apply(highlights)
        coordinator.present(anchor)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.closePopover()
    }

    private static func attributed(_ text: String, isMarkdown: Bool, scale: CGFloat) -> NSAttributedString {
        let palette = NativeMarkdownPalette(bodySize: DockTypography.size(.conversation, scale: scale))
        guard isMarkdown else {
            return NSAttributedString(
                string: text,
                attributes: [
                    .font: NSFont.monospacedSystemFont(
                        ofSize: DockWorkspaceScale.points(11.5, scale: scale), weight: .regular),
                    .foregroundColor: palette.primary,
                ])
        }
        // Quotes and highlights are text offsets; inline file icons would add
        // attachment characters to selections, so the review view omits them.
        let document = NSMutableAttributedString(
            attributedString: NativeMarkdownAttributedTextBuilder.document(text, palette: palette).string)
        var iconRanges: [NSRange] = []
        document.enumerateAttribute(
            NativeMarkdownAttributedTextBuilder.fileIconKey, in: NSRange(location: 0, length: document.length)
        ) { value, range, _ in
            if value != nil { iconRanges.append(range) }
        }
        for range in iconRanges.reversed() { document.deleteCharacters(in: range) }
        return document
    }

    @MainActor
    final class Coordinator: NSObject, NSPopoverDelegate {
        var parent: AnnotatableDocumentView?
        weak var textView: ReviewTextView?
        var renderedText: String?
        var renderedTheme: Int?
        var renderedMarkdown: Bool?
        var renderedScale: CGFloat?
        private(set) var appliedHighlights: [AnnotationHighlight] = []
        private var popover: NSPopover?
        private var hosting: NSHostingController<AnyView>?
        private var shownAnchor: AnnotationAnchor?
        private var isClosingProgrammatically = false

        // MARK: Mouse

        func mouseUp(in textView: NSTextView, at point: NSPoint) {
            let string = textView.string as NSString
            let selection = Self.trimmed(textView.selectedRange(), in: string)
            if selection.length > 0 {
                textView.setSelectedRange(selection)
                parent?.onSelect(selection, String(string.substring(with: selection).prefix(500)))
                return
            }
            let index = textView.characterIndexForInsertion(at: point)
            // Smallest highlight wins when notes overlap.
            if let hit =
                appliedHighlights
                .filter({ NSLocationInRange(index, $0.range) })
                .min(by: { $0.range.length < $1.range.length })
            {
                open(hit)
            }
        }

        func open(_ highlight: AnnotationHighlight) {
            parent?.onOpenAnnotation(highlight.id, highlight.range)
        }

        /// Drops leading/trailing whitespace and newlines so a sloppy drag
        /// doesn't highlight to the end of the line or into the next bullet.
        static func trimmed(_ range: NSRange, in string: NSString) -> NSRange {
            guard range.length > 0, NSMaxRange(range) <= string.length else {
                return NSRange(location: range.location, length: 0)
            }
            let blank = CharacterSet.whitespacesAndNewlines
            var start = range.location
            var end = NSMaxRange(range)
            while start < end, let scalar = UnicodeScalar(string.character(at: start)), blank.contains(scalar) {
                start += 1
            }
            while end > start, let scalar = UnicodeScalar(string.character(at: end - 1)), blank.contains(scalar) {
                end -= 1
            }
            return NSRange(location: start, length: end - start)
        }

        // MARK: Highlights

        func forceHighlightRefresh() { appliedHighlights = [] }

        func apply(_ highlights: [AnnotationHighlight]) {
            guard highlights != appliedHighlights, let textView, let layout = textView.layoutManager else { return }
            let length = textView.string.utf16.count
            layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: length))
            let accent = NSColor(Color.dockAccent)
            // Sent first so drafts and the active note paint over them.
            let order: [AnnotationHighlight.Style: Int] = [.sent: 0, .draft: 1, .active: 2]
            for highlight in highlights.sorted(by: { order[$0.style]! < order[$1.style]! })
            where NSMaxRange(highlight.range) <= length {
                let alpha: CGFloat =
                    switch highlight.style {
                    case .sent: 0.07
                    case .draft: 0.16
                    case .active: 0.30
                    }
                layout.addTemporaryAttribute(
                    .backgroundColor, value: accent.withAlphaComponent(alpha), forCharacterRange: highlight.range)
            }
            appliedHighlights = highlights
            textView.needsDisplay = true
            textView.window?.invalidateCursorRects(for: textView)
        }

        // MARK: Popover

        func present(_ anchor: AnnotationAnchor?) {
            guard let anchor, let parent, let textView else {
                closePopover()
                return
            }
            let content = AnyView(parent.editor())
            if let hosting, popover?.isShown == true, shownAnchor == anchor {
                hosting.rootView = content
                return
            }
            closePopover()
            textView.scrollRangeToVisible(anchor.range)
            guard textView.window != nil, let rect = textView.lastLineRect(for: anchor.range) else { return }
            let hosting = NSHostingController(rootView: content)
            hosting.sizingOptions = .preferredContentSize
            let popover = NSPopover()
            popover.behavior = .transient
            popover.animates = true
            popover.contentViewController = hosting
            popover.delegate = self
            self.hosting = hosting
            self.popover = popover
            shownAnchor = anchor
            popover.show(relativeTo: rect, of: textView, preferredEdge: .maxY)
        }

        func closePopover() {
            guard let popover else { return }
            isClosingProgrammatically = true
            popover.close()
            isClosingProgrammatically = false
            didClose()
        }

        func popoverDidClose(_ notification: Notification) {
            guard !isClosingProgrammatically, popover != nil else { return }
            didClose()
            parent?.onDismiss()
        }

        /// The note now carries the highlight; the raw selection would just
        /// sit on top of it.
        private func didClose() {
            popover = nil
            hosting = nil
            shownAnchor = nil
            if let textView {
                textView.setSelectedRange(NSRange(location: textView.selectedRange().location, length: 0))
            }
        }
    }
}

final class ReviewTextView: NSTextView {
    weak var coordinator: AnyAnnotationCoordinator?

    private static let leftInset: CGFloat = 16
    /// Right margin wide enough for note markers.
    private static let gutter: CGFloat = 40

    init() {
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
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
        minSize = .zero
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        // Symmetric inset sized for both margins; the origin override below
        // moves the text left so the spare width becomes the right gutter.
        textContainerInset = NSSize(width: (Self.leftInset + Self.gutter) / 2, height: 16)
        linkTextAttributes = [
            .foregroundColor: NSColor(Color.dockAccent), .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
        selectedTextAttributes = [.backgroundColor: NSColor(Color.dockAccent).withAlphaComponent(0.3)]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var textContainerOrigin: NSPoint {
        NSPoint(x: Self.leftInset, y: textContainerInset.height)
    }

    /// NSTextView tracks the whole drag inside `super.mouseDown`, so the
    /// selection is final once it returns — that is the "highlight done" moment.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let marker = markers().first(where: { $0.rect.insetBy(dx: -3, dy: -3).contains(point) }) {
            coordinator?.open(marker.highlight)
            return
        }
        super.mouseDown(with: event)
        coordinator?.mouseUp(in: self, at: point)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let accent = NSColor(Color.dockAccent)
        for marker in markers() where marker.rect.intersects(dirtyRect) {
            let active = marker.highlight.style == .active
            let path = NSBezierPath(
                roundedRect: marker.rect, xRadius: marker.rect.height / 2, yRadius: marker.rect.height / 2)
            (active ? accent : accent.withAlphaComponent(0.22)).setFill()
            path.fill()
            let label = "\(marker.highlight.number ?? 0)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: active ? NSColor(Color.dockOnAccentText) : accent,
            ]
            let size = label.size(withAttributes: attributes)
            label.draw(
                at: NSPoint(x: marker.rect.midX - size.width / 2, y: marker.rect.midY - size.height / 2),
                withAttributes: attributes)
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard let coordinator, let layout = layoutManager, let container = textContainer else { return }
        let origin = textContainerOrigin
        for highlight in coordinator.appliedHighlights where NSMaxRange(highlight.range) <= string.utf16.count {
            let glyphs = layout.glyphRange(forCharacterRange: highlight.range, actualCharacterRange: nil)
            layout.enumerateEnclosingRects(
                forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container
            ) { rect, _ in
                self.addCursorRect(rect.offsetBy(dx: origin.x, dy: origin.y), cursor: .pointingHand)
            }
        }
        for marker in markers() { addCursorRect(marker.rect, cursor: .pointingHand) }
    }

    /// Margin markers beside each numbered highlight's first line; markers on
    /// the same line sit side by side.
    private func markers() -> [(highlight: AnnotationHighlight, rect: NSRect)] {
        guard let coordinator else { return [] }
        var result: [(highlight: AnnotationHighlight, rect: NSRect)] = []
        for highlight in coordinator.appliedHighlights.filter({ $0.number != nil }).sorted(by: {
            $0.number! < $1.number!
        }) {
            guard let line = firstLineRect(for: highlight.range) else { continue }
            let size = NSSize(width: 18, height: 16)
            var x = bounds.maxX - Self.gutter + 10
            while result.contains(where: { abs($0.rect.minX - x) < 1 && abs($0.rect.midY - line.midY) < 4 }) {
                x += size.width - 6
            }
            result.append(
                (highlight, NSRect(x: x, y: line.midY - size.height / 2, width: size.width, height: size.height)))
        }
        return result
    }

    private func firstLineRect(for range: NSRange) -> NSRect? {
        lineRects(for: range).first
    }

    /// The selection's last line, so the popover sits right under where the
    /// highlight ends instead of under a tall multi-line box.
    func lastLineRect(for range: NSRange) -> NSRect? {
        lineRects(for: range).last
    }

    private func lineRects(for range: NSRange) -> [NSRect] {
        guard let layout = layoutManager, let container = textContainer, NSMaxRange(range) <= string.utf16.count else {
            return []
        }
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rects: [NSRect] = []
        layout.enumerateEnclosingRects(
            forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container
        ) { rect, _ in
            rects.append(rect)
        }
        let origin = textContainerOrigin
        return rects.map { $0.offsetBy(dx: origin.x, dy: origin.y) }
    }
}

/// Type-erased so the non-generic text view can talk to the generic coordinator.
@MainActor
protocol AnyAnnotationCoordinator: AnyObject {
    func mouseUp(in textView: NSTextView, at point: NSPoint)
    func open(_ highlight: AnnotationHighlight)
    var appliedHighlights: [AnnotationHighlight] { get }
}

extension AnnotatableDocumentView.Coordinator: AnyAnnotationCoordinator {}
