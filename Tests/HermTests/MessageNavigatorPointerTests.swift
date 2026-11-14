import AppKit
import SwiftUI
import XCTest

@testable import Herm

final class MessageNavigatorPointerTests: XCTestCase {
    @MainActor
    func testLayoutDefersHoverPublicationAndMovementEventsPublishExit() async throws {
        _ = NSApplication.shared
        let window = VisibleNavigatorTestWindow(
            contentRect: NSRect(x: 100, y: 100, width: 200, height: 200),
            styleMask: [.borderless], backing: .buffered, defer: false)
        let strip = RailPointerStrip.StripView(frame: NSRect(x: 0, y: 0, width: 28, height: 100))
        var location = window.convertPoint(toScreen: NSPoint(x: 10, y: 50))
        strip.pointerLocation = { location }
        var topmostWindow = window.windowNumber + 1
        strip.windowNumberAtPoint = { _ in topmostWindow }
        var moves: [CGFloat] = []
        var exits = 0
        let moved = expectation(description: "deferred hover")
        strip.onMove = { y in
            moves.append(y)
            moved.fulfill()
        }
        strip.onExit = { exits += 1 }
        window.contentView?.addSubview(strip)
        XCTAssertTrue(strip.bounds.contains(strip.convert(window.convertPoint(fromScreen: location), from: nil)))
        defer { strip.removeFromSuperview() }
        strip.callbacksReady = true
        strip.refreshPointer()
        XCTAssertTrue(moves.isEmpty, "a foreign topmost window must suppress hover")
        topmostWindow = window.windowNumber
        strip.layout()
        XCTAssertTrue(moves.isEmpty, "layout must not publish during a SwiftUI update")
        await fulfillment(of: [moved], timeout: 2)
        XCTAssertEqual(moves.count, 1)
        let event = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        XCTAssertTrue(strip.handlePointerEvent(event) === event)
        XCTAssertEqual(moves.count, 1, "unchanged pointer must not publish twice")
        location = window.convertPoint(toScreen: NSPoint(x: 40, y: 50))
        XCTAssertTrue(strip.handlePointerEvent(event) === event)
        XCTAssertEqual(exits, 1)
        XCTAssertNil(timer(in: strip))
    }

    @MainActor
    func testPollingFollowsPointerAndWindowLifecycle() throws {
        _ = NSApplication.shared
        let window = VisibleNavigatorTestWindow(
            contentRect: NSRect(x: 100, y: 100, width: 200, height: 200),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.acceptsMouseMovedEvents = false
        let strip = RailPointerStrip.StripView(frame: NSRect(x: 0, y: 0, width: 28, height: 100))
        var location = window.convertPoint(toScreen: NSPoint(x: 40, y: 50))
        strip.pointerLocation = { location }
        window.contentView?.addSubview(strip)
        defer { strip.removeFromSuperview() }
        XCTAssertTrue(window.acceptsMouseMovedEvents)
        XCTAssertNil(timer(in: strip))

        location = window.convertPoint(toScreen: NSPoint(x: 10, y: 50))
        strip.refreshPointer()
        let first = try XCTUnwrap(timer(in: strip))
        XCTAssertTrue(first.isValid)
        strip.refreshPointer()
        XCTAssertTrue(timer(in: strip) === first)

        location = window.convertPoint(toScreen: NSPoint(x: 40, y: 50))
        first.fire()
        XCTAssertFalse(first.isValid)
        XCTAssertNil(timer(in: strip))
        strip.removeFromSuperview()
        XCTAssertFalse(window.acceptsMouseMovedEvents)
    }

    @MainActor
    private func timer(in strip: RailPointerStrip.StripView) -> Timer? {
        guard let storage = Mirror(reflecting: strip).children.first(where: { $0.label == "timer" }) else { return nil }
        return Mirror(reflecting: storage.value).children.first?.value as? Timer
    }

    @MainActor
    func testVisibleNavigatorDoesNotPollWhenPointerIsOutsideStrip() async throws {
        _ = NSApplication.shared
        let items = MessageNavigator.items(
            messages: (0..<24).map { ChatMessage(role: .user, text: "Message \($0)") },
            sessionID: "pointer-idle")
        let host = NSHostingView(
            rootView: MessageNavigatorView(
                snapshot: MessageNavigatorSnapshot(items: items), sessionID: "pointer-idle",
                visibleTargets: [], isSearchPresented: .constant(false), onSelect: { _ in }))
        host.sizingOptions = []
        host.frame = NSRect(x: 0, y: 0, width: 286, height: 600)
        let pointer = NSEvent.mouseLocation
        let window = VisibleNavigatorTestWindow(
            contentRect: NSRect(x: pointer.x + 2_000, y: pointer.y + 2_000, width: 286, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        for _ in 0..<3 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        let strip = try XCTUnwrap(
            descendants(host).first { view in
                String(reflecting: type(of: view)).contains("RailPointerStrip")
                    && String(reflecting: type(of: view)).hasSuffix("StripView")
            })
        let local = strip.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        XCTAssertFalse(strip.bounds.contains(local), "Fixture must place the pointer outside the rail")
        let timerStorage = try XCTUnwrap(Mirror(reflecting: strip).children.first { $0.label == "timer" })
        let timer = Mirror(reflecting: timerStorage.value).children.first?.value as? Timer
        XCTAssertFalse(
            timer?.isValid == true, "A visible navigator must not schedule idle pointer polling outside its strip")
    }

    @MainActor
    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }
}

/// Controls only the window-visibility boundary; no real app is opened or pointer moved.
@MainActor
private final class VisibleNavigatorTestWindow: NSWindow {
    override var isVisible: Bool { true }
    override var occlusionState: NSWindow.OcclusionState { [.visible] }
}
