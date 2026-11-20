import AppKit
import SwiftUI

final class ComposerInputTextView: NSTextView {
    var onPrepareForInput: ((NSTextView) -> Void)?
    var onSubmit: (() -> Void)?
    var onCompletionKey: ((ComposerCompletionKey) -> Bool)?
    var animatesFileDrop = false
    private var fileDragSequence: Int?
    private var fileDragRevision: Int?
    private var dragHasFiles = false
    private var fileDropOutline: CAShapeLayer?
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

    private func acceptsFileDrag(_ sender: NSDraggingInfo) -> Bool {
        guard isEditable, onDropFiles != nil else {
            clearFileDrag()
            return false
        }
        let revision = sender.draggingPasteboard.changeCount
        if fileDragSequence != sender.draggingSequenceNumber || fileDragRevision != revision {
            clearFileDrag()
            fileDragSequence = sender.draggingSequenceNumber
            fileDragRevision = revision
            dragHasFiles = !droppedFileURLs(sender).isEmpty
            if dragHasFiles { showFileDropOutline() }
        }
        return dragHasFiles
    }

    private func showFileDropOutline() {
        guard let scroll = enclosingScrollView else { return }
        scroll.wantsLayer = true
        guard let host = scroll.layer else { return }
        let rect = CGRect(origin: .zero, size: host.bounds.size).insetBy(dx: 2, dy: 2)
        guard rect.width > 0, rect.height > 0 else { return }
        let outline = CAShapeLayer()
        outline.frame = host.bounds
        outline.path = CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil)
        outline.fillColor = nil
        outline.strokeColor = insertionPointColor.cgColor
        outline.lineWidth = 2
        outline.lineCap = .round
        host.addSublayer(outline)
        fileDropOutline = outline
        if animatesFileDrop {
            let trace = CABasicAnimation(keyPath: "strokeEnd")
            trace.fromValue = 0
            trace.toValue = 1
            trace.duration = 0.20
            trace.timingFunction = CAMediaTimingFunction(name: .easeOut)
            outline.add(trace, forKey: "trace")
        }
    }

    private func clearFileDrag() {
        fileDropOutline?.removeFromSuperlayer()
        fileDropOutline = nil
        fileDragSequence = nil
        fileDragRevision = nil
        dragHasFiles = false
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        acceptsFileDrag(sender) ? .copy : super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        acceptsFileDrag(sender) ? .copy : super.draggingUpdated(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        clearFileDrag()
        super.draggingExited(sender)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        clearFileDrag()
        super.draggingEnded(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        clearFileDrag()
        let urls = droppedFileURLs(sender)
        guard isEditable, !urls.isEmpty, let onDropFiles else { return super.performDragOperation(sender) }
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
