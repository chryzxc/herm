import AppKit
import SwiftUI

/// A floating panel that can take typing: the composer needs key status, and a
/// detached chat stays above other apps so it can sit beside a browser.
private final class ConversationPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// One detached conversation's window. It projects the session through a disposable
/// `EdgeQuickConversationModel` (shared gateway, Hermes-owned history), so closing it
/// drops only the view: a running turn keeps going in Hermes.
@MainActor
final class ConversationWindowController: NSObject, NSWindowDelegate, ConversationWindowHandle {
    nonisolated static let defaultSize = CGSize(width: 460, height: 600)
    /// Wide enough for the transcript and composer toolbar to lay out without clipping the trailing edge.
    nonisolated static let minimumSize = CGSize(width: 420, height: 360)

    private let destination: QuickDestination
    private let sessionID: String
    private weak var runtime: DockModel?
    private let chat = EdgeQuickConversationModel()
    private let header: ConversationPopoutHeader
    private let worktree = ConversationWorktreeState()
    private weak var controlCenter: ControlCenterModel?
    private var window: NSPanel?
    private var loadTask: Task<Void, Never>?
    private var previewPanelOpen = false

    init(destination: QuickDestination, runtime: DockModel, controlCenter: ControlCenterModel, cascadeIndex: Int) {
        self.destination = destination
        self.sessionID = destination.sessionID ?? ""
        self.runtime = runtime
        let profile = destination.profileID.flatMap { $0 == runtime.profileScopeID ? nil : $0 }
        self.header = ConversationPopoutHeader(title: destination.title, profileLabel: profile)
        self.controlCenter = controlCenter
        super.init()
        window = makeWindow(controlCenter: controlCenter, bots: runtime.botMode, cascadeIndex: cascadeIndex)
        load()
    }

    func focus() {
        guard let window else { return }
        // Opened from the notch or a shortcut while another app is frontmost.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() { window?.close() }

    func retitle(_ title: String) {
        guard header.title != title else { return }
        header.title = title
        window?.title = title
    }

    /// Holds the minimum even when a saved frame or a live resize asks for less.
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        NSSize(width: max(frameSize.width, sender.minSize.width), height: max(frameSize.height, sender.minSize.height))
    }

    func windowWillClose(_ notification: Notification) {
        loadTask?.cancel()
        loadTask = nil
        worktree.stop()
        chat.shutdown()
        window?.delegate = nil
        // The store holds the last reference; release it after AppKit finishes closing.
        let sessionID = sessionID
        DispatchQueue.main.async { ConversationWindowStore.shared.windowDidClose(sessionID: sessionID) }
    }

    private func load() {
        // Rooms read the shared group-chat store; there is no session to project.
        guard let runtime, destination.groupRoomID == nil else { return }
        loadTask?.cancel()
        guard let resume = chat.startLoad(destination, runtime: runtime) else { return }
        loadTask = Task { [weak self, chat] in
            _ = await resume.value
            guard let self, !Task.isCancelled, let model = chat.conversation, let control = self.controlCenter
            else { return }
            self.worktree.track(model, control: control)
        }
    }

    /// Hands the composer's draft to a new main-window chat at `path`, like the main
    /// chat's worktree actions do, and leaves this conversation where it is.
    private func openInMain(_ path: String) {
        let composer = chat.conversation?.composer
        let draft = composer?.text ?? ""
        composer?.text = ""
        ConversationWindowStore.shared.openMainChat(path, draft)
    }

    @ViewBuilder
    private func content(control: ControlCenterModel, bots: BotModeModel) -> some View {
        if let roomID = destination.groupRoomID {
            ConversationPopoutRoomView(header: header, bots: bots, roomID: roomID, control: control) { [weak self] in
                self?.close()
            }
        } else {
            ConversationPopoutView(
                header: header, worktree: worktree, chat: chat, control: control, bots: bots,
                openQuota: { ConversationWindowStore.shared.showQuota() },
                openInMain: { [weak self] in self?.openInMain($0) },
                onRetry: { [weak self] in self?.load() },
                onPreviewPanel: { [weak self] in self?.setPreviewPanel($0) })
        }
    }

    /// Widens the window for the preview panel so the chat keeps its width, and narrows it
    /// again when the panel closes. The frame stays on the window's screen.
    private func setPreviewPanel(_ open: Bool) {
        guard let window, previewPanelOpen != open else { return }
        previewPanelOpen = open
        let extra = ConversationPopoutView.previewWidth + DockLayout.hairline
        var content = Self.minimumSize
        if open { content.width += extra }
        window.minSize = window.frameRect(forContentRect: CGRect(origin: .zero, size: content)).size
        var frame = window.frame
        frame.size.width = max(window.minSize.width, frame.width + (open ? extra : -extra))
        if let screen = (window.screen ?? NSScreen.main)?.visibleFrame {
            frame.size.width = min(frame.width, max(screen.width, window.minSize.width))
            if frame.maxX > screen.maxX { frame.origin.x = max(screen.minX, screen.maxX - frame.width) }
        }
        window.setFrame(frame, display: true, animate: false)
    }

    private var autosaveName: String { "HermConversationWindow." + sessionID }

    private func makeWindow(controlCenter: ControlCenterModel, bots: BotModeModel, cascadeIndex: Int) -> NSPanel {
        let window = ConversationPanel(
            contentRect: CGRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = destination.title
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // An empty compact toolbar centers the traffic lights in a short title row.
        window.toolbar = NSToolbar(identifier: "HermConversationWindowToolbar")
        window.toolbarStyle = .unifiedCompact
        window.titlebarSeparatorStyle = .none
        window.isFloatingPanel = true
        window.level = .floating
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.delegate = self
        let host = DockWindowHostingView(
            rootView: DockWindowWorkspace {
                content(control: controlCenter, bots: bots).modifier(ConversationWindowPresentation())
            })
        host.performanceRole = "conversationWindow"
        host.sizingOptions = []
        host.safeAreaRegions = []
        window.contentView = host
        // Set after the host: assigning a content view recomputes the window's limits.
        window.minSize = window.frameRect(forContentRect: CGRect(origin: .zero, size: Self.minimumSize)).size
        header.titleRowHeight = max(28, window.frame.height - window.contentLayoutRect.height)
        if let zoom = window.standardWindowButton(.zoomButton) {
            header.titleLeading = zoom.frame.maxX + 14
        }
        let saved = window.setFrameUsingName(autosaveName) ? window.frame : nil
        var frame = ConversationWindowStore.placement(
            saved: saved, screens: NSScreen.screens.map(\.visibleFrame), mouse: NSEvent.mouseLocation,
            size: window.frameRect(forContentRect: CGRect(origin: .zero, size: Self.defaultSize)).size,
            cascadeIndex: cascadeIndex)
        // A window saved before the minimum grew reopens at the minimum, not clipped.
        frame.size.width = max(frame.width, window.minSize.width)
        frame.size.height = max(frame.height, window.minSize.height)
        window.setFrame(frame, display: false)
        window.setFrameAutosaveName(autosaveName)
        return window
    }
}

private struct ConversationWindowPresentation: ViewModifier {
    @StateObject private var presentation = DockHostPresentation()

    func body(content: Content) -> some View {
        content
            .environment(\.dockHostVisible, presentation.isVisible)
            .environment(\.dockHostResizing, presentation.isResizing)
            .background { DockHostPresentationObserver(presentation: presentation).frame(width: 0, height: 0) }
    }
}
