@preconcurrency import AppKit
import SwiftUI

struct InlineBlameEditor: NSViewRepresentable {
    @Binding var text: String
    let filePath: String
    let blame: RepositoryBlameDocument?
    let unavailableReason: String?
    let onSelectBlame: (RepositoryBlameLine) -> Void
    let onHoverBlame: (RepositoryBlameLine?) -> Void

    func makeNSView(context: Context) -> InlineBlameEditorContainerView {
        InlineBlameEditorContainerView(text: text, filePath: filePath, blame: blame, unavailableReason: unavailableReason,
            onTextChanged: { updated in text = updated }, onSelectBlame: onSelectBlame, onHoverBlame: onHoverBlame)
    }

    func updateNSView(_ view: InlineBlameEditorContainerView, context: Context) {
        view.update(text: text, filePath: filePath, blame: blame, unavailableReason: unavailableReason, onSelectBlame: onSelectBlame, onHoverBlame: onHoverBlame)
    }
}

final class InlineBlameEditorContainerView: NSView {
    static let blameWidth: CGFloat = 290
    private let scrollView = NSScrollView()
    private let textView: InlineBlameTextView
    private let blameView: InlineBlameAnnotationView
    private var changeObserver: NSObjectProtocol?
    private var scrollObserver: NSObjectProtocol?
    private var onTextChanged: (String) -> Void

    private var filePath: String

    init(text: String, filePath: String, blame: RepositoryBlameDocument?, unavailableReason: String?,
         onTextChanged: @escaping (String) -> Void, onSelectBlame: @escaping (RepositoryBlameLine) -> Void,
         onHoverBlame: @escaping (RepositoryBlameLine?) -> Void) {
        self.filePath = filePath
        self.onTextChanged = onTextChanged
        let editor = InlineBlameTextView()
        self.textView = editor
        self.blameView = InlineBlameAnnotationView(textView: editor, onSelectBlame: onSelectBlame)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.dockCanvas.cgColor

        textView.string = text
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = true
        textView.allowsUndo = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = .dockForeground
        textView.insertionPointColor = .dockAccent
        textView.backgroundColor = .dockCanvas
        textView.drawsBackground = true
        textView.textContainerInset = NSSize(width: 10, height: 8)
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.height]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: 1, height: CGFloat.greatestFiniteMagnitude)
        editor.blame = blame
        SyntaxHighlighter.apply(to: textView, filePath: filePath)

        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .dockCanvas
        scrollView.documentView = textView
        addSubview(scrollView)

        blameView.blame = blame
        blameView.unavailableReason = unavailableReason
        // Blame is drawn by the editor itself at each line's end. The former
        // floating annotation layer is intentionally kept out of the view
        // hierarchy so it cannot cover or shift source text.
        blameView.isHidden = true
        addSubview(blameView)
        self.onHoverBlame = onHoverBlame
        editor.onLineClick = { [weak self] lineNumber in
            self?.selectLine(lineNumber)
        }
        editor.onHoverBlame = { [weak self] line in
            guard let self else { return }
            if let line {
                self.onHoverBlame?(line)
            } else {
                self.onHoverBlame?(nil)
            }
        }

        changeObserver = NotificationCenter.default.addObserver(forName: NSText.didChangeNotification, object: textView, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.onTextChanged(self.textView.string)
                self.blameView.needsDisplay = true
            }
        }
        scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.blameView.needsDisplay = true
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
    }

    deinit {
        if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
    }

    override func layout() {
        super.layout()
        let viewportWidth = max(1, bounds.width)
        let scrollFrame = NSRect(x: 0, y: 0, width: viewportWidth, height: bounds.height)
        if scrollView.frame != scrollFrame { scrollView.frame = scrollFrame }
        let blameFrame = NSRect(x: 0, y: 0, width: 0, height: 0)
        if blameView.frame != blameFrame { blameView.frame = blameFrame }
        blameView.isHidden = true
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: max(viewportWidth, 4096), height: CGFloat.greatestFiniteMagnitude)

        let usedHeight: CGFloat
        if let layoutManager = textView.layoutManager, let textContainer = textView.textContainer {
            usedHeight = layoutManager.usedRect(for: textContainer).height
        } else {
            usedHeight = 0
        }
        var longestLineEnd = viewportWidth
        if let layoutManager = textView.layoutManager, let textContainer = textView.textContainer {
            let allGlyphs = layoutManager.glyphRange(for: textContainer)
            layoutManager.enumerateLineFragments(forGlyphRange: allGlyphs) { fragmentRect, _, _, _, _ in
                longestLineEnd = max(longestLineEnd, fragmentRect.maxX + self.textView.textContainerOrigin.x)
            }
        }
        let documentWidth = max(viewportWidth, longestLineEnd + Self.blameWidth + 12)
        let textFrame = NSRect(x: 0, y: 0, width: documentWidth, height: max(bounds.height, usedHeight + 16))
        if textView.frame != textFrame { textView.frame = textFrame }
        blameView.needsDisplay = true
    }

    private var onHoverBlame: ((RepositoryBlameLine?) -> Void)?

    func update(text: String, filePath: String, blame: RepositoryBlameDocument?, unavailableReason: String?, onSelectBlame: @escaping (RepositoryBlameLine) -> Void, onHoverBlame: @escaping (RepositoryBlameLine?) -> Void) {
        let textChanged = textView.string != text || self.filePath != filePath
        if textChanged {
            textView.string = text
            self.filePath = filePath
            SyntaxHighlighter.apply(to: textView, filePath: filePath)
        }
        textView.blame = blame
        blameView.blame = blame
        blameView.unavailableReason = unavailableReason
        blameView.onSelectBlame = onSelectBlame
        self.onHoverBlame = onHoverBlame
        if textChanged { needsLayout = true }
        blameView.needsDisplay = true
    }

    private func selectLine(_ lineNumber: Int) {
        guard let line = blameView.blame?.lines.first(where: { $0.lineNumber == lineNumber }) else { return }
        blameView.selectedLineNumber = lineNumber
        textView.selectedBlameLineNumber = lineNumber
        blameView.needsDisplay = true
        textView.needsDisplay = true
        blameView.onSelectBlame?(line)
    }
}

final class InlineBlameTextView: NSTextView {
    var onLineClick: ((Int) -> Void)?
    var onHoverBlame: ((RepositoryBlameLine?) -> Void)?
    var blame: RepositoryBlameDocument?
    var selectedBlameLineNumber: Int?
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        guard let blame, let layoutManager, let textContainer else { return }
        let point = convert(event.locationInWindow, from: nil)
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        let linesByNumber = Dictionary(uniqueKeysWithValues: blame.lines.map { ($0.lineNumber, $0) })
        let annotationX = annotationColumnX
        var hovered: RepositoryBlameLine?
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { [weak self] fragmentRect, _, _, characterRange, _ in
            guard let self, characterRange.location != NSNotFound else { return }
            let lineNumber = self.string.utf16.prefix(characterRange.location).reduce(into: 1) { if $1 == 10 { $0 += 1 } }
            guard lineNumber == self.selectedBlameLineNumber else { return }
            let lineHeight = layoutManager.defaultLineHeight(for: self.font ?? .monospacedSystemFont(ofSize: 12, weight: .regular))
            let y = fragmentRect.minY + self.textContainerOrigin.y
            if point.x >= annotationX - 4 && point.x <= annotationX + 290,
               point.y >= y && point.y <= y + lineHeight {
                hovered = linesByNumber[lineNumber]
            }
        }
        onHoverBlame?(hovered)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverBlame?(nil)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let blame, let layoutManager, let textContainer else { return }

        let visibleRect = visibleRect
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        let linesByNumber = Dictionary(uniqueKeysWithValues: blame.lines.map { ($0.lineNumber, $0) })
        var lastFragmentByLine: [Int: NSRect] = [:]
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { [weak self] fragmentRect, _, _, characterRange, _ in
            guard let self, characterRange.location != NSNotFound else { return }
            let lineNumber = self.string.utf16.prefix(characterRange.location).reduce(into: 1) { if $1 == 10 { $0 += 1 } }
            lastFragmentByLine[lineNumber] = fragmentRect
        }
        for (lineNumber, fragmentRect) in lastFragmentByLine {
            guard let line = linesByNumber[lineNumber] else { continue }
            guard lineNumber == selectedBlameLineNumber else { continue }
            let font = self.font ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            let lineHeight = layoutManager.defaultLineHeight(for: font)
            let x = annotationColumnX
            guard x < self.bounds.width - 4 || lineNumber == self.selectedBlameLineNumber else { continue }
            let y = fragmentRect.minY + self.textContainerOrigin.y
            let date = line.commit.authoredAt.map { RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: .now) } ?? "unknown date"
            let value = line.commit.isUncommitted ? "UNCOMMITTED · WORKING TREE" : "\(line.commit.author) · \(date) · \(line.commit.shortHash)"
            let backgroundRect = NSRect(x: x - 4, y: y, width: max(0, self.bounds.width - x + 4), height: lineHeight)
            NSColor.dockCanvas.withAlphaComponent(0.96).setFill()
            NSBezierPath(rect: backgroundRect).fill()
            NSString(string: value).draw(in: NSRect(x: x, y: y, width: max(0, self.bounds.width - x), height: lineHeight), withAttributes: [
                .font: font,
                .foregroundColor: line.commit.isUncommitted ? NSColor.dockWarning : NSColor.dockSecondaryText
            ])
        }
    }

    private var annotationColumnX: CGFloat {
        max(10, visibleRect.maxX - 300)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let characterIndex = layoutManager?.characterIndex(
            for: point,
            in: textContainer ?? NSTextContainer(),
            fractionOfDistanceBetweenInsertionPoints: nil
        ) ?? 0
        let lineNumber = string.utf16.prefix(characterIndex).reduce(into: 1) { if $1 == 10 { $0 += 1 } }
        super.mouseDown(with: event)
        onLineClick?(lineNumber)
    }
}

final class InlineBlameAnnotationView: NSView {
    weak var textView: NSTextView?
    var blame: RepositoryBlameDocument?
    var unavailableReason: String?
    var onSelectBlame: ((RepositoryBlameLine) -> Void)?
    var selectedLineNumber: Int?

    init(textView: NSTextView, onSelectBlame: @escaping (RepositoryBlameLine) -> Void) {
        self.textView = textView
        self.onSelectBlame = onSelectBlame
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        guard let textView, let layoutManager = textView.layoutManager, let textContainer = textView.textContainer else { return }
        if unavailableReason != nil { drawStatus("BLAME UNAVAILABLE"); return }
        guard let blame else { drawStatus("LOADING BLAME…"); return }
        guard let selectedLineNumber else { return }
        let visibleRect = textView.visibleRect
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        let linesByNumber = Dictionary(uniqueKeysWithValues: blame.lines.map { ($0.lineNumber, $0) })
        var drawnLines = Set<Int>()
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { [weak self] fragmentRect, _, _, characterRange, _ in
            guard let self, characterRange.location != NSNotFound else { return }
            let lineNumber = textView.string.utf16.prefix(characterRange.location).reduce(into: 1) { if $1 == 10 { $0 += 1 } }
            // A long source line can wrap into multiple fragments. Draw its
            // blame once, beside the first visible fragment only.
            guard lineNumber == selectedLineNumber,
                  drawnLines.insert(lineNumber).inserted,
                  let line = linesByNumber[lineNumber] else { return }
            let sourceY = fragmentRect.minY + textView.textContainerOrigin.y
            let annotationPoint = textView.convert(NSPoint(x: 0, y: sourceY), to: self)
            self.drawMetadata(line.commit, at: annotationPoint.y)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let textView, let blame else { return }
        let sourcePoint = textView.convert(event.locationInWindow, from: nil)
        let height = textView.layoutManager?.defaultLineHeight(for: textView.font ?? .monospacedSystemFont(ofSize: 12, weight: .regular)) ?? 16
        let number = max(1, Int((sourcePoint.y - textView.textContainerOrigin.y) / height) + 1)
        if let line = blame.lines.first(where: { $0.lineNumber == number }) { onSelectBlame?(line) }
    }

    private func drawMetadata(_ commit: RepositoryBlameCommit, at y: CGFloat) {
        let date = commit.authoredAt.map { RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: .now) } ?? "unknown date"
        let value = commit.isUncommitted ? "UNCOMMITTED · WORKING TREE" : "\(commit.author) · \(date) · \(commit.shortHash)"
        let font = textView?.font ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let lineHeight = textView?.layoutManager?.defaultLineHeight(for: font) ?? 16
        NSString(string: value).draw(in: NSRect(x: 10, y: y, width: bounds.width - 18, height: lineHeight), withAttributes: [
            .font: font,
            .foregroundColor: commit.isUncommitted ? NSColor.dockWarning : NSColor.dockSecondaryText
        ])
    }

    private func drawStatus(_ value: String) {
        NSString(string: value).draw(in: NSRect(x: 10, y: 10, width: bounds.width - 18, height: 15), withAttributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold), .foregroundColor: NSColor.dockMetadataText
        ])
    }
}

@MainActor private enum SyntaxHighlighter {
    static func apply(to textView: NSTextView, filePath: String) {
        let text = textView.string
        let baseFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let baseColor = NSColor(calibratedRed: 0.76, green: 0.80, blue: 0.88, alpha: 1)
        let storage = NSMutableAttributedString(string: text, attributes: [.font: baseFont, .foregroundColor: baseColor])
        let isMarkdown = filePath.lowercased().hasSuffix(".md") || filePath.lowercased().hasSuffix(".markdown")

        if isMarkdown {
            color(#"(?m)^#{1,6} .*?$"#, in: storage, color: .dockAccent, weight: .bold)
            color(#"(?m)^```.*?$"#, in: storage, color: .dockSuccess, weight: .bold)
            color(#"`[^`\n]+`"#, in: storage, color: .dockFolder)
            color(#"\[[^\]]+\]\([^\)]+\)"#, in: storage, color: .dockAccent)
            color(#"(?m)^\s*(?:[-*+] |\d+\. )"#, in: storage, color: .dockAccent, weight: .bold)
            color(#"\*\*[^*]+\*\*|__[^_]+__"#, in: storage, color: .dockPrimaryText, weight: .bold)
            color(#"(?m)^> .*?$"#, in: storage, color: .dockSecondaryText)
        } else {
            color(#"(?m)//.*$|/\*[\s\S]*?\*/|#.*$"#, in: storage, color: .dockMetadataText)
            color(#"\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'"#, in: storage, color: .dockSuccess)
            color(#"\b(?:true|false|nil|null|None)\b"#, in: storage, color: .dockFolder)
            color(#"\b(?:class|struct|enum|func|let|var|if|else|for|while|return|import|from|in|public|private|internal|final|async|await|throw|throws|try|guard|switch|case|new|const|function|interface|type)\b"#, in: storage, color: .dockAccent, weight: .bold)
            color(#"\b\d+(?:\.\d+)?\b"#, in: storage, color: .dockFolder)
        }

        textView.textStorage?.setAttributedString(storage)
        textView.typingAttributes = [.font: baseFont, .foregroundColor: baseColor]
    }

    private static func color(_ pattern: String, in storage: NSMutableAttributedString, color: NSColor, weight: NSFont.Weight = .regular) {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return }
        let range = NSRange(location: 0, length: storage.length)
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: weight)
        expression.enumerateMatches(in: storage.string, range: range) { match, _, _ in
            guard let match else { return }
            storage.addAttributes([.foregroundColor: color, .font: font], range: match.range)
        }
    }
}

private extension NSColor {
    static let dockCanvas = NSColor(calibratedRed: 0.055, green: 0.065, blue: 0.115, alpha: 1)
    static let dockForeground = NSColor(calibratedRed: 0.76, green: 0.80, blue: 0.88, alpha: 1)
    static let dockAccent = NSColor(calibratedRed: 0.02, green: 0.65, blue: 0.95, alpha: 1)
    static let dockSecondaryText = NSColor(calibratedRed: 0.60, green: 0.64, blue: 0.71, alpha: 1)
    static let dockMetadataText = NSColor(calibratedRed: 0.46, green: 0.50, blue: 0.58, alpha: 1)
    static let dockPrimaryText = NSColor(calibratedRed: 0.70, green: 0.74, blue: 0.81, alpha: 1)
    static let dockSuccess = NSColor(calibratedRed: 0.16, green: 0.78, blue: 0.25, alpha: 1)
    static let dockFolder = NSColor(calibratedRed: 1.0, green: 0.70, blue: 0.30, alpha: 1)
    static let dockWarning = NSColor(calibratedRed: 1.0, green: 0.67, blue: 0.12, alpha: 1)
}
