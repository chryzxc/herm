import AppKit
import SwiftUI

/// A lightweight right-edge launcher that is independent from the menu-bar item.
@MainActor
final class EdgeDockController: NSObject {
    private enum Metrics {
        static let notchWidth: CGFloat = 9
        static let notchHeight: CGFloat = 52
        static let expandedWidth: CGFloat = 420
        static let expandedHeight: CGFloat = 720
        static let screenInset: CGFloat = 12
        static let hoverDelay: TimeInterval = 0.18
        static let collapseDelay: TimeInterval = 0.28
        static let animationDuration: TimeInterval = 0.28
    }

    private let model: DockModel
    private let presentation = DockPanelPresentation()
    private let notchPanel: EdgeDockPanel
    private let expandedPanel: EdgeDockPanel
    private var notchView: EdgeNotchView?
    private var collapseWorkItem: DispatchWorkItem?
    private var isPinned = false
    private var isExpanded = false

    init(model: DockModel) {
        self.model = model
        notchPanel = EdgeDockPanel(
            contentRect: .zero,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        expandedPanel = EdgeDockPanel(
            contentRect: .zero,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()
        configureNotch()
        configureExpandedPanel()
        showNotch()
    }

    private func configureNotch() {
        notchPanel.level = .statusBar
        notchPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        notchPanel.backgroundColor = .clear
        notchPanel.isOpaque = false
        notchPanel.hasShadow = true
        notchPanel.hidesOnDeactivate = false
        notchPanel.onCancel = { [weak self] in self?.collapse() }

        let view = EdgeNotchView()
        view.onHoverChanged = { [weak self] hovering in
            self?.handleNotchHover(hovering)
        }
        view.onClick = { [weak self] in
            self?.togglePinned()
        }
        notchView = view
        notchPanel.contentView = view
    }

    private func configureExpandedPanel() {
        expandedPanel.level = .statusBar
        expandedPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        expandedPanel.backgroundColor = .clear
        expandedPanel.isOpaque = false
        expandedPanel.hasShadow = true
        expandedPanel.hidesOnDeactivate = false
        expandedPanel.onCancel = { [weak self] in self?.collapse() }

        let hostingView = EdgeDockHostingView(
            rootView: DockPopover(
                model: model,
                panelPresentation: presentation,
                availableWorkspaceWidth: { [weak self] in
                    self?.availableWidth() ?? Metrics.expandedWidth
                },
                onWorkspaceWidthChange: { [weak self] width in
                    self?.resizeExpanded(to: width)
                    return width
                },
                onClose: { [weak self] in self?.collapse() },
                onFullscreenToggle: {}
            )
        )
        hostingView.onHoverChanged = { [weak self] hovering in
            if hovering {
                self?.collapseWorkItem?.cancel()
            } else if self?.isPinned == false {
                self?.scheduleCollapse()
            }
        }
        hostingView.wantsLayer = true
        hostingView.layer?.masksToBounds = false
        expandedPanel.contentView = hostingView
    }

    private func showNotch() {
        guard let screen = targetScreen else { return }
        let frame = screen.visibleFrame
        let notchFrame = NSRect(
            x: frame.maxX - Metrics.notchWidth,
            y: max(frame.minY + Metrics.screenInset, frame.midY - Metrics.notchHeight / 2),
            width: Metrics.notchWidth,
            height: Metrics.notchHeight
        )
        notchPanel.setFrame(notchFrame, display: true)
        notchPanel.orderFrontRegardless()
    }

    private func handleNotchHover(_ hovering: Bool) {
        if hovering {
            collapseWorkItem?.cancel()
            guard !isPinned else { return }
            let work = DispatchWorkItem { [weak self] in self?.expand(pinned: false) }
            collapseWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Metrics.hoverDelay, execute: work)
        } else if !isPinned {
            scheduleCollapse()
        }
    }

    private func togglePinned() {
        collapseWorkItem?.cancel()
        if isPinned {
            collapse()
        } else {
            expand(pinned: true)
        }
    }

    private func expand(pinned: Bool) {
        guard !isExpanded, let screen = targetScreen else {
            isPinned = pinned
            return
        }
        isPinned = pinned
        isExpanded = true
        presentation.isEdgeAttached = true
        let target = expandedFrame(in: screen)
        let start = NSRect(
            x: target.maxX - Metrics.notchWidth,
            y: target.midY - Metrics.notchHeight / 2,
            width: Metrics.notchWidth,
            height: Metrics.notchHeight
        )
        expandedPanel.setFrame(start, display: true)
        expandedPanel.alphaValue = 0.96
        expandedPanel.orderFrontRegardless()
        notchPanel.orderOut(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Metrics.animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            expandedPanel.animator().setFrame(target, display: true)
            expandedPanel.animator().alphaValue = 1
        }
        NSApp.activate()
        expandedPanel.makeKeyAndOrderFront(nil)
        model.markPopoverVisible()
    }

    private func scheduleCollapse() {
        collapseWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isPinned else { return }
            self.collapse()
        }
        collapseWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Metrics.collapseDelay, execute: work)
    }

    private func collapse() {
        collapseWorkItem?.cancel()
        isPinned = false
        guard isExpanded else {
            showNotch()
            return
        }
        isExpanded = false
        expandedPanel.orderOut(nil)
        presentation.isEdgeAttached = false
        model.markPopoverHidden()
        showNotch()
    }

    private func resizeExpanded(to width: CGFloat) {
        guard isExpanded, let screen = targetScreen else { return }
        var frame = expandedFrame(in: screen)
        frame.size.width = min(max(width, 420), availableWidth())
        frame.origin.x = screen.visibleFrame.maxX - frame.width
        expandedPanel.setFrame(frame, display: true)
    }

    private func expandedFrame(in screen: NSScreen) -> NSRect {
        let frame = screen.visibleFrame
        let width = min(Metrics.expandedWidth, availableWidth())
        return NSRect(
            x: frame.maxX - width,
            y: max(frame.minY + Metrics.screenInset, frame.midY - Metrics.expandedHeight / 2),
            width: width,
            height: min(Metrics.expandedHeight, frame.height - Metrics.screenInset * 2)
        )
    }

    private func availableWidth() -> CGFloat {
        guard let screen = targetScreen else { return Metrics.expandedWidth }
        return max(420, screen.visibleFrame.width - Metrics.screenInset * 2)
    }

    private var targetScreen: NSScreen? {
        NSScreen.main ?? NSScreen.screens.first
    }
}

@MainActor
private final class EdgeDockPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

private final class EdgeDockHostingView<Content: View>: NSHostingView<Content> {
    var onHoverChanged: ((Bool) -> Void)?
    private var trackingAreaRef: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef { removeTrackingArea(trackingAreaRef) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        trackingAreaRef = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) { onHoverChanged?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChanged?(false) }
}

private final class EdgeNotchView: NSView {
    var onHoverChanged: ((Bool) -> Void)?
    var onClick: (() -> Void)?
    private var trackingAreaRef: NSTrackingArea?

    override var isFlipped: Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef { removeTrackingArea(trackingAreaRef) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        trackingAreaRef = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) { onHoverChanged?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChanged?(false) }
    override func mouseUp(with event: NSEvent) { onClick?() }

    override func draw(_ dirtyRect: NSRect) {
        // Only the inward-facing side is rounded. The outer edge is flush with
        // the display edge, making this read as a screen notch rather than a
        // floating button.
        let radius = min(bounds.height / 2, 5)
        let path = NSBezierPath()
        path.move(to: NSPoint(x: bounds.minX + radius, y: bounds.minY))
        path.line(to: NSPoint(x: bounds.maxX, y: bounds.minY))
        path.line(to: NSPoint(x: bounds.maxX, y: bounds.maxY))
        path.line(to: NSPoint(x: bounds.minX + radius, y: bounds.maxY))
        path.curve(
            to: NSPoint(x: bounds.minX, y: bounds.maxY - radius),
            controlPoint1: NSPoint(x: bounds.minX, y: bounds.maxY),
            controlPoint2: NSPoint(x: bounds.minX, y: bounds.maxY - radius)
        )
        path.line(to: NSPoint(x: bounds.minX, y: bounds.minY + radius))
        path.curve(
            to: NSPoint(x: bounds.minX + radius, y: bounds.minY),
            controlPoint1: NSPoint(x: bounds.minX, y: bounds.minY),
            controlPoint2: NSPoint(x: bounds.minX, y: bounds.minY)
        )
        path.close()
        NSColor.white.withAlphaComponent(0.16).setFill()
        path.fill()

        NSColor.white.withAlphaComponent(0.24).setStroke()
        path.lineWidth = 0.5
        path.stroke()
    }
}
