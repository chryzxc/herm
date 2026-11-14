import AppKit
import SwiftUI

final class ComposerInputTextView: NSTextView {
    var onPrepareForInput: ((NSTextView) -> Void)?
    var onSubmit: (() -> Void)?
    var onCompletionKey: ((ComposerCompletionKey) -> Bool)?
    var onDropFiles: (([URL]) -> Void)?
    var onPaste: (() -> Bool)?
    var onWidthChanged: (() -> Void)?
    var contexts: [ChatContext] = []
    var onInspectContext: ((ChatContext) -> Void)?

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = frame.width != newSize.width
        super.setFrameSize(newSize)
        if widthChanged { onWidthChanged?() }
    }

    override func mouseDown(with event: NSEvent) {
        onPrepareForInput?(self)
        let index = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
        if index < (string as NSString).length,
            let attachment = textStorage?.attribute(.attachment, at: index, effectiveRange: nil)
                as? InlineContextAttachment,
            let context = contexts.first(where: { $0.inlineToken == attachment.token })
        {
            onInspectContext?(context)
            return
        }
        super.mouseDown(with: event)
    }

    override func writeSelection(to pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard type == .string, let storage = textStorage, selectedRange().length > 0 else {
            return super.writeSelection(to: pasteboard, type: type)
        }
        let selected = storage.attributedSubstring(from: selectedRange())
        let serialized = InlineContextCodec.serialize(selected)
        let readable = contexts.reduce(serialized) { value, context in
            context.inlineToken.map { value.replacingOccurrences(of: $0, with: "[" + context.title + "]") } ?? value
        }
        return pasteboard.setString(readable, forType: .string)
    }

    /// Dropped files become attachments; NSTextView would otherwise insert their paths as text.
    private func droppedFileURLs(_ sender: NSDraggingInfo) -> [URL] {
        AttachmentPopoverFileSelection.fileURLs(from: sender.draggingPasteboard)
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)), isEditable {
            // Plain-text NSTextView rejects file/image clipboards before our paste handler runs.
            if onDropFiles != nil, !AttachmentPopoverFileSelection.fileURLs(from: .general).isEmpty { return true }
            if onPaste != nil, DockModel.pasteboardHoldsImageOnly(.general) { return true }
        }
        return super.validateUserInterfaceItem(item)
    }

    override func paste(_ sender: Any?) {
        onPrepareForInput?(self)
        let urls = AttachmentPopoverFileSelection.fileURLs(from: .general)
        guard isEditable else { return }
        if !urls.isEmpty, let onDropFiles {
            onDropFiles(urls)
        } else if onPaste?() != true {
            super.paste(sender)
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedFileURLs(sender).isEmpty ? super.draggingEntered(sender) : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedFileURLs(sender).isEmpty ? super.draggingUpdated(sender) : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = droppedFileURLs(sender)
        guard !urls.isEmpty, let onDropFiles else { return super.performDragOperation(sender) }
        onDropFiles(urls)
        return true
    }

    override func keyDown(with event: NSEvent) {
        onPrepareForInput?(self)
        // While an input method is composing, its keys belong to it: Return commits
        // the conversion and the arrows move through candidates.
        if hasMarkedText() {
            super.keyDown(with: event)
            return
        }
        let editingModifiers: NSEvent.ModifierFlags = [.shift, .command, .option, .control]
        if event.modifierFlags.intersection(editingModifiers).isEmpty,
            let key = ComposerCompletionKey(keyCode: event.keyCode),
            onCompletionKey?(key) == true
        {
            return
        }
        if event.keyCode == 36 || event.keyCode == 76,
            event.modifierFlags.intersection(editingModifiers).isEmpty
        {
            onSubmit?()
            return
        }
        if event.keyCode == 36, event.modifierFlags.contains(.shift), continueBullet() { return }
        super.keyDown(with: event)
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        onPrepareForInput?(self)
        super.insertText(insertString, replacementRange: replacementRange)
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        onPrepareForInput?(self)
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    }

    /// Shift+Return on a "• " line continues the list; on an empty bullet it ends it.
    private func continueBullet() -> Bool {
        let ns = string as NSString
        let line = ns.lineRange(for: NSRange(location: selectedRange().location, length: 0))
        let content = ns.substring(with: line).trimmingCharacters(in: .newlines)
        guard content.hasPrefix("• ") else { return false }
        if content == "• " {
            let range = NSRange(location: line.location, length: 2)
            if shouldChangeText(in: range, replacementString: "") {
                replaceCharacters(in: range, with: "")
                didChangeText()
            }
        } else {
            insertText("\n• ", replacementRange: selectedRange())
        }
        return true
    }
}
