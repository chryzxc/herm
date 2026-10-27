import AppKit
import Testing

@testable import Herm

@MainActor
struct KanbanCardDragTests {
    @Test func dragPreservesCardSizeAndDoesNotSelectOnRelease() throws {
        let view = RecordingKanbanDragView(frame: NSRect(x: 0, y: 0, width: 256, height: 94))
        view.taskID = "task-one"
        view.isEnabled = true
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        var selections = 0
        var dragging = false
        view.select = { selections += 1 }
        view.dragging = { dragging = $0 }
        func mouse(_ type: NSEvent.EventType, x: CGFloat) throws -> NSEvent {
            try #require(
                NSEvent.mouseEvent(
                    with: type, location: NSPoint(x: x, y: 30), modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        view.mouseDown(with: try mouse(.leftMouseDown, x: 20))
        view.mouseDragged(with: try mouse(.leftMouseDragged, x: 22))
        #expect(view.starts == 0)
        view.mouseDragged(with: try mouse(.leftMouseDragged, x: 40))
        view.mouseDragged(with: try mouse(.leftMouseDragged, x: 60))
        #expect(view.starts == 1)
        #expect(dragging)
        let item = try #require(view.draggingItem())
        #expect(item.draggingFrame == view.bounds)
        #expect((item.item as? NSString) == "task-one")
        view.mouseUp(with: try mouse(.leftMouseUp, x: 60))
        #expect(selections == 0)
        view.endDrag()
        #expect(!dragging)
        view.isEnabled = false
        view.mouseDown(with: try mouse(.leftMouseDown, x: 20))
        view.mouseDragged(with: try mouse(.leftMouseDragged, x: 40))
        view.mouseUp(with: try mouse(.leftMouseUp, x: 40))
        #expect(view.starts == 1)
        #expect(selections == 1)
        #expect(!view.mouseDownCanMoveWindow)
    }
}

@MainActor
private final class RecordingKanbanDragView: KanbanCardDragView {
    var starts = 0
    override func beginDrag(with event: NSEvent) {
        starts += 1
        dragging?(true)
    }
}
