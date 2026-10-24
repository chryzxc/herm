import AppKit
import Combine
import SwiftUI

struct DockActionError: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
}

/// Transient feedback for explicit actions; background projections keep their own stale states.
@MainActor
final class DockActionErrorCenter: ObservableObject {
    static let shared = DockActionErrorCenter()
    @Published private(set) var current: DockActionError?

    func report(_ title: String, error: Error) {
        guard !(error is CancellationError), (error as? URLError)?.code != .cancelled else { return }
        report(title, message: error.localizedDescription)
    }

    func report(_ title: String, message: String) {
        let safeMessage = HermesDiagnosticsService.safeSummary(message)
        current = DockActionError(
            title: HermesDiagnosticsService.safeSummary(title),
            message: safeMessage.isEmpty ? "The action could not be completed. Try again." : safeMessage)
    }

    func dismiss(_ id: UUID) {
        if current?.id == id { current = nil }
    }
}

struct DockActionErrorPopup: View {
    let error: DockActionError
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            DockIcon(.warningCircle, size: 18, weight: .fill, color: .dockDestructive)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(error.title).dockFont(.body, weight: .semibold)
                Text(error.message).dockFont(.body).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(Color.dockPrimaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: dismiss) {
                DockIcon(.x, size: 12, color: .dockPrimaryText)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.dockHover)
            .help("Dismiss error")
            .accessibilityLabel("Dismiss error")
        }
        .padding(16)
        .background {
            let shape = DockThemeShape(cornerRadius: DockLayout.paneRadius, role: .pane)
            shape.fill(Color.dockOpaqueCanvas)
            shape.fill(Color.dockDestructive.opacity(0.18))
            shape.stroke(Color.dockDestructive.opacity(0.6), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("dock.action-error")
        .onExitCommand(perform: dismiss)
    }
}

/// A child panel stays above sheets and never inserts a row into a feature's layout.
@MainActor
final class DockActionErrorPresenter {
    private let center: DockActionErrorCenter
    private var observation: AnyCancellable?
    private var panel: NSPanel?

    init(center: DockActionErrorCenter = .shared) {
        self.center = center
        observation = center.$current.sink { [weak self] error in self?.show(error) }
    }

    private func show(_ error: DockActionError?) {
        if let panel {
            let parent = panel.parent
            let restoreFocus = panel.isKeyWindow
            parent?.removeChildWindow(panel)
            panel.close()
            self.panel = nil
            if restoreFocus, parent?.isVisible == true { parent?.makeKey() }
        }
        guard let error, let parent = NSApp.keyWindow ?? NSApp.mainWindow,
            let screen = parent.screen
        else { return }
        let width = min(420, screen.visibleFrame.width - 32)
        let host = DockActionErrorHostingView(
            rootView: DockActionErrorPopup(error: error) { [weak center] in center?.dismiss(error.id) }
                .frame(width: width)
                .dockThemedRoot())
        let height = host.fittingSize.height
        let panel = DockActionErrorPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.sharingType = parent.sharingType
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = parent.level
        panel.contentView = host
        let visible = screen.visibleFrame
        panel.setFrameOrigin(
            NSPoint(
                x: min(max(parent.frame.maxX - width - 20, visible.minX + 16), visible.maxX - width - 16),
                y: min(max(parent.frame.minY + 20, visible.minY + 16), visible.maxY - height - 16)))
        self.panel = panel
        parent.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        NSAccessibility.post(
            element: host, notification: .announcementRequested,
            userInfo: [
                .announcement: "\(error.title). \(error.message)",
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ])
    }
}

/// Borderless panels otherwise refuse focus, so AppKit can discard their first click.
private final class DockActionErrorPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class DockActionErrorHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
