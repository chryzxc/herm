import AppKit
import SwiftUI

struct KanbanCardDragSource: NSViewRepresentable {
    let taskID: String
    let isEnabled: Bool
    let select: () -> Void
    let dragging: (Bool) -> Void

    func makeNSView(context: Context) -> KanbanCardDragView { KanbanCardDragView() }

    func updateNSView(_ view: KanbanCardDragView, context: Context) {
        view.taskID = taskID
        view.isEnabled = isEnabled
        view.select = select
        view.dragging = dragging
    }
}

/// Captures the actual card before dimming its source, preserving the pointer's grab position.
class KanbanCardDragView: NSView, NSDraggingSource {
    var taskID = ""
    var isEnabled = false
    var select: (() -> Void)?
    var dragging: ((Bool) -> Void)?
    private var pressPoint: NSPoint?
    private var didDrag = false

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        pressPoint = event.locationInWindow
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEnabled, let pressPoint, !didDrag,
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
        guard let canvas = window?.contentView else { return nil }
        let rect = convert(bounds, to: canvas)
        guard let bitmap = canvas.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        canvas.cacheDisplay(in: rect, to: bitmap)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(bitmap)
        let item = NSDraggingItem(pasteboardWriter: taskID as NSString)
        item.setDraggingFrame(bounds, contents: image)
        return item
    }

    func beginDrag(with event: NSEvent) {
        guard let item = draggingItem() else { return }
        dragging?(true)
        let session = beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext)
        -> NSDragOperation
    {
        context == .withinApplication ? .move : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        endDrag()
    }

    func endDrag() {
        pressPoint = nil
        didDrag = false
        dragging?(false)
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
}
