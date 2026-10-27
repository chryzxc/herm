import AppKit
import SwiftUI

struct SessionInspectorTabHoverArea: NSViewRepresentable {
    var surface: (NSView) -> Void = { _ in }
    let hover: (Bool) -> Void

    func makeNSView(context: Context) -> SessionInspectorTabHoverView { SessionInspectorTabHoverView() }
    func updateNSView(_ view: SessionInspectorTabHoverView, context: Context) {
        view.hover = hover
        surface(view)
    }
}

final class SessionInspectorTabHoverView: NSView {
    var hover: ((Bool) -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hover?(true) }
    override func mouseExited(with event: NSEvent) { hover?(false) }
}

/// Owns pointer input in the unified title row; the window must never claim a tab drag.
struct SessionInspectorTabDragSource<Content: View>: NSViewRepresentable {
    let payload: SessionInspectorTabDrag
    let title: String
    let isSelected: Bool
    let select: () -> Void
    let dragging: (Bool) -> Void
    let entered: () -> Void
    let content: Content
    var preview: () -> NSView? = { nil }

    func makeNSView(context: Context) -> SessionInspectorTabDragView { SessionInspectorTabDragView() }

    func updateNSView(_ view: SessionInspectorTabDragView, context: Context) {
        view.payload = payload
        view.select = select
        view.dragging = dragging
        view.entered = entered
        view.preview = preview
        view.setAccessibilityLabel("Show \(title)")
        view.setAccessibilitySelected(isSelected)
        view.label.rootView = AnyView(
            content.environment(\.colorScheme, context.environment.colorScheme)
                .environment(\.dockWorkspaceScale, context.environment.dockWorkspaceScale))
        view.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SessionInspectorTabDragView, context: Context) -> CGSize? {
        nsView.label.intrinsicContentSize
    }
}

class SessionInspectorTabDragView: NSView, NSDraggingSource {
    let label = NSHostingView(rootView: AnyView(EmptyView()))
    var payload: SessionInspectorTabDrag?
    var select: (() -> Void)?
    var dragging: ((Bool) -> Void)?
    var entered: (() -> Void)?
    var preview: (() -> NSView?)?
    private var pressPoint: NSPoint?
    private var didDrag = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.sizingOptions = [.intrinsicContentSize]
        addSubview(label)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        label.frame = bounds
    }

    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }

    override var mouseDownCanMoveWindow: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityPerformPress() -> Bool {
        guard let select else { return false }
        select()
        return true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49 { select?() } else { super.keyDown(with: event) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { entered?() }

    override func mouseDown(with event: NSEvent) {
        pressPoint = event.locationInWindow
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pressPoint, !didDrag,
            hypot(event.locationInWindow.x - pressPoint.x, event.locationInWindow.y - pressPoint.y) >= 4
        else { return }
        didDrag = true
        beginDrag(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        let clicked = pressPoint != nil && !didDrag && bounds.contains(convert(event.locationInWindow, from: nil))
        pressPoint = nil
        didDrag = false
        if clicked { select?() }
    }

    func draggingItem() -> NSDraggingItem? {
        guard let payload, let data = try? JSONEncoder().encode(payload) else { return nil }
        let pasteboard = NSPasteboardItem()
        pasteboard.setData(data, forType: SessionInspectorTabDrag.pasteboardType)
        let item = NSDraggingItem(pasteboardWriter: pasteboard)
        let surface = preview?() ?? self
        let frame = convert(surface.bounds, from: surface)
        let image = NSImage(size: frame.size)
        if let canvas = surface.window?.contentView ?? surface.superview {
            let rect = surface.convert(surface.bounds, to: canvas)
            if let bitmap = canvas.bitmapImageRepForCachingDisplay(in: rect) {
                canvas.cacheDisplay(in: rect, to: bitmap)
                image.addRepresentation(bitmap)
            }
        }
        item.setDraggingFrame(frame, contents: image)
        return item
    }

    func beginDrag(with event: NSEvent) {
        guard let item = draggingItem() else { return }
        dragging?(true)
        _ = beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext)
        -> NSDragOperation
    {
        context == .withinApplication ? .move : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        pressPoint = nil
        didDrag = false
        dragging?(false)
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
}

struct SessionInspectorTabDropDelegate: DropDelegate {
    @Binding var isTargeted: Bool
    let reorder: @MainActor (SessionInspectorTabDrag) -> Bool

    func dropEntered(info: DropInfo) { isTargeted = true }
    func dropExited(info: DropInfo) { isTargeted = false }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        let providers = info.itemProviders(for: [SessionInspectorTabDrag.pasteboardType.rawValue])
        guard providers.count == 1, let provider = providers.first else { return false }
        let reorder = reorder
        _ = provider.loadTransferable(type: SessionInspectorTabDrag.self) { result in
            guard case .success(let payload) = result else { return }
            Task { @MainActor in _ = reorder(payload) }
        }
        return true
    }
}
