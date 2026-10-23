@preconcurrency import AppKit
import SwiftUI

struct CodeEditorCursor: Equatable {
    var line = 1
    var column = 1
    var selectedCharacters = 0
}

/// A hovered blame line plus its vertical position (top-down, in editor
/// coordinates) so the SwiftUI layer can place a hover card beside it.
struct CodeEditorBlameHover: Equatable {
    let line: RepositoryBlameLine
    let y: CGFloat
}

/// A VS Code-style source editor: line-number gutter, optional per-block blame
/// annotations, current-line highlight, inline blame for the caret line,
/// syntax highlighting, auto-indent, and the native find bar.
struct CodeEditor: NSViewRepresentable {
    @Binding var text: String
    let filePath: String
    let blame: RepositoryBlameDocument?
    let showsBlameGutter: Bool
    let wrapsLines: Bool
    /// Incrementing this asks the editor to show its find bar.
    let findRequest: Int
    var onCursorChange: (CodeEditorCursor) -> Void = { _ in }
    var onHoverBlame: (CodeEditorBlameHover?) -> Void = { _ in }
    var commitURL: (RepositoryBlameCommit) -> URL? = { _ in nil }

    func makeNSView(context: Context) -> CodeEditorContainerView {
        let view = CodeEditorContainerView(text: text, filePath: filePath)
        view.onTextChanged = { text = $0 }
        apply(to: view)
        return view
    }

    func updateNSView(_ view: CodeEditorContainerView, context: Context) {
        view.onTextChanged = { text = $0 }
        view.setText(text, filePath: filePath)
        apply(to: view)
    }

    private func apply(to view: CodeEditorContainerView) {
        view.applyThemeIfNeeded()
        view.onCursorChange = onCursorChange
        view.gutter.onHoverBlame = onHoverBlame
        view.gutter.commitURL = commitURL
        view.setBlame(blame, showsGutter: showsBlameGutter)
        view.setWrapsLines(wrapsLines)
        view.showFindBarIfNeeded(findRequest)
    }
}

final class CodeEditorContainerView: NSView {
    let scrollView = NSScrollView()
    let textView = CodeTextView(usingTextLayoutManager: false)
    let gutter: CodeGutterView
    var onTextChanged: (String) -> Void = { _ in }
    var onCursorChange: (CodeEditorCursor) -> Void = { _ in }
    private var filePath: String
    private var wrapsLines: Bool?
    private var lastFindRequest = 0
    private var themeRevision: Int?
    private var highlightTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    override var isFlipped: Bool { true }

    init(text: String, filePath: String) {
        self.filePath = filePath
        gutter = CodeGutterView(scrollView: scrollView, orientation: .verticalRuler)
        super.init(frame: .zero)

        textView.string = text
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.insertionPointColor = .codeAccent
        textView.selectedTextAttributes = [.backgroundColor: NSColor.codeAccent.withAlphaComponent(0.28)]
        textView.backgroundColor = .codeCanvas
        textView.drawsBackground = true
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.textContainer?.lineFragmentPadding = 4
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.typingAttributes = CodeSyntaxHighlighter.baseAttributes

        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .codeCanvas
        scrollView.documentView = textView
        scrollView.verticalRulerView = gutter
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        gutter.clientView = textView
        gutter.textView = textView
        addSubview(scrollView)

        textView.recomputeLineStarts()
        CodeSyntaxHighlighter.apply(to: textView, tokens: [])
        scheduleHighlight()

        let center = NotificationCenter.default
        observers.append(
            center.addObserver(forName: NSText.didChangeNotification, object: textView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.textDidChange() }
            })
        observers.append(
            center.addObserver(forName: NSTextView.didChangeSelectionNotification, object: textView, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.selectionDidChange() }
            })
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        highlightTask?.cancel()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        if wrapsLines == true { textView.frame.size.width = wrapWidth }
    }

    /// The clip view spans the whole scroll view and insets its content by the
    /// gutter, so wrapped text must subtract that inset.
    private var wrapWidth: CGFloat {
        let insets = scrollView.contentView.contentInsets
        return max(0, scrollView.contentSize.width - insets.left - insets.right)
    }

    func applyThemeIfNeeded() {
        guard themeRevision != DockThemeRuntime.revision else { return }
        themeRevision = DockThemeRuntime.revision
        textView.backgroundColor = .codeCanvas
        scrollView.backgroundColor = .codeCanvas
        textView.insertionPointColor = .codeAccent
        textView.selectedTextAttributes = [
            .backgroundColor: NSColor(Color.dockAccentMuted), .foregroundColor: NSColor(Color.dockPrimaryText),
        ]
        scheduleHighlight()
        gutter.needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        themeRevision = nil
        applyThemeIfNeeded()
    }

    func setText(_ text: String, filePath: String) {
        guard textView.string != text || self.filePath != filePath else { return }
        let selection = textView.selectedRange()
        self.filePath = filePath
        textView.string = text
        textView.recomputeLineStarts()
        gutter.updateThickness()
        CodeSyntaxHighlighter.apply(to: textView, tokens: [])
        scheduleHighlight()
        let length = (text as NSString).length
        textView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
        gutter.needsDisplay = true
    }

    func setBlame(_ blame: RepositoryBlameDocument?, showsGutter: Bool) {
        guard gutter.blame != blame || gutter.showsBlame != showsGutter else { return }
        gutter.setBlame(blame, showsBlame: showsGutter)
        textView.blameByLine = gutter.blameByLine
        textView.needsDisplay = true
    }

    func setWrapsLines(_ wraps: Bool) {
        guard wrapsLines != wraps, let container = textView.textContainer else { return }
        wrapsLines = wraps
        scrollView.hasHorizontalScroller = !wraps
        textView.isHorizontallyResizable = !wraps
        textView.autoresizingMask = wraps ? [.width] : []
        container.widthTracksTextView = wraps
        container.containerSize = NSSize(
            width: wraps ? wrapWidth : CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        if wraps { textView.frame.size.width = wrapWidth }
        textView.sizeToFit()
        gutter.needsDisplay = true
    }

    func showFindBarIfNeeded(_ request: Int) {
        guard request != lastFindRequest else { return }
        lastFindRequest = request
        DispatchQueue.main.async { [textView] in
            textView.window?.makeFirstResponder(textView)
            let item = NSMenuItem()
            item.tag = NSTextFinder.Action.showFindInterface.rawValue
            textView.performTextFinderAction(item)
        }
    }

    private func textDidChange() {
        textView.recomputeLineStarts()
        gutter.updateThickness()
        selectionDidChange()
        onTextChanged(textView.string)
        scheduleHighlight(debounced: true)
    }

    private func scheduleHighlight(debounced: Bool = false) {
        highlightTask?.cancel()
        let source = textView.string
        let path = filePath
        highlightTask = Task { @MainActor [weak self] in
            if debounced {
                do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            }
            let work = Task.detached(priority: .userInitiated) {
                CodeTokenizer.tokens(in: source, language: CodeLanguage(path: path))
            }
            let tokens = await withTaskCancellationHandler {
                await work.value
            } onCancel: {
                work.cancel()
            }
            guard !Task.isCancelled, let self,
                self.filePath == path, self.textView.string == source
            else { return }
            CodeSyntaxHighlighter.apply(to: self.textView, tokens: tokens)
        }
    }

    private func selectionDidChange() {
        let selection = textView.selectedRange()
        let line = textView.lineNumber(at: selection.location)
        let lineStart = textView.lineStarts[line - 1]
        let cursor = CodeEditorCursor(
            line: line, column: selection.location - lineStart + 1, selectedCharacters: selection.length)
        if textView.currentLine != line || textView.currentLine > textView.lineStarts.count {
            textView.currentLine = line
            gutter.needsDisplay = true
        }
        textView.needsDisplay = true
        // Selection also changes while SwiftUI pushes text in updateNSView.
        DispatchQueue.main.async { [onCursorChange] in onCursorChange(cursor) }
    }
}

final class CodeTextView: NSTextView {
    /// UTF-16 offset of the first character of each line.
    private(set) var lineStarts: [Int] = [0]
    var currentLine = 1
    var blameByLine: [Int: RepositoryBlameLine] = [:]

    func recomputeLineStarts() {
        var starts = [0]
        for (offset, unit) in string.utf16.enumerated() where unit == 10 { starts.append(offset + 1) }
        lineStarts = starts
    }

    /// 1-based line containing the UTF-16 offset.
    func lineNumber(at offset: Int) -> Int {
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return low + 1
    }

    /// Fragment rect (in text view coordinates) of the caret's line, spanning
    /// every wrapped fragment.
    private func caretLineRect() -> NSRect? {
        guard let layoutManager, let textContainer else { return nil }
        let text = string as NSString
        let caret = selectedRange().location
        if caret >= text.length, !layoutManager.extraLineFragmentRect.isEmpty,
            text.length == 0 || text.character(at: text.length - 1) == 10
        {
            return layoutManager.extraLineFragmentRect.offsetBy(dx: 0, dy: textContainerOrigin.y)
        }
        let lineRange = text.lineRange(for: NSRange(location: min(caret, max(0, text.length - 1)), length: 0))
        let glyphs = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return nil }
        return layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer).offsetBy(
            dx: 0, dy: textContainerOrigin.y)
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard selectedRange().length == 0, var line = caretLineRect() else { return }
        line.origin.x = 0
        line.size.width = bounds.width
        NSColor.codeCurrentLine.setFill()
        line.fill()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawInlineBlame()
    }

    /// GitLens-style ghost text after the caret line.
    private func drawInlineBlame() {
        guard selectedRange().length == 0,
            currentLine <= lineStarts.count,
            let blame = blameByLine[currentLine],
            let layoutManager
        else { return }
        let text = string as NSString
        let start = lineStarts[currentLine - 1]
        let lineRange = text.lineRange(for: NSRange(location: min(start, text.length), length: 0))
        var contentEnd = NSMaxRange(lineRange)
        while contentEnd > lineRange.location, [10, 13].contains(text.character(at: contentEnd - 1)) { contentEnd -= 1 }
        guard contentEnd > lineRange.location else { return }
        let lastGlyph = layoutManager.glyphIndexForCharacter(at: contentEnd - 1)
        let used = layoutManager.lineFragmentUsedRect(forGlyphAt: lastGlyph, effectiveRange: nil)
        let commit = blame.commit
        let label =
            commit.isUncommitted
            ? "You · Uncommitted changes"
            : "\(commit.author), \(commit.authoredAt.map { HumanDateFormatting.relative($0) } ?? "unknown date") · \(commit.summary)"
        // Share the code's baseline and font so the ghost text sits on the line.
        let font = CodeSyntaxHighlighter.font
        let fragment = layoutManager.lineFragmentRect(forGlyphAt: lastGlyph, effectiveRange: nil)
        let baseline = fragment.minY + layoutManager.location(forGlyphAt: lastGlyph).y + textContainerOrigin.y
        let origin = NSPoint(x: used.maxX + textContainerOrigin.x + 28, y: baseline - font.ascender)
        NSString(string: label).draw(
            at: origin,
            withAttributes: [
                .font: font,
                .foregroundColor: NSColor.codeGhost,
            ])
    }

    override func insertNewline(_ sender: Any?) {
        let text = string as NSString
        let caret = selectedRange().location
        let lineStart = lineStarts[lineNumber(at: caret) - 1]
        let prefix = text.substring(with: NSRange(location: lineStart, length: caret - lineStart))
        var indent = String(prefix.prefix { $0 == " " || $0 == "\t" })
        if let last = prefix.trimmingCharacters(in: .whitespaces).last, "{[(:".contains(last) {
            indent += indent.contains("\t") ? "\t" : "    "
        }
        super.insertNewline(sender)
        if !indent.isEmpty { insertText(indent, replacementRange: selectedRange()) }
    }
}

/// Line numbers plus an optional blame column, drawn in the scroll view's
/// vertical ruler so it stays synchronized with the text while scrolling.
final class CodeGutterView: NSRulerView {
    static let blameWidth: CGFloat = 188
    weak var textView: CodeTextView?
    private(set) var blame: RepositoryBlameDocument?
    private(set) var blameByLine: [Int: RepositoryBlameLine] = [:]
    private(set) var showsBlame = true
    var onHoverBlame: (CodeEditorBlameHover?) -> Void = { _ in }
    var commitURL: (RepositoryBlameCommit) -> URL? = { _ in nil }
    private var ageRange: ClosedRange<TimeInterval>?
    private var hoveredLine: Int?
    private var trackingArea: NSTrackingArea?

    override var isFlipped: Bool { true }

    private var blameColumnWidth: CGFloat { showsBlame && blame != nil ? Self.blameWidth : 0 }

    private var numberColumnWidth: CGFloat {
        let digits = max(3, String(textView?.lineStarts.count ?? 1).count)
        return CGFloat(digits) * 7.6 + 22
    }

    func setBlame(_ blame: RepositoryBlameDocument?, showsBlame: Bool) {
        self.blame = blame
        self.showsBlame = showsBlame
        blameByLine = Dictionary(
            blame?.lines.map { ($0.lineNumber, $0) } ?? [], uniquingKeysWith: { first, _ in first })
        let dates =
            blame?.lines.compactMap { $0.commit.isUncommitted ? nil : $0.commit.authoredAt?.timeIntervalSince1970 }
            ?? []
        ageRange = dates.min().flatMap { low in dates.max().map { low...$0 } }
        updateThickness()
        needsDisplay = true
    }

    func updateThickness() {
        let thickness = blameColumnWidth + numberColumnWidth
        if abs(ruleThickness - thickness) > 0.5 { ruleThickness = thickness }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.codeCanvas.setFill()
        bounds.fill()
        if blameColumnWidth > 0 {
            NSColor.codeGutterBlame.setFill()
            NSRect(x: 0, y: 0, width: blameColumnWidth, height: bounds.height).fill()
        }
        drawHashMarksAndLabels(in: dirtyRect)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let layoutManager = textView.layoutManager, let textContainer = textView.textContainer
        else { return }
        let text = textView.string as NSString
        let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let blameFont = NSFont.systemFont(ofSize: 11, weight: .regular)
        let visible = textView.visibleRect
        let glyphs = layoutManager.glyphRange(forBoundingRect: visible, in: textContainer)
        let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        var line = textView.lineNumber(at: characters.location)
        let lastLine = textView.lineNumber(at: NSMaxRange(characters))

        while line <= lastLine, line <= textView.lineStarts.count {
            let start = textView.lineStarts[line - 1]
            let fragment: NSRect
            if start >= text.length {
                guard !layoutManager.extraLineFragmentRect.isEmpty else { break }
                fragment = layoutManager.extraLineFragmentRect
            } else {
                fragment = layoutManager.lineFragmentRect(
                    forGlyphAt: layoutManager.glyphIndexForCharacter(at: start), effectiveRange: nil)
            }
            let y = convert(NSPoint(x: 0, y: fragment.minY + textView.textContainerOrigin.y), from: textView).y
            // Empty lines report the newline glyph's baseline at the fragment
            // bottom, so use the font's baseline for every line.
            let baseline = y + layoutManager.defaultBaselineOffset(for: CodeSyntaxHighlighter.font)

            let isCurrent = line == textView.currentLine
            let number = NSAttributedString(
                string: "\(line)",
                attributes: [
                    .font: numberFont,
                    .foregroundColor: isCurrent ? NSColor.codeLineNumberActive : NSColor.codeLineNumber,
                ])
            let numberX = blameColumnWidth + numberColumnWidth - number.size().width - 14
            number.draw(at: NSPoint(x: numberX, y: baseline - numberFont.ascender))

            if blameColumnWidth > 0, let entry = blameByLine[line] {
                drawBlame(
                    entry, startsBlock: blameByLine[line - 1]?.commit.hash != entry.commit.hash,
                    y: y, height: fragment.height, baseline: baseline, font: blameFont)
            }
            line += 1
        }
    }

    private func drawBlame(
        _ entry: RepositoryBlameLine, startsBlock: Bool, y: CGFloat, height: CGFloat, baseline: CGFloat, font: NSFont
    ) {
        let commit = entry.commit
        let isHovered = hoveredLine.flatMap { blameByLine[$0]?.commit.hash } == commit.hash
        if isHovered {
            NSColor.codeAccent.withAlphaComponent(0.10).setFill()
            NSRect(x: 0, y: y, width: blameColumnWidth, height: height).fill()
        }
        // Age heat bar: newest commits are brightest.
        ageColor(for: commit).setFill()
        NSRect(x: 0, y: y, width: 3, height: height).fill()
        guard startsBlock else { return }

        NSColor.codeBorder.setFill()
        NSRect(x: 0, y: y, width: blameColumnWidth, height: 0.5).fill()
        let date = commit.isUncommitted ? "now" : commit.authoredAt.map { Self.shortAge($0) } ?? ""
        let author = commit.isUncommitted ? "Uncommitted" : commit.author
        let dateText = NSAttributedString(
            string: date, attributes: [.font: font, .foregroundColor: NSColor.codeLineNumber])
        let dateWidth = dateText.size().width
        let textY = baseline - font.ascender
        let lineHeight = height
        dateText.draw(at: NSPoint(x: blameColumnWidth - dateWidth - 10, y: textY))
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        NSAttributedString(
            string: author,
            attributes: [
                .font: font,
                .foregroundColor: commit.isUncommitted
                    ? NSColor.codeWarning : (isHovered ? NSColor.codeLineNumberActive : NSColor.codeBlameText),
                .paragraphStyle: paragraph,
            ]
        ).draw(in: NSRect(x: 12, y: textY, width: blameColumnWidth - dateWidth - 28, height: lineHeight))
    }

    private func ageColor(for commit: RepositoryBlameCommit) -> NSColor {
        if commit.isUncommitted { return .codeWarning }
        guard let range = ageRange, let date = commit.authoredAt?.timeIntervalSince1970,
            range.upperBound > range.lowerBound
        else {
            return NSColor.codeAccent.withAlphaComponent(0.6)
        }
        let freshness = (date - range.lowerBound) / (range.upperBound - range.lowerBound)
        return NSColor.codeAccent.withAlphaComponent(0.12 + 0.78 * freshness)
    }

    static func shortAge(_ date: Date, now: Date = .now) -> String {
        let days = Int(now.timeIntervalSince(date) / 86_400)
        switch days {
        case ..<1: return "today"
        case ..<7: return "\(days)d"
        case ..<30: return "\(days / 7)w"
        case ..<365: return "\(days / 30)mo"
        default: return "\(days / 365)y"
        }
    }

    // MARK: Interaction

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    private func line(at event: NSEvent) -> (line: Int, y: CGFloat)? {
        guard let textView, let layoutManager = textView.layoutManager, let textContainer = textView.textContainer
        else { return nil }
        let point = textView.convert(event.locationInWindow, from: nil)
        guard textView.string.utf16.count > 0 else { return nil }
        let glyph = layoutManager.glyphIndex(
            for: NSPoint(x: 0, y: point.y - textView.textContainerOrigin.y), in: textContainer)
        let character = layoutManager.characterIndexForGlyph(at: glyph)
        let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        guard point.y <= fragment.maxY + textView.textContainerOrigin.y else { return nil }
        let y = convert(NSPoint(x: 0, y: fragment.minY + textView.textContainerOrigin.y), from: textView).y
        return (textView.lineNumber(at: character), y)
    }

    override func mouseMoved(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        let hit = local.x < blameColumnWidth ? line(at: event) : nil
        let hovered = hit.flatMap { blameByLine[$0.line] }
        if hoveredLine != hovered?.lineNumber {
            hoveredLine = hovered?.lineNumber
            needsDisplay = true
        }
        let editorY = hit.map { convert(NSPoint(x: 0, y: $0.y), to: superview?.superview).y }
        onHoverBlame(hovered.flatMap { line in editorY.map { CodeEditorBlameHover(line: line, y: $0) } })
    }

    override func mouseExited(with event: NSEvent) {
        hoveredLine = nil
        needsDisplay = true
        onHoverBlame(nil)
    }

    /// Clicking a line number selects that line, like VS Code.
    override func mouseDown(with event: NSEvent) {
        guard let textView, let hit = line(at: event) else { return }
        let text = textView.string as NSString
        let start = textView.lineStarts[hit.line - 1]
        textView.window?.makeFirstResponder(textView)
        textView.setSelectedRange(text.lineRange(for: NSRange(location: min(start, text.length), length: 0)))
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let hit = line(at: event), let entry = blameByLine[hit.line], !entry.commit.isUncommitted else {
            return nil
        }
        let menu = NSMenu()
        menu.addItem(CodeMenuItem("Copy Commit Hash") { Self.copy(entry.commit.hash) })
        menu.addItem(CodeMenuItem("Copy Commit Message") { Self.copy(entry.commit.summary) })
        if let url = commitURL(entry.commit) {
            menu.addItem(.separator())
            menu.addItem(CodeMenuItem("Open Commit on GitHub") { ExternalOpen.open(url) })
        }
        return menu
    }

    private static func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

/// Closure-backed menu item for AppKit context menus.
final class CodeMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func run() { handler() }
}

// MARK: - Syntax highlighting

@MainActor enum CodeSyntaxHighlighter {
    static let fontSize: CGFloat = 12
    static let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)

    static var baseAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        return [.font: font, .foregroundColor: NSColor.codeText, .paragraphStyle: paragraph]
    }

    static func apply(to textView: NSTextView, tokens: [(NSRange, CodeToken)]) {
        guard let storage = textView.textStorage else { return }
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes(baseAttributes, range: full)
        for (range, token) in tokens {
            storage.addAttribute(.foregroundColor, value: token.color, range: range)
        }
        storage.endEditing()
        textView.typingAttributes = baseAttributes
    }
}

enum CodeToken: Equatable, Sendable {
    case keyword, string, number, comment, type, function, property, heading, link

    @MainActor var color: NSColor {
        switch self {
        case .keyword: .codeKeyword
        case .string: .codeString
        case .number: .codeNumber
        case .comment: .codeComment
        case .type: .codeType
        case .function: .codeFunction
        case .property, .link: .codeProperty
        case .heading: .codeKeyword
        }
    }
}

struct CodeLanguage: Equatable, Sendable {
    let name: String
    var keywords: [String] = []
    var lineComments: [String] = []
    var blockComments = false
    var tripleQuotes = false
    var backtickStrings = false
    var keysBeforeColon = false
    var yamlKeys = false
    var isMarkdown = false

    private static let cFamily = [
        "if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue", "return", "true", "false",
        "null", "const", "static", "struct", "enum", "void", "new", "this", "class", "public", "private", "protected",
        "import", "try", "catch", "throw", "finally",
    ]

    init(
        name: String, keywords: [String] = [], lineComments: [String] = [], blockComments: Bool = false,
        tripleQuotes: Bool = false, backtickStrings: Bool = false, keysBeforeColon: Bool = false,
        yamlKeys: Bool = false, isMarkdown: Bool = false
    ) {
        self.name = name
        self.keywords = keywords
        self.lineComments = lineComments
        self.blockComments = blockComments
        self.tripleQuotes = tripleQuotes
        self.backtickStrings = backtickStrings
        self.keysBeforeColon = keysBeforeColon
        self.yamlKeys = yamlKeys
        self.isMarkdown = isMarkdown
    }

    init(path: String) {
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent.lowercased()
        let ext = url.pathExtension.lowercased()
        let c = Self.cFamily
        switch ext {
        case "swift":
            self.init(
                name: "Swift",
                keywords: c + [
                    "func", "let", "var", "guard", "in", "self", "Self", "nil", "init", "deinit", "extension",
                    "protocol", "internal", "fileprivate", "final", "override", "async", "await", "throws", "rethrows",
                    "some", "any", "where", "inout", "mutating", "lazy", "weak", "typealias", "defer", "repeat", "is",
                    "as",
                ], lineComments: ["//"], blockComments: true, tripleQuotes: true)
        case "js", "jsx", "mjs", "cjs", "ts", "tsx", "mts":
            self.init(
                name: ext.hasPrefix("t") ? "TypeScript" : "JavaScript",
                keywords: c + [
                    "function", "let", "var", "async", "await", "export", "from", "of", "in", "typeof", "instanceof",
                    "undefined", "yield", "extends", "interface", "type", "implements", "readonly", "as", "delete",
                    "super",
                ], lineComments: ["//"], blockComments: true, backtickStrings: true)
        case "json", "jsonc":
            self.init(
                name: "JSON", keywords: ["true", "false", "null"], lineComments: ext == "jsonc" ? ["//"] : [],
                blockComments: ext == "jsonc", keysBeforeColon: true)
        case "py":
            self.init(
                name: "Python",
                keywords: [
                    "def", "class", "if", "elif", "else", "for", "while", "return", "import", "from", "as", "with",
                    "try", "except", "finally", "raise", "pass", "break", "continue", "lambda", "yield", "async",
                    "await", "in", "is", "not", "and", "or", "None", "True", "False", "self", "global", "nonlocal",
                ], lineComments: ["#"], tripleQuotes: true)
        case "rb":
            self.init(
                name: "Ruby",
                keywords: [
                    "def", "class", "module", "if", "elsif", "else", "unless", "end", "do", "while", "return",
                    "require", "yield", "nil", "true", "false", "self", "begin", "rescue", "ensure",
                ], lineComments: ["#"])
        case "go":
            self.init(
                name: "Go",
                keywords: c + [
                    "func", "package", "var", "type", "interface", "map", "chan", "go", "defer", "range", "select",
                    "nil", "fallthrough",
                ], lineComments: ["//"], blockComments: true, backtickStrings: true)
        case "rs":
            self.init(
                name: "Rust",
                keywords: c + [
                    "fn", "let", "mut", "impl", "trait", "pub", "use", "mod", "crate", "self", "Self", "match", "loop",
                    "where", "as", "ref", "move", "async", "await", "dyn", "unsafe", "Some", "None", "Ok", "Err",
                ], lineComments: ["//"], blockComments: true)
        case "c", "h", "cpp", "cc", "hpp", "m", "mm", "java", "kt", "kts", "cs", "dart", "scala":
            self.init(
                name: ext.uppercased(),
                keywords: c + [
                    "int", "char", "float", "double", "long", "unsigned", "bool", "auto", "namespace", "using",
                    "template", "typename", "virtual", "override", "fun", "val", "var", "package", "interface",
                    "extends", "implements", "nil", "self", "final", "abstract",
                ], lineComments: ["//"], blockComments: true)
        case "css", "scss", "less":
            self.init(
                name: "CSS", keywords: ["important", "media", "import", "keyframes"],
                lineComments: ext == "css" ? [] : ["//"], blockComments: true)
        case "sh", "bash", "zsh", "fish":
            self.init(
                name: "Shell",
                keywords: [
                    "if", "then", "else", "elif", "fi", "for", "while", "do", "done", "case", "esac", "function",
                    "return", "export", "local", "in", "echo", "set",
                ], lineComments: ["#"])
        case "yml", "yaml":
            self.init(
                name: "YAML", keywords: ["true", "false", "null", "yes", "no"], lineComments: ["#"], yamlKeys: true)
        case "toml", "ini", "cfg", "conf", "properties":
            self.init(name: ext.uppercased(), keywords: ["true", "false"], lineComments: ["#", ";"], yamlKeys: true)
        case "sql":
            self.init(
                name: "SQL",
                keywords: [
                    "select", "from", "where", "insert", "into", "update", "delete", "create", "table", "join", "left",
                    "right", "inner", "on", "and", "or", "not", "null", "as", "order", "by", "group", "limit", "values",
                    "set", "SELECT", "FROM", "WHERE", "INSERT", "INTO", "UPDATE", "DELETE", "CREATE", "TABLE", "JOIN",
                    "ON", "AND", "OR", "NOT", "NULL", "AS", "ORDER", "BY", "GROUP", "LIMIT", "VALUES", "SET",
                ], lineComments: ["--"], blockComments: true)
        case "md", "markdown", "mdx":
            self.init(name: "Markdown", isMarkdown: true)
        case "html", "htm", "xml", "svg", "plist", "vue":
            self.init(name: ext.uppercased(), blockComments: false)
        default:
            if ["dockerfile", "makefile", "gemfile", "podfile", ".gitignore", ".env", ".zshrc", ".bashrc"].contains(
                name) || name.hasPrefix(".env")
            {
                self.init(
                    name: name.capitalized,
                    keywords: ["FROM", "RUN", "COPY", "CMD", "ENV", "WORKDIR", "EXPOSE", "ARG", "ENTRYPOINT"],
                    lineComments: ["#"])
            } else {
                self.init(name: "Plain Text")
            }
        }
    }
}

/// Regex tokenizer. Strings and comments are matched in one left-to-right
/// alternation so `"http://x"` stays a string and `// "quoted"` stays a
/// comment; they are emitted last so they win over keyword/number passes.
enum CodeTokenizer {
    static func tokens(in source: String, language: CodeLanguage) -> [(NSRange, CodeToken)] {
        let text = source as NSString
        let full = NSRange(location: 0, length: text.length)
        var result: [(NSRange, CodeToken)] = []

        func add(
            _ pattern: String, _ token: CodeToken, group: Int = 0,
            options: NSRegularExpression.Options = [.anchorsMatchLines]
        ) {
            guard !Task.isCancelled, let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
                return
            }
            for match in regex.matches(in: source, range: full) where match.range(at: group).location != NSNotFound {
                guard !Task.isCancelled else { return }
                result.append((match.range(at: group), token))
            }
        }

        if language.isMarkdown {
            add(#"^#{1,6} .*$"#, .heading)
            add(#"^\s*(?:[-*+]|\d+\.) "#, .keyword)
            add(#"\[[^\]\n]+\]\([^)\n]+\)"#, .link)
            add(#"\*\*[^*\n]+\*\*|__[^_\n]+__"#, .type)
            add(#"^> .*$"#, .comment)
            add(#"`[^`\n]+`"#, .string)
            add(#"^```[\s\S]*?^```"#, .string)
            return result
        }

        add(#"\b(?:0x[0-9a-fA-F]+|\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)\b"#, .number)
        if language.blockComments || !language.lineComments.isEmpty || language.backtickStrings {
            add(#"\b[A-Z][A-Za-z0-9_]*\b"#, .type)
            add(#"\b([a-zA-Z_][A-Za-z0-9_]*)\s*(?=\()"#, .function, group: 1)
        }
        if !language.keywords.isEmpty {
            let words = language.keywords.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
            add(#"(?<![\w.$@-])(?:"# + words + #")(?![\w$-])"#, .keyword)
        }
        if language.yamlKeys {
            add(#"^\s*-?\s*([A-Za-z0-9_.\-\[\]"']+)\s*(?=[:=])"#, .property, group: 1)
        }

        var alternatives: [String] = []
        if language.tripleQuotes { alternatives.append(#"(?<s3>"""[\s\S]*?""")"#) }
        if language.blockComments { alternatives.append(#"(?<cb>/\*[\s\S]*?\*/)"#) }
        if !language.lineComments.isEmpty {
            let markers = language.lineComments.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
            alternatives.append(#"(?<cl>(?:"# + markers + #").*$)"#)
        }
        alternatives.append(#"(?<s>"(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*')"#)
        if language.backtickStrings { alternatives.append(#"(?<bt>`(?:\\.|[^`\\])*`)"#) }

        if !Task.isCancelled,
            let regex = try? NSRegularExpression(
                pattern: alternatives.joined(separator: "|"), options: [.anchorsMatchLines])
        {
            for match in regex.matches(in: source, range: full) {
                guard !Task.isCancelled else { break }
                let isComment = ["cb", "cl"].contains { match.range(withName: $0).location != NSNotFound }
                var token: CodeToken = isComment ? .comment : .string
                if !isComment, language.keysBeforeColon, followedByColon(text, after: NSMaxRange(match.range)) {
                    token = .property
                }
                result.append((match.range, token))
            }
        }
        return result
    }

    private static func followedByColon(_ text: NSString, after index: Int) -> Bool {
        var cursor = index
        while cursor < text.length {
            let character = text.character(at: cursor)
            if character == 58 { return true }
            if character != 32 && character != 9 { return false }
            cursor += 1
        }
        return false
    }
}

// MARK: - Colors

extension NSColor {
    fileprivate static var codeKeyword: NSColor { NSColor(DockAccentColor.violet.color) }
    fileprivate static var codeString: NSColor { NSColor(DockAccentColor.orange.color) }
    fileprivate static var codeNumber: NSColor { NSColor(DockAccentColor.green.color) }
    fileprivate static var codeComment: NSColor { NSColor(Color.dockSecondaryText) }
    fileprivate static var codeType: NSColor { NSColor(DockAccentColor.teal.color) }
    fileprivate static var codeFunction: NSColor { NSColor(DockAccentColor.amber.color) }
    fileprivate static var codeProperty: NSColor { NSColor(DockAccentColor.blue.color) }

    fileprivate static var codeCanvas: NSColor { NSColor(Color.dockCanvas) }
    fileprivate static var codeText: NSColor { NSColor(Color.dockMarkdownText) }
    fileprivate static var codeAccent: NSColor { NSColor(Color.dockAccent) }
    fileprivate static var codeWarning: NSColor { NSColor(Color.dockWarning) }
    fileprivate static var codeBorder: NSColor { NSColor(Color.dockBorderLight) }
    fileprivate static var codeLineNumber: NSColor { NSColor(Color.dockMetadataText).withAlphaComponent(0.7) }
    fileprivate static var codeLineNumberActive: NSColor { NSColor(Color.dockPrimaryText) }
    fileprivate static var codeBlameText: NSColor { NSColor(Color.dockSecondaryText) }
    fileprivate static var codeGhost: NSColor { NSColor(Color.dockMetadataText).withAlphaComponent(0.55) }
    fileprivate static var codeCurrentLine: NSColor { NSColor(Color.dockPrimaryText).withAlphaComponent(0.045) }
    fileprivate static var codeGutterBlame: NSColor { NSColor(Color.dockPrimaryText).withAlphaComponent(0.025) }
}
