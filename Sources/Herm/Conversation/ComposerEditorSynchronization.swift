import AppKit
import SwiftUI

/// Native storage edits, rather than SwiftUI renders or caret moves, invalidate editor work.
@MainActor
final class ComposerEditorSynchronization: NSObject, @preconcurrency NSTextStorageDelegate {
    private weak var storage: NSTextStorage?
    private var generation: UInt = 0
    private var serializedGeneration: UInt?
    private var serialized = ""
    private var contexts: [ChatContext]?
    private var highlightedGeneration: UInt?
    private var highlightedAccent: NSColor?
    private var measuredGeneration: UInt?
    private var measuredWidth: CGFloat?
    private var measuredContainerSize: NSSize?
    private var measuredPadding: CGFloat?
    private var measuredInset: NSSize?
    private var measuredFont: NSFont?
    private var publishedHeight: CGFloat?
    private var revealPending = false
    private(set) var serializationCount = 0
    private(set) var highlightCount = 0
    private(set) var layoutCount = 0

    private func observe(_ textView: NSTextView) {
        guard storage !== textView.textStorage else { return }
        if storage?.delegate === self { storage?.delegate = nil }
        storage = textView.textStorage
        storage?.delegate = self
        generation &+= 1
        contexts = nil
    }

    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        // Attribute-only edits include attachment replacement and undo/redo.
        generation &+= 1
    }

    func markdown(in textView: NSTextView) -> String {
        observe(textView)
        if serializedGeneration != generation {
            serialized = InlineContextCodec.serialize(textView.attributedString()).markdownBullets
            serializedGeneration = generation
            serializationCount += 1
        }
        return serialized
    }

    func synchronize(_ textView: NSTextView, markdown: String, contexts: [ChatContext], inset: NSSize) {
        observe(textView)
        // Do not replace the native marked range while the input method owns it.
        if !textView.hasMarkedText(), self.contexts != contexts || self.markdown(in: textView) != markdown {
            let selection = textView.selectedRange()
            textView.textStorage?.setAttributedString(InlineContextCodec.render(markdown.displayBullets, contexts: contexts))
            self.contexts = contexts
            serialized = markdown
            serializedGeneration = generation
            let length = (textView.string as NSString).length
            let location = min(selection.location, length)
            textView.setSelectedRange(NSRange(location: location, length: min(selection.length, length - location)))
        }
        let font = DockSkinPresentation.nativeFont(size: 14)
        let color = NSColor(Color.dockPrimaryText)
        let accent = NSColor(Color.dockAccent)
        if textView.font != font { textView.font = font }
        if textView.textColor != color { textView.textColor = color }
        if textView.insertionPointColor != accent { textView.insertionPointColor = accent }
        if textView.textContainerInset != inset { textView.textContainerInset = inset }
        _ = self.markdown(in: textView)
    }

    func updatePresentation(_ textView: NSTextView, publishHeight: (CGFloat) -> Void) {
        observe(textView)
        guard let layout = textView.layoutManager, let container = textView.textContainer else { return }
        let accent = NSColor(Color.dockAccent)
        if highlightedGeneration != generation || highlightedAccent != accent {
            let full = NSRange(location: 0, length: (textView.string as NSString).length)
            layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: full)
            layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)
            for range in SlashCommandTokens.ranges(in: textView.string) {
                layout.addTemporaryAttributes(
                    [.foregroundColor: accent, .backgroundColor: accent.withAlphaComponent(0.16)],
                    forCharacterRange: range)
            }
            highlightedGeneration = generation
            highlightedAccent = accent
            highlightCount += 1
        }
        guard measuredGeneration != generation || measuredWidth != textView.bounds.width
            || measuredContainerSize != container.containerSize || measuredPadding != container.lineFragmentPadding
            || measuredInset != textView.textContainerInset || measuredFont != textView.font else { return }
        layout.ensureLayout(for: container)
        layoutCount += 1
        measuredGeneration = generation
        measuredWidth = textView.bounds.width
        measuredContainerSize = container.containerSize
        measuredPadding = container.lineFragmentPadding
        measuredInset = textView.textContainerInset
        measuredFont = textView.font
        let height = max(ComposerLayout.minHeight, layout.usedRect(for: container).height + textView.textContainerInset.height * 2)
        if publishedHeight != height {
            publishedHeight = height
            publishHeight(height)
        }
    }

    func revealCaret(in textView: NSTextView, isFocused: @escaping () -> Bool) {
        guard !revealPending else { return }
        revealPending = true
        DispatchQueue.main.async { [weak self, weak textView] in
            guard let self else { return }
            self.revealPending = false
            guard let textView, self.storage === textView.textStorage,
                  isFocused(), textView.isEditable, textView.window?.firstResponder === textView else { return }
            textView.scrollRangeToVisible(textView.selectedRange())
        }
    }
}
