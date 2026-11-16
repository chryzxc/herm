import AppKit
import SwiftUI

private func diffBlameEntry(_ line: DiffLine?, side: String?, blame: DiffBlame) -> RepositoryBlameLine? {
    guard let line else { return nil }
    let entry =
        side == "LEFT" || (side == nil && line.newLine == nil)
        ? line.oldLine.flatMap { blame.old[$0] } : line.newLine.flatMap { blame.new[$0] }
    guard let entry, entry.text == DiffDocument.source(line) else { return nil }
    return entry
}

private func blameDetails(_ entry: RepositoryBlameLine) -> String {
    let commit = entry.commit
    guard !commit.isUncommitted else { return "Uncommitted changes" }
    return [
        commit.author, commit.authoredAt?.formatted(date: .abbreviated, time: .shortened), commit.hash, commit.summary,
    ]
    .compactMap { $0 }.joined(separator: " · ")
}

struct NativeDiffCanvas: NSViewRepresentable {
    @Environment(\.dockWorkspaceScale) private var workspaceScale
    let document: DiffDocument
    let split: Bool
    let wraps: Bool
    let wordDiffs: Bool
    let findRequest: Int
    var reveal: DiffSearchMatch? = nil
    var viewport: DiffViewportState? = nil
    var blame = DiffBlame()
    let onNote: ((DiffSelection) -> Void)?
    let onComment: ((DiffLine) -> Void)?
    var noteMarks: [DiffNoteMark] = []
    var onEditNote: ((UUID) -> Bool)? = nil
    var noteEditor: ((@escaping () -> Void) -> DiffNoteEditor)? = nil
    func makeNSView(context: Context) -> DiffCanvasContainer { DiffCanvasContainer() }
    func updateNSView(_ view: DiffCanvasContainer, context: Context) {
        view.update(
            document, split: split, wraps: wraps, wordDiffs: wordDiffs, findRequest: findRequest, reveal: reveal,
            viewport: viewport, blame: blame,
            onNote: onNote, onComment: onComment, noteMarks: noteMarks, onEditNote: onEditNote, noteEditor: noteEditor,
            textScale: workspaceScale)
    }
}

/// A saved revision note drawn on the diff rows it captured.
struct DiffNoteMark: Equatable {
    let id: UUID
    let lineIndexes: Set<Int>
    let side: String?
}

/// Popover content plus what to do if it closes without saving (click-away, Esc).
struct DiffNoteEditor {
    let view: AnyView
    let dismissed: () -> Void
}

final class DiffCanvasContainer: NSView {
    private let stack = NSStackView()
    private var textScale: CGFloat = 1
    private var codeFont: NSFont {
        .monospacedSystemFont(ofSize: DockTypography.size(.code, scale: textScale), weight: .regular)
    }
    private var codeAttributes: [NSAttributedString.Key: Any] {
        var attributes = CodeSyntaxHighlighter.baseAttributes
        attributes[.font] = codeFont
        return attributes
    }
    private var fingerprint = ""
    private var findRevision = 0
    private var alignmentKey = ""
    private var sizingKey = ""
    private var revealedID: String?
    private var lastViewportRestore = -1
    private var previousPath: String?
    private var pendingScroll: [NSPoint] = []
    private var tasks: [Task<Void, Never>] = []
    override init(frame: NSRect) {
        super.init(frame: frame)
        stack.orientation = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 1
        addSubview(stack)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    static func wrappedTextWidth(in scroll: NSScrollView) -> CGFloat {
        scroll.contentSize.width - (scroll.rulersVisible ? scroll.verticalRulerView?.ruleThickness ?? 0 : 0)
    }
    override func layout() {
        super.layout()
        stack.frame = bounds
        stack.layoutSubtreeIfNeeded()
        // Whole-document sizing only changes with content or column width; scrolling re-enters layout.
        let scrolls = stack.arrangedSubviews.compactMap { $0 as? NSScrollView }
        let key = fingerprint + ":" + scrolls.map { String(Double($0.contentSize.width)) }.joined(separator: ",")
        if sizingKey != key {
            sizingKey = key
            for scroll in scrolls {
                guard let text = scroll.documentView as? NSTextView else { continue }
                // The line ruler floats over the clip view, so wrapped text fits the width beside it.
                let width = max(100, Self.wrappedTextWidth(in: scroll))
                // Wrapped text tracks its view's width, so the container follows the frame.
                if !text.isHorizontallyResizable { text.frame.size.width = width }
                text.sizeToFit()
                if !text.isHorizontallyResizable { text.frame.size.width = width }
            }
        }
        alignWrappedRows()
        if !pendingScroll.isEmpty {
            for (index, view) in stack.arrangedSubviews.enumerated() {
                if pendingScroll.indices.contains(index), let scroll = view as? NSScrollView {
                    scroll.layoutSubtreeIfNeeded()
                    scroll.contentView.scroll(to: pendingScroll[index])
                    scroll.reflectScrolledClipView(scroll.contentView)
                }
            }
            pendingScroll = []
        }
    }
    private struct GutterInput: Equatable {
        let identity: String
        let split: Bool
        let textScale: CGFloat
        let hasComment: Bool
        let blame: DiffBlame
    }
    private struct GutterLayout {
        let rows: [DiffSplitRow]
        let columns: [[DiffLine?]]
        let blameWidths: [CGFloat]
        let gutterWidths: [CGFloat]
    }
    private var gutterCache: (input: GutterInput, layout: GutterLayout)?
    /// Stands in for the blame in the fingerprint: interpolating the blame
    /// maps into the key would describe every entry on each SwiftUI update.
    private var blameRevision = 0

    /// Split rows and gutter widths scan every line; SwiftUI calls `update` on
    /// unrelated state changes, so they are recomputed only when an input
    /// changes. The same blame value shares storage, so equality is cheap.
    private func gutterLayout(_ input: GutterInput, document: DiffDocument) -> GutterLayout {
        if let cache = gutterCache, cache.input == input { return cache.layout }
        if gutterCache?.input.blame != input.blame { blameRevision &+= 1 }
        let split = input.split
        let digits = max(
            1,
            document.lines.lazy.flatMap { [$0.oldLine, $0.newLine].compactMap { $0 } }
                .map { String($0).count }.max() ?? 1)
        let font = NSFont.monospacedSystemFont(
            ofSize: DockTypography.size(.metadata, scale: input.textScale), weight: .regular)
        let digitWidth = ("0" as NSString).size(withAttributes: [.font: font]).width
        let rows = DiffPresentation.splitRows(document.lines)
        let columns: [[DiffLine?]] =
            split ? [rows.map(\.left), rows.map(\.right)] : [document.lines.map(Optional.some)]
        let hasBlame = !input.blame.old.isEmpty || !input.blame.new.isEmpty
        let blameWidths: [CGFloat] = columns.enumerated().map { index, column in
            guard hasBlame else { return 0 }
            let side = split ? (index == 0 ? "LEFT" : "RIGHT") : nil
            return column.contains { diffBlameEntry($0, side: side, blame: input.blame) != nil } ? 128 : 0
        }
        let numberWidth =
            ceil(18 + CGFloat(digits * (split ? 1 : 2) + (split ? 0 : 2)) * digitWidth)
            + (input.hasComment ? 24 : 0)
        let layout = GutterLayout(
            rows: rows, columns: columns, blameWidths: blameWidths, gutterWidths: blameWidths.map { $0 + numberWidth })
        gutterCache = (input, layout)
        return layout
    }

    private func alignWrappedRows() {
        let key = fingerprint + ":" + String(Double(bounds.width))
        guard alignmentKey != key, stack.arrangedSubviews.count == 2 else { return }
        alignmentKey = key
        let texts = stack.arrangedSubviews.compactMap { ($0 as? NSScrollView)?.documentView as? DiffSelectableTextView }
        guard texts.count == 2, texts.allSatisfy({ !$0.isHorizontallyResizable }) else { return }
        let base = CodeSyntaxHighlighter.baseAttributes[.paragraphStyle] as? NSParagraphStyle ?? .default
        let font = codeFont
        let heights = texts.map { text in
            text.lines.map { line -> CGFloat in
                let value = line.map(DiffDocument.source) ?? ""
                let measured = (value.isEmpty ? " " : value) as NSString
                return ceil(
                    measured.boundingRect(
                        with: NSSize(
                            width: max(1, text.bounds.width - text.textContainerInset.width * 2 - 10),
                            height: .greatestFiniteMagnitude),
                        options: [.usesLineFragmentOrigin, .usesFontLeading],
                        attributes: [.font: font, .paragraphStyle: base]
                    ).height)
            }
        }
        for (column, text) in texts.enumerated() {
            guard let storage = text.textStorage else { continue }
            var offset = 0
            storage.beginEditing()
            for index in text.lines.indices {
                let length = ((text.lines[index].map(DiffDocument.source) ?? "") as NSString).length
                let style = base.mutableCopy() as! NSMutableParagraphStyle
                style.paragraphSpacing = max(0, max(heights[0][index], heights[1][index]) - heights[column][index])
                let range = NSRange(location: offset, length: min(length + 1, storage.length - offset))
                if range.length > 0 { storage.addAttribute(.paragraphStyle, value: style, range: range) }
                offset += length + 1
            }
            storage.endEditing()
            text.sizeToFit()
        }
    }
    func update(
        _ document: DiffDocument, split: Bool, wraps: Bool, wordDiffs: Bool, findRequest: Int, reveal: DiffSearchMatch?,
        viewport: DiffViewportState?, blame: DiffBlame = DiffBlame(),
        onNote: ((DiffSelection) -> Void)?, onComment: ((DiffLine) -> Void)?,
        noteMarks: [DiffNoteMark] = [], onEditNote: ((UUID) -> Bool)? = nil,
        noteEditor: ((@escaping () -> Void) -> DiffNoteEditor)? = nil, textScale: CGFloat = 1
    ) {
        self.textScale = textScale
        let split = split && document.supportsSplitView
        let layout = gutterLayout(
            GutterInput(
                identity: document.identity, split: split, textScale: textScale, hasComment: onComment != nil,
                blame: blame),
            document: document)
        let (rows, columns, blameWidths, gutterWidths) =
            (layout.rows, layout.columns, layout.blameWidths, layout.gutterWidths)
        let key =
            "\(textScale):\(document.identity):\(split):\(wraps):\(wordDiffs):\(DockThemeRuntime.revision):\(viewport?.restorationRevision ?? 0):\(blameRevision)"
        if fingerprint == key {
            // A revision can change without changing the patch. Rebind actions while keeping selection and scroll.
            for (index, view) in stack.arrangedSubviews.enumerated() {
                guard let scroll = view as? NSScrollView, gutterWidths.indices.contains(index) else { continue }
                let gutterWidth = gutterWidths[index]
                guard let text = scroll.documentView as? DiffSelectableTextView else { continue }
                text.blame = blame
                text.onNote = onNote
                text.noteEditor = noteEditor
                text.onEditNote = onEditNote
                text.noteMarks = noteMarks
                text.onComment = onComment
                if let ruler = scroll.verticalRulerView {
                    let wasAtStart = scroll.contentView.bounds.minX <= -ruler.ruleThickness + 0.5
                    let changed = ruler.ruleThickness != gutterWidth
                    ruler.ruleThickness = gutterWidth
                    ruler.needsDisplay = true
                    if changed {
                        sizingKey = ""
                        alignmentKey = ""
                        if wasAtStart {
                            scroll.contentView.scroll(to: NSPoint(x: -gutterWidth, y: scroll.contentView.bounds.minY))
                        }
                        needsLayout = true
                    }
                }
            }
        }
        if fingerprint != key {
            let previous = stack.arrangedSubviews.enumerated().compactMap { index, view -> NSPoint? in
                guard let scroll = view as? NSScrollView else { return nil }
                var origin = scroll.contentView.bounds.origin
                if gutterWidths.indices.contains(index),
                    origin.x <= -(scroll.verticalRulerView?.ruleThickness ?? 0) + 0.5
                {
                    origin.x = -gutterWidths[index]
                }
                return origin
            }
            let restored =
                viewport?.comparison == document.identity && lastViewportRestore != viewport?.restorationRevision
            pendingScroll = restored ? (viewport?.origins ?? []) : previousPath == document.path ? previous : []
            lastViewportRestore = viewport?.restorationRevision ?? 0
            if viewport?.comparison != document.identity { viewport?.origins = pendingScroll }
            viewport?.comparison = document.identity
            previousPath = document.path
            fingerprint = key
            alignmentKey = ""
            revealedID = nil
            for task in tasks { task.cancel() }
            tasks = []
            for subview in stack.arrangedSubviews {
                stack.removeArrangedSubview(subview)
                subview.removeFromSuperview()
            }
            var counterparts: [Int: String] = [:]
            for row in rows {
                if let left = row.left, let right = row.right, left.kind == .deletion, right.kind == .addition {
                    counterparts[left.index] = DiffDocument.source(right)
                    counterparts[right.index] = DiffDocument.source(left)
                }
            }
            // Overlay rulers inset the document; zero would hide source underneath the gutter.
            pendingScroll = columns.indices.map {
                pendingScroll.indices.contains($0) ? pendingScroll[$0] : NSPoint(x: -gutterWidths[$0], y: 0)
            }
            for (columnIndex, column) in columns.enumerated() {
                let gutterWidth = gutterWidths[columnIndex]
                let scroll = NSScrollView()
                let text = DiffSelectableTextView()
                text.lines = column
                text.side = split ? (columnIndex == 0 ? "LEFT" : "RIGHT") : nil
                text.blame = blame
                text.onNote = onNote
                text.noteEditor = noteEditor
                text.onEditNote = onEditNote
                text.noteMarks = noteMarks
                text.onComment = onComment
                text.frame = NSRect(
                    x: 0, y: 0, width: max(100, bounds.width / CGFloat(columns.count) - gutterWidth), height: 100)
                text.minSize = NSSize(width: 0, height: 100)
                text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
                text.isEditable = false
                text.isSelectable = true
                text.isRichText = false
                text.usesFindBar = true
                text.isIncrementalSearchingEnabled = true
                text.font = codeFont
                text.backgroundColor = NSColor(Color.dockCanvas)
                text.textContainerInset = NSSize(width: 8, height: 8)
                text.isVerticallyResizable = true
                text.isHorizontallyResizable = !wraps
                text.autoresizingMask = wraps ? [.width] : []
                text.textContainer?.widthTracksTextView = wraps
                text.textContainer?.containerSize = NSSize(
                    width: wraps
                        ? max(100, bounds.width / CGFloat(columns.count) - gutterWidth) : .greatestFiniteMagnitude,
                    height: .greatestFiniteMagnitude)
                text.string = column.map { $0.map(DiffDocument.source) ?? "" }.joined(separator: "\n")
                text.textStorage?.addAttributes(
                    codeAttributes,
                    range: NSRange(location: 0, length: (text.string as NSString).length))
                text.applyNoteMarks()
                let clip = DiffSyncedClipView()
                clip.onScroll = { [weak viewport] point in viewport?.record(point, column: columnIndex) }
                scroll.contentView = clip
                scroll.documentView = text
                scroll.hasVerticalScroller = !split || columnIndex == columns.count - 1
                scroll.hasHorizontalScroller = !wraps
                scroll.autohidesScrollers = true
                scroll.drawsBackground = true
                scroll.backgroundColor = text.backgroundColor
                let ruler = DiffLineRuler(scrollView: scroll, orientation: .verticalRuler)
                ruler.clientView = text
                ruler.text = text
                ruler.side = text.side
                ruler.blame = blame
                ruler.blameWidth = blameWidths[columnIndex]
                ruler.ruleThickness = gutterWidth
                scroll.verticalRulerView = ruler
                scroll.hasVerticalRuler = true
                scroll.rulersVisible = true
                stack.addArrangedSubview(scroll)
                if let first = stack.arrangedSubviews.first as? NSScrollView, first !== scroll,
                    let left = first.contentView as? DiffSyncedClipView,
                    let right = scroll.contentView as? DiffSyncedClipView
                {
                    left.peer = right
                    right.peer = left
                }
                let source = text.string
                let attributes = codeAttributes
                tasks.append(
                    Task { @MainActor [weak text] in
                        let preparation = Task.detached(priority: .userInitiated) { [counterparts] in
                            let tokens = CodeTokenizer.tokens(in: source, language: CodeLanguage(path: document.path))
                            var ranges: [Int: [NSRange]] = [:]
                            if wordDiffs {
                                for case let line? in column {
                                    if Task.isCancelled { break }
                                    if let previous = counterparts[line.index] {
                                        ranges[line.index] = DiffDocument.changedWordRanges(
                                            DiffDocument.source(line), comparedWith: previous)
                                    }
                                }
                            }
                            return (tokens, ranges)
                        }
                        let (tokens, wordRanges) = await withTaskCancellationHandler {
                            await preparation.value
                        } onCancel: {
                            preparation.cancel()
                        }
                        guard !Task.isCancelled, let text, text.string == source, let storage = text.textStorage else {
                            return
                        }
                        storage.addAttributes(
                            attributes.filter { $0.key != .paragraphStyle },
                            range: NSRange(location: 0, length: storage.length))
                        for (range, token) in tokens {
                            storage.addAttribute(.foregroundColor, value: token.color, range: range)
                        }
                        var offset = 0
                        for line in column {
                            let value = line.map(DiffDocument.source) ?? ""
                            let length = (value as NSString).length
                            let tint: Color =
                                line?.kind == .addition
                                ? .dockSuccess : line?.kind == .deletion ? .dockDestructive : .dockCanvas
                            storage.addAttribute(
                                .backgroundColor, value: NSColor(tint.opacity(0.14)),
                                range: NSRange(location: offset, length: length))
                            if let line {
                                for range in wordRanges[line.index] ?? [] {
                                    storage.addAttribute(
                                        .backgroundColor, value: NSColor(tint.opacity(0.35)),
                                        range: NSRange(location: offset + range.location, length: range.length))
                                }
                            }
                            offset += length + 1
                        }
                        text.sizeToFit()
                        text.applyNoteMarks()
                    })
            }
        }
        if let reveal, revealedID != reveal.id {
            for case let scroll as NSScrollView in stack.arrangedSubviews {
                guard let text = scroll.documentView as? DiffSelectableTextView,
                    let index = text.lines.firstIndex(where: { $0?.index == reveal.lineIndex })
                else { continue }
                let offset = text.lineOffsets.starts[index]
                let range = NSRange(location: offset + reveal.range.location, length: reveal.range.length)
                guard NSMaxRange(range) <= (text.string as NSString).length else { continue }
                text.setSelectedRange(range)
                text.scrollRangeToVisible(range)
                revealedID = reveal.id
            }
        }
        if findRevision != findRequest {
            findRevision = findRequest
            if let scroll = stack.arrangedSubviews.first as? NSScrollView, let text = scroll.documentView as? NSTextView
            {
                window?.makeFirstResponder(text)
                let item = NSMenuItem()
                item.tag = NSTextFinder.Action.showFindInterface.rawValue
                text.performTextFinderAction(item)
            }
        }
    }
}

private final class DiffSelectableTextView: NSTextView {
    var lines: [DiffLine?] = [] {
        didSet {
            lineOffsets = DiffLineOffsets(
                lengths: lines.map { (($0.map(DiffDocument.source) ?? "") as NSString).length })
        }
    }
    private(set) var lineOffsets = DiffLineOffsets(lengths: [])
    var side: String?
    var blame = DiffBlame()
    private var copiedBlame: String?
    var onNote: ((DiffSelection) -> Void)?
    var onComment: ((DiffLine) -> Void)?
    private var captured = DiffSelection(lines: [])
    var noteEditor: ((@escaping () -> Void) -> DiffNoteEditor)?
    var onEditNote: ((UUID) -> Bool)?
    var noteMarks: [DiffNoteMark] = [] { didSet { if noteMarks != oldValue { applyNoteMarks() } } }
    private var notePopover: NSPopover?
    private var noteDismissed: (() -> Void)?

    func noteMark(atRow row: Int) -> DiffNoteMark? {
        guard lines.indices.contains(row), let line = lines[row] else { return nil }
        return noteMarks.first {
            $0.lineIndexes.contains(line.index) && ($0.side == nil || side == nil || $0.side == side)
        }
    }
    func characterRange(ofRow row: Int) -> NSRange {
        let length = (string as NSString).length
        let start = min(lineOffsets.starts[row], length)
        let end = row + 1 < lineOffsets.starts.count ? lineOffsets.starts[row + 1] - 1 : length
        return NSRange(location: start, length: max(0, min(end, length) - start))
    }
    /// Annotated rows carry the annotator's draft tint; temporary attributes sit above the diff tint.
    func applyNoteMarks() {
        guard let layoutManager else { return }
        layoutManager.removeTemporaryAttribute(
            .backgroundColor, forCharacterRange: NSRange(location: 0, length: (string as NSString).length))
        let tint = NSColor(Color.dockAccent).withAlphaComponent(0.18)
        for row in lines.indices where noteMark(atRow: row) != nil {
            layoutManager.addTemporaryAttribute(
                .backgroundColor, value: tint, forCharacterRange: characterRange(ofRow: row))
        }
        enclosingScrollView?.verticalRulerView?.needsDisplay = true
    }

    private func captureSelection() {
        let rows = DiffTextSelection.rowRange(in: string, selection: selectedRange())
        captured = DiffSelection(
            lines: lines.enumerated().compactMap { index, line in rows.contains(index) ? line : nil }, side: side)
    }
    /// NSTextView tracks the whole drag inside `super.mouseDown`, so the selection is final once it
    /// returns. Highlighting opens the note popover, matching the markdown/text annotator.
    /// A plain click on an annotated row reopens its note.
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        let range = selectedRange()
        if range.length > 0 {
            if onNote != nil {
                captureSelection()
                addNote()
            }
            return
        }
        guard event.clickCount == 1, !lines.isEmpty else { return }
        let row = lineOffsets.row(containing: range.location)
        guard let mark = noteMark(atRow: row), onEditNote?(mark.id) == true else { return }
        let last = lines.indices.last { noteMark(atRow: $0) == mark } ?? row
        presentNotePopover(at: lineOffsets.starts[last])
    }
    private func presentNotePopover(at index: Int) {
        // Detach first so closing the previous popover cannot discard the note this one edits.
        let previous = notePopover
        notePopover = nil
        previous?.close()
        let length = (string as NSString).length
        guard let noteEditor, let layoutManager, length > 0, window != nil else { return }
        let last = layoutManager.lineFragmentUsedRect(
            forGlyphAt: layoutManager.glyphIndexForCharacter(at: min(max(0, index), length - 1)), effectiveRange: nil)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        let editor = noteEditor { [weak popover] in popover?.close() }
        noteDismissed = editor.dismissed
        let hosting = NSHostingController(rootView: editor.view.dockPresentationSurface())
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting
        popover.delegate = self
        notePopover = popover
        popover.show(
            relativeTo: last.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y), of: self,
            preferredEdge: .maxY)
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        // AppKit may re-select the word under the pointer; notes act on the highlighted code.
        let highlighted = selectedRange()
        let menu = super.menu(for: event) ?? NSMenu()
        if highlighted.length > 0 {
            setSelectedRange(highlighted)
        } else if selectedRange().length == 0, event.type == .rightMouseDown {
            setSelectedRange(
                NSRange(location: characterIndexForInsertion(at: convert(event.locationInWindow, from: nil)), length: 0)
            )
        }
        captureSelection()
        copiedBlame = captured.lines.first.flatMap { diffBlameEntry($0, side: side, blame: blame) }.map(blameDetails)
        if copiedBlame != nil {
            let item = NSMenuItem(title: "Copy blame details", action: #selector(copyBlame), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        if onNote != nil {
            let item = NSMenuItem(title: "Add revision note", action: #selector(addNote), keyEquivalent: "")
            item.target = self
            item.isEnabled = captured.first != nil
            menu.addItem(item)
        }
        if onComment != nil {
            let comment = NSMenuItem(title: "Comment on GitHub…", action: #selector(commentOnLine), keyEquivalent: "")
            comment.target = self
            comment.isEnabled = captured.first != nil
            menu.addItem(comment)
        }
        return menu
    }
    override func writeSelection(to pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard type == .string else { return super.writeSelection(to: pasteboard, type: type) }
        return pasteboard.setString(DiffTextSelection.source(lines: lines, range: selectedRange()), forType: .string)
    }
    /// Uses the selection captured by the menu or `mouseDown`; the menu may move the caret before it fires.
    @objc private func addNote() {
        guard captured.first != nil else { return }
        onNote?(captured)
        // Anchor under the selection's last line; a right-click selection can be empty.
        let range = selectedRange()
        presentNotePopover(at: max(NSMaxRange(range) - 1, range.location))
    }
    @objc private func commentOnLine() {
        if var first = captured.first {
            if side == "LEFT" { first.newLine = nil } else if side == "RIGHT" { first.oldLine = nil }
            onComment?(first)
        }
    }
    @objc private func copyBlame() {
        guard let copiedBlame else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copiedBlame, forType: .string)
    }
}

extension DiffSelectableTextView: NSPopoverDelegate {
    /// Click-away or Esc discards the draft, like the annotator; the selection would sit on top of it.
    func popoverDidClose(_ notification: Notification) {
        guard (notification.object as? NSPopover) === notePopover else { return }
        notePopover = nil
        noteDismissed?()
        noteDismissed = nil
        setSelectedRange(NSRange(location: selectedRange().location, length: 0))
    }
}

private final class DiffLineRuler: NSRulerView {
    weak var text: DiffSelectableTextView?
    var side: String?
    var blame = DiffBlame()
    var blameWidth: CGFloat = 0
    private var commentButtons: [Int: DiffLineCommentButton] = [:]
    private var blameAccessibility: [NSAccessibilityElement] = []
    override func accessibilityChildren() -> [Any]? {
        (super.accessibilityChildren() ?? []) + blameAccessibility
    }
    override var isFlipped: Bool { true }
    override var requiredThickness: CGFloat { ruleThickness }
    override func draw(_ dirtyRect: NSRect) {
        drawHashMarksAndLabels(in: dirtyRect)
    }
    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let text, let manager = text.layoutManager, let container = text.textContainer,
            manager.numberOfGlyphs > 0
        else {
            blameAccessibility = []
            for button in commentButtons.values { button.removeFromSuperview() }
            commentButtons.removeAll()
            return
        }
        NSColor(Color.dockSurface2).setFill()
        bounds.fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(
                ofSize: DockTypography.size(
                    .metadata,
                    scale: (text.font?.pointSize ?? CodeSyntaxHighlighter.fontSize) / CodeSyntaxHighlighter.fontSize),
                weight: .regular),
            .foregroundColor: NSColor(Color.dockMetadataText),
        ]
        let visible = text.visibleRect.offsetBy(dx: -text.textContainerInset.width, dy: -text.textContainerInset.height)
        let glyphs = manager.glyphRange(forBoundingRect: visible, in: container)
        let character = manager.characterIndexForGlyph(at: min(glyphs.location, manager.numberOfGlyphs - 1))
        let first = text.lineOffsets.row(containing: character)
        let length = (text.string as NSString).length
        var visibleComments = Set<Int>()
        var accessibility: [NSAccessibilityElement] = []
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        var blameAttributes = attributes
        blameAttributes[.paragraphStyle] = paragraph
        for index in first..<text.lines.count {
            let line = text.lines[index]
            let offset = text.lineOffsets.starts[index]
            let glyph = manager.glyphIndexForCharacter(at: min(offset, max(0, length - 1)))
            let frame = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let y = convert(NSPoint(x: 0, y: frame.minY + text.textContainerOrigin.y), from: text).y
            if y > bounds.maxY { break }
            if y + frame.height >= bounds.minY {
                let sign = line?.kind == .addition ? "+" : line?.kind == .deletion ? "−" : " "
                let numbers =
                    side == "LEFT"
                    ? (line?.oldLine.map(String.init) ?? "")
                    : side == "RIGHT"
                        ? (line?.newLine.map(String.init) ?? "")
                        : "\(line?.oldLine.map(String.init) ?? "")  \(line?.newLine.map(String.init) ?? "")"
                let label = "\(sign) \(numbers)" as NSString
                label.draw(at: NSPoint(x: blameWidth + 4, y: y), withAttributes: attributes)
                if let entry = diffBlameEntry(line, side: side, blame: blame), blameWidth > 0 {
                    let commit = entry.commit
                    let rect = NSRect(x: 4, y: y, width: blameWidth - 8, height: frame.height)
                    if !commit.isUncommitted, let date = commit.authoredAt {
                        let dateText = date.formatted(.dateTime.month(.abbreviated).year()) as NSString
                        let dateWidth = min(rect.width * 0.55, dateText.size(withAttributes: blameAttributes).width)
                        (commit.author as NSString).draw(
                            in: NSRect(x: rect.minX, y: y, width: rect.width - dateWidth - 6, height: rect.height),
                            withAttributes: blameAttributes)
                        dateText.draw(
                            in: NSRect(x: rect.maxX - dateWidth, y: y, width: dateWidth, height: rect.height),
                            withAttributes: blameAttributes)
                    } else {
                        let title = commit.isUncommitted ? "Uncommitted changes" : commit.author
                        (title as NSString).draw(in: rect, withAttributes: blameAttributes)
                    }
                    if let window {
                        let screenRect = window.convertToScreen(convert(rect, to: nil))
                        let element = NSAccessibilityElement()
                        element.setAccessibilityRole(.staticText)
                        element.setAccessibilityFrame(screenRect)
                        element.setAccessibilityLabel(blameDetails(entry))
                        element.setAccessibilityParent(self)
                        accessibility.append(element)
                    }
                }
                if text.noteMark(atRow: index) != nil {
                    let glyphs = manager.glyphRange(
                        forCharacterRange: text.characterRange(ofRow: index), actualCharacterRange: nil)
                    let height = max(frame.height, manager.boundingRect(forGlyphRange: glyphs, in: container).height)
                    NSColor(Color.dockAccent).setFill()
                    NSRect(x: 0, y: y, width: 3, height: height).fill()
                }
                if let line, text.onComment != nil, line.oldLine != nil || line.newLine != nil {
                    visibleComments.insert(line.index)
                    let button = commentButtons[line.index] ?? DiffLineCommentButton()
                    if button.superview == nil { addSubview(button) }
                    commentButtons[line.index] = button
                    button.frame = NSRect(x: ruleThickness - 23, y: y, width: 22, height: max(20, frame.height))
                    var target = line
                    if side == "LEFT" { target.newLine = nil }
                    if side == "RIGHT" { target.oldLine = nil }
                    let captured = target
                    button.onPress = { [weak text] in text?.onComment?(captured) }
                    let location =
                        "\(target.newLine == nil ? "old" : "new") line \(target.newLine ?? target.oldLine ?? 0)"
                    button.toolTip = "Add review comment on \(location)"
                    button.setAccessibilityLabel("Add review comment on \(location)")
                }
            }
        }
        for key in Array(commentButtons.keys) where !visibleComments.contains(key) {
            commentButtons.removeValue(forKey: key)?.removeFromSuperview()
        }
        blameAccessibility = accessibility
        _ = container
    }
}

private final class DiffLineCommentButton: NSButton {
    var onPress: (() -> Void)?

    init() {
        super.init(frame: .zero)
        title = "+"
        font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
        isBordered = false
        contentTintColor = NSColor(Color.dockAccent)
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(press)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func press() { onPress?() }
}

private final class DiffSyncedClipView: NSClipView {
    weak var peer: DiffSyncedClipView?
    var onScroll: ((NSPoint) -> Void)?
    private var syncing = false
    override func constrainBoundsRect(_ proposed: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposed)
        if let own = documentView?.frame.height, let other = peer?.documentView?.frame.height, other > own {
            rect.origin.y = min(max(proposed.origin.y, 0), max(0, other - bounds.height))
        }
        return rect
    }
    override func scroll(to newOrigin: NSPoint) {
        super.scroll(to: newOrigin)
        onScroll?(bounds.origin)
        guard !syncing, let peer else { return }
        peer.syncing = true
        peer.scroll(to: NSPoint(x: peer.bounds.minX, y: newOrigin.y))
        peer.enclosingScrollView?.reflectScrolledClipView(peer)
        peer.syncing = false
    }
}
