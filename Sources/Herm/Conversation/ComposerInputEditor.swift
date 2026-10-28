import AppKit
import SwiftUI

struct ComposerInputEditor: NSViewRepresentable {
    @AppStorage(ComposerTypingSettings.autocorrectKey) private var autocorrectEnabled = true
    @Environment(\.dockWorkspaceScale) private var workspaceScale
    @Environment(\.isEnabled) private var isEnabled
    @Binding var text: String
    let isFocused: Bool
    let onSubmit: () -> Void
    let onCompletionKey: (ComposerCompletionKey) -> Bool
    var onDropFiles: (([URL]) -> Void)? = nil
    var onPaste: (() -> Bool)? = nil
    let onFocusChanged: (Bool) -> Void
    let onCaretMoved: (String, Int) -> Void
    let takePendingCaret: () -> Int?
    let onTextChanged: (String, Int) -> Void
    var onTextReplaced: ((NSRange, String) -> Void)? = nil
    let onContentHeightChanged: (CGFloat) -> Void
    var inset = NSSize(width: 16, height: 0)
    var contexts: [ChatContext] = []
    var onInspectContext: ((ChatContext) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.verticalScrollElasticity = .automatic
        scrollView.horizontalScrollElasticity = .none

        let textView = ComposerInputTextView()
        textView.delegate = context.coordinator
        textView.onPrepareForInput = { [weak coordinator = context.coordinator] textView in
            coordinator?.prepareForNativeInput(in: textView)
        }
        textView.onSubmit = onSubmit
        textView.onCompletionKey = onCompletionKey
        textView.onDropFiles = onDropFiles
        textView.onPaste = onPaste
        textView.isEditable = isEnabled
        textView.isAutomaticSpellingCorrectionEnabled = autocorrectEnabled
        textView.isContinuousSpellCheckingEnabled = autocorrectEnabled
        textView.onWidthChanged = { [weak coordinator = context.coordinator, weak textView] in
            guard let textView else { return }
            coordinator?.schedulePresentationUpdate(for: textView)
        }
        textView.contexts = contexts
        textView.onInspectContext = onInspectContext
        textView.font = DockSkinPresentation.nativeFont(size: DockTypography.size(.conversation))
        textView.textColor = NSColor(Color.dockPrimaryText)
        textView.insertionPointColor = NSColor(Color.dockAccent)
        textView.drawsBackground = false
        textView.isRichText = false
        if #available(macOS 15.0, *) {
            // Plain text only: Writing Tools must not insert formatting into a message.
            textView.writingToolsBehavior = .complete
            textView.allowedWritingToolsResultOptions = [.plainText]
        }
        textView.allowsUndo = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainerInset = inset
        // NSTextContainer adds a 5pt line-fragment inset by default. The
        // placeholder already uses the shared 16pt gutter, so remove that
        // hidden extra inset to align the caret with its first character.
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)

        scrollView.documentView = textView
        context.coordinator.synchronize(textView)
        context.coordinator.reportContentHeight(for: textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? ComposerInputTextView else { return }
        context.coordinator.parent = self
        textView.onSubmit = onSubmit
        textView.onCompletionKey = onCompletionKey
        textView.onDropFiles = onDropFiles
        textView.onPaste = onPaste
        textView.isEditable = isEnabled
        textView.isAutomaticSpellingCorrectionEnabled = autocorrectEnabled
        textView.isContinuousSpellCheckingEnabled = autocorrectEnabled
        textView.contexts = contexts
        textView.onInspectContext = onInspectContext
        context.coordinator.synchronize(textView)
        context.coordinator.applyPendingCaret(in: textView)
        context.coordinator.reportContentHeight(for: textView)

        guard isFocused, scrollView.window?.firstResponder !== textView else { return }
        DispatchQueue.main.async { [weak coordinator = context.coordinator, weak textView, weak scrollView] in
            guard let coordinator, let textView, let scrollView,
                coordinator.parent.isFocused, textView.isEditable,
                scrollView.documentView === textView
            else { return }
            scrollView.window?.makeFirstResponder(textView)
        }
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerInputEditor
        var isSynchronizingText = false
        private var presentationUpdatePending = false
        let synchronization = ComposerEditorSynchronization()

        func synchronize(_ textView: NSTextView) {
            isSynchronizingText = true
            synchronization.synchronize(
                textView, markdown: parent.text, contexts: parent.contexts, inset: parent.inset,
                bodySize: DockTypography.size(.conversation, scale: parent.workspaceScale))
            isSynchronizingText = false
        }

        func prepareForNativeInput(in textView: NSTextView) {
            guard !isSynchronizingText, !textView.hasMarkedText(), let caret = parent.takePendingCaret() else { return }
            guard synchronization.markdown(in: textView) != parent.text else { return }
            synchronize(textView)
            setCaret(caret, in: textView)
        }

        func applyPendingCaret(in textView: NSTextView) {
            guard !textView.hasMarkedText(), let caret = parent.takePendingCaret() else { return }
            setCaret(caret, in: textView)
        }

        private func setCaret(_ caret: Int, in textView: NSTextView) {
            let location = max(0, min(caret, (textView.string as NSString).length))
            textView.setSelectedRange(NSRange(location: location, length: 0))
        }

        init(_ parent: ComposerInputEditor) {
            self.parent = parent
        }

        func textDidBeginEditing(_ notification: Notification) {
            parent.onFocusChanged(true)
        }

        func textDidEndEditing(_ notification: Notification) {
            parent.onFocusChanged(false)
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            guard !isSynchronizingText else { return }
            // Typing supersedes a completion's queued selection before the next redraw.
            _ = parent.takePendingCaret()
            if !textView.hasMarkedText() { bulletizeCurrentLine(textView) }
            let markdown = synchronization.markdown(in: textView)
            if !isSynchronizingText, parent.text != markdown {
                parent.text = markdown
                parent.onTextChanged(markdown, textView.selectedRange().location)
            }
            reportContentHeight(for: textView)
            synchronization.revealCaret(in: textView) { [weak self] in self?.parent.isFocused == true }
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
            if !isSynchronizingText, let replacementString {
                parent.onTextReplaced?(range, replacementString)
            }
            return true
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isSynchronizingText, let textView = notification.object as? NSTextView else { return }
            parent.onCaretMoved(synchronization.markdown(in: textView), textView.selectedRange().location)
        }

        /// Typing "- " at a line start shows a "•" bullet; the binding keeps markdown "- ".
        private func bulletizeCurrentLine(_ textView: NSTextView) {
            let ns = textView.string as NSString
            let caret = textView.selectedRange().location
            let line = ns.lineRange(for: NSRange(location: caret, length: 0))
            guard caret >= line.location + 2, ns.substring(with: line).hasPrefix("- ") else { return }
            let range = NSRange(location: line.location, length: 2)
            if textView.shouldChangeText(in: range, replacementString: "• ") {
                textView.replaceCharacters(in: range, with: "• ")
                textView.didChangeText()
            }
        }

        func reportContentHeight(for textView: NSTextView) {
            synchronization.updatePresentation(textView, publishHeight: parent.onContentHeightChanged)
        }

        func schedulePresentationUpdate(for textView: NSTextView) {
            guard !presentationUpdatePending else { return }
            presentationUpdatePending = true
            // Native wrapping settles after SwiftUI assigns the scroll view's width.
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self else { return }
                self.presentationUpdatePending = false
                if let textView { self.reportContentHeight(for: textView) }
            }
        }
    }
}
