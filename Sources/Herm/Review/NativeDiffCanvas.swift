import AppKit
import SwiftUI

struct NativeDiffCanvas: NSViewRepresentable {
    let document: DiffDocument
    let split: Bool
    let wraps: Bool
    let wordDiffs: Bool
    let findRequest: Int
    var reveal: DiffSearchMatch? = nil
    var viewport: DiffViewportState? = nil
    let onNote: (DiffSelection) -> Void
    let onComment: ((DiffLine) -> Void)?
    func makeNSView(context: Context) -> DiffCanvasContainer { DiffCanvasContainer() }
    func updateNSView(_ view: DiffCanvasContainer, context: Context) {
        view.update(
            document, split: split, wraps: wraps, wordDiffs: wordDiffs, findRequest: findRequest, reveal: reveal,
            viewport: viewport,
            onNote: onNote, onComment: onComment)
    }
}

final class DiffCanvasContainer: NSView {
    private let stack = NSStackView()
    private var fingerprint = ""
    private var findRevision = 0
    private var alignmentKey = ""
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
    override func layout() {
        super.layout()
        stack.frame = bounds
        stack.layoutSubtreeIfNeeded()
        for case let scroll as NSScrollView in stack.arrangedSubviews {
            guard let text = scroll.documentView as? NSTextView else { continue }
            if !text.isHorizontallyResizable {
                let width = max(100, scroll.contentSize.width)
                text.frame.size.width = width
                text.textContainer?.containerSize.width = width
            }
            text.sizeToFit()
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
    private func alignWrappedRows() {
        let key = fingerprint + ":" + String(Double(bounds.width))
        guard alignmentKey != key, stack.arrangedSubviews.count == 2 else { return }
        alignmentKey = key
        let texts = stack.arrangedSubviews.compactMap { ($0 as? NSScrollView)?.documentView as? DiffSelectableTextView }
        guard texts.count == 2, texts.allSatisfy({ !$0.isHorizontallyResizable }) else { return }
        let base = CodeSyntaxHighlighter.baseAttributes[.paragraphStyle] as? NSParagraphStyle ?? .default
        let font = CodeSyntaxHighlighter.font
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
        viewport: DiffViewportState?,
        onNote: @escaping (DiffSelection) -> Void, onComment: ((DiffLine) -> Void)?
    ) {
        let split = split && document.supportsSplitView
        let key =
            "\(document.identity):\(split):\(wraps):\(wordDiffs):\(DockThemeRuntime.revision):\(viewport?.restorationRevision ?? 0)"
        if fingerprint == key {
            // A revision can change without changing the patch. Rebind actions while keeping selection and scroll.
            for case let scroll as NSScrollView in stack.arrangedSubviews {
                guard let text = scroll.documentView as? DiffSelectableTextView else { continue }
                text.onNote = onNote
                text.onComment = onComment
                if let ruler = scroll.verticalRulerView {
                    ruler.ruleThickness = onComment == nil ? 76 : 100
                    ruler.needsDisplay = true
                }
            }
        }
        if fingerprint != key {
            let previous = stack.arrangedSubviews.compactMap { ($0 as? NSScrollView)?.contentView.bounds.origin }
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
            let rows = DiffPresentation.splitRows(document.lines)
            var counterparts: [Int: String] = [:]
            for row in rows {
                if let left = row.left, let right = row.right, left.kind == .deletion, right.kind == .addition {
                    counterparts[left.index] = DiffDocument.source(right)
                    counterparts[right.index] = DiffDocument.source(left)
                }
            }
            let columns: [[DiffLine?]] =
                split ? [rows.map(\.left), rows.map(\.right)] : [document.lines.map(Optional.some)]
            // Overlay rulers inset the document; zero would hide source underneath the gutter.
            let leadingOrigin = NSPoint(x: onComment == nil ? -76 : -100, y: 0)
            pendingScroll = columns.indices.map {
                pendingScroll.indices.contains($0) ? pendingScroll[$0] : leadingOrigin
            }
            for (columnIndex, column) in columns.enumerated() {
                let scroll = NSScrollView()
                let text = DiffSelectableTextView()
                text.lines = column
                text.side = split ? (columnIndex == 0 ? "LEFT" : "RIGHT") : nil
                text.onNote = onNote
                text.onComment = onComment
                text.frame = NSRect(
                    x: 0, y: 0, width: max(100, bounds.width / CGFloat(columns.count) - 90), height: 100)
                text.minSize = NSSize(width: 0, height: 100)
                text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
                text.isEditable = false
                text.isSelectable = true
                text.isRichText = false
                text.usesFindBar = true
                text.isIncrementalSearchingEnabled = true
                text.font = CodeSyntaxHighlighter.font
                text.backgroundColor = NSColor(Color.dockCanvas)
                text.textContainerInset = NSSize(width: 8, height: 8)
                text.isVerticallyResizable = true
                text.isHorizontallyResizable = !wraps
                text.autoresizingMask = wraps ? [.width] : []
                text.textContainer?.widthTracksTextView = wraps
                text.textContainer?.containerSize = NSSize(
                    width: wraps ? max(100, bounds.width / CGFloat(columns.count) - 90) : .greatestFiniteMagnitude,
                    height: .greatestFiniteMagnitude)
                text.string = column.map { $0.map(DiffDocument.source) ?? "" }.joined(separator: "\n")
                text.textStorage?.addAttributes(
                    CodeSyntaxHighlighter.baseAttributes,
                    range: NSRange(location: 0, length: (text.string as NSString).length))
                let clip = DiffSyncedClipView()
                clip.onScroll = { [weak viewport] point in viewport?.record(point, column: columnIndex) }
                scroll.contentView = clip
                scroll.documentView = text
                scroll.hasVerticalScroller = true
                scroll.hasHorizontalScroller = !wraps
                scroll.autohidesScrollers = true
                scroll.drawsBackground = true
                scroll.backgroundColor = text.backgroundColor
                let ruler = DiffLineRuler(scrollView: scroll, orientation: .verticalRuler)
                ruler.clientView = text
                ruler.text = text
                ruler.side = text.side
                ruler.ruleThickness = onComment == nil ? 76 : 100
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
                            CodeSyntaxHighlighter.baseAttributes.filter { $0.key != .paragraphStyle },
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
                    })
            }
        }
        if let reveal, revealedID != reveal.id {
            for case let scroll as NSScrollView in stack.arrangedSubviews {
                guard let text = scroll.documentView as? DiffSelectableTextView,
                    let index = text.lines.firstIndex(where: { $0?.index == reveal.lineIndex })
                else { continue }
                let offset = text.lines.prefix(index).reduce(0) {
                    $0 + (($1.map(DiffDocument.source) ?? "") as NSString).length + 1
                }
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
    var lines: [DiffLine?] = []
    var side: String?
    var onNote: ((DiffSelection) -> Void)?
    var onComment: ((DiffLine) -> Void)?
    private var captured = DiffSelection(lines: [])
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        if selectedRange().length == 0 {
            setSelectedRange(
                NSRange(location: characterIndexForInsertion(at: convert(event.locationInWindow, from: nil)), length: 0)
            )
        }
        let rows = DiffTextSelection.rowRange(in: string, selection: selectedRange())
        captured = DiffSelection(
            lines: lines.enumerated().compactMap { index, line in rows.contains(index) ? line : nil }, side: side)
        let item = NSMenuItem(title: "Add revision note", action: #selector(addNote), keyEquivalent: "")
        item.target = self
        item.isEnabled = captured.first != nil
        menu.addItem(item)
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
    @objc private func addNote() { onNote?(captured) }
    @objc private func commentOnLine() {
        if var first = captured.first {
            if side == "LEFT" { first.newLine = nil } else if side == "RIGHT" { first.oldLine = nil }
            onComment?(first)
        }
    }
}

private final class DiffLineRuler: NSRulerView {
    weak var text: DiffSelectableTextView?
    var side: String?
    private var commentButtons: [Int: DiffLineCommentButton] = [:]
    override var requiredThickness: CGFloat { text?.onComment == nil ? 76 : 100 }
    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let text, let manager = text.layoutManager, let container = text.textContainer,
            manager.numberOfGlyphs > 0
        else {
            commentButtons.values.forEach { $0.removeFromSuperview() }
            commentButtons.removeAll()
            return
        }
        NSColor(Color.dockSurface2).setFill()
        bounds.fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor(Color.dockMetadataText),
        ]
        var offset = 0
        var visibleComments = Set<Int>()
        for line in text.lines {
            let glyph = manager.glyphIndexForCharacter(at: min(offset, max(0, (text.string as NSString).length - 1)))
            let frame = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let y = frame.minY + text.textContainerInset.height - (scrollView?.contentView.bounds.minY ?? 0)
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
                label.draw(at: NSPoint(x: 4, y: y), withAttributes: attributes)
                if let line, text.onComment != nil, line.oldLine != nil || line.newLine != nil {
                    visibleComments.insert(line.index)
                    let button = commentButtons[line.index] ?? DiffLineCommentButton()
                    if button.superview == nil { addSubview(button) }
                    commentButtons[line.index] = button
                    button.frame = NSRect(x: 77, y: y, width: 22, height: max(20, frame.height))
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
            offset += ((line.map(DiffDocument.source) ?? "") as NSString).length + 1
        }
        for key in Array(commentButtons.keys) where !visibleComments.contains(key) {
            commentButtons.removeValue(forKey: key)?.removeFromSuperview()
        }
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
