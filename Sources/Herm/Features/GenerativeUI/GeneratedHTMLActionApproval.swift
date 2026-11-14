import AppKit

/// A renderer can request an action, but only this native sheet can authorize it.
@MainActor
final class GeneratedHTMLActionApproval {
    enum Action {
        case submitPrompt(prompt: String, conversation: String)
        case openLink(url: URL, source: String)
    }

    private static var occupied = false
    private var finish: ((Bool) -> Void)?
    private weak var window: NSWindow?
    private var alert: NSAlert?
    private var observer: NSObjectProtocol?
    private var lease: UUID?

    func approve(_ action: Action, window: NSWindow?) async -> Bool {
        guard !Self.occupied, let window, window.isVisible, window.attachedSheet == nil else { return false }
        Self.occupied = true
        let lease = UUID()
        self.lease = lease
        let alert = NSAlert()
        let text: String
        switch action {
        case .submitPrompt(let prompt, let conversation):
            alert.messageText = "Send message from widget?"
            alert.informativeText = "Conversation: \(conversation)"
            text = prompt
        case .openLink(let url, let source):
            alert.messageText = "Open external link?"
            alert.informativeText = "App view: \(source)"
            text = url.absoluteString
        }
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        let confirm: String
        switch action {
        case .submitPrompt: confirm = "Send message"
        case .openLink: confirm = "Open link"
        }
        alert.addButton(withTitle: confirm).keyEquivalent = ""
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 440, height: 140))
        scroll.hasVerticalScroller = true
        let view = NSTextView(frame: scroll.bounds)
        view.isEditable = false
        view.isSelectable = true
        view.isVerticallyResizable = true
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.containerSize = NSSize(
            width: scroll.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = true
        view.string = text
        scroll.documentView = view
        alert.accessoryView = scroll
        self.window = window
        self.alert = alert
        return await withCheckedContinuation { continuation in
            finish = { [weak self] approved in
                guard let self, self.lease == lease, self.finish != nil else { return }
                self.lease = nil
                self.finish = nil
                if let observer = self.observer { NotificationCenter.default.removeObserver(observer) }
                self.observer = nil
                self.alert = nil
                self.window = nil
                Self.occupied = false
                continuation.resume(returning: approved)
            }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.invalidate() }
            }
            alert.beginSheetModal(for: window) { [weak self] response in
                guard self?.lease == lease else { return }
                self?.finish?(response == .alertSecondButtonReturn)
            }
        }
    }

    func invalidate() {
        let alert = alert
        let window = window
        finish?(false)
        if let alert, let window { window.endSheet(alert.window) }
    }
}
