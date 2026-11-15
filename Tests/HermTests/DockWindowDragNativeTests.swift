import AppKit
import CoreGraphics
import SwiftUI
#if !DOCK_WINDOW_DRAG_STANDALONE
    import Testing
    @testable import Herm
#endif

@MainActor
private func verifyWindowDragAdmission(baseline: Bool) -> Int {
    _ = NSApplication.shared
    let root: NSHostingView<AnyView> =
        baseline
        ? NSHostingView(rootView: AnyView(EmptyView()))
        : DockWindowHostingView(rootView: AnyView(EmptyView()))
    let pane: NSHostingView<AnyView> =
        baseline
        ? NSHostingView(rootView: AnyView(EmptyView())) : splitPaneHost()
    let strip = TitlebarDoubleClickArea.Strip()
    var failures = 0
    for (name, view) in [("root", root), ("pane", pane)] {
        if view.mouseDownCanMoveWindow {
            print("FAIL \(name) host admits window dragging")
            failures += 1
        }
    }
    if !strip.mouseDownCanMoveWindow {
        print("FAIL blank strip does not admit window dragging")
        failures += 1
    }
    if !baseline && (!pane.sizingOptions.isEmpty || !pane.safeAreaRegions.isEmpty) {
        print("FAIL pane hosting options changed")
        failures += 1
    }
    print("SUMMARY admission failures=\(failures)")
    return failures
}

#if DOCK_WINDOW_DRAG_STANDALONE
    @MainActor
    private final class ActionCounter: ObservableObject {
        @Published var count = 0
    }

    private struct DragFixture: View {
        @ObservedObject var counter: ActionCounter
        let disabled: Bool
        var body: some View {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Spacer().background { TitlebarDoubleClickArea() }
                    Button(action: { counter.count += 1 }) {
                        Image(systemName: "arrow.clockwise").frame(width: 28, height: 28)
                    }
                    .disabled(disabled)
                    .padding(.trailing, 12)
                }
                .frame(height: 52)
                Spacer()
            }
        }
    }

    private enum PointerFailure: Error {
        case message(String)
    }

    @MainActor
    private func pointerSequence(_ point: CGPoint, drag: Bool) async throws {
        let end = CGPoint(x: point.x + (drag ? 40 : 0), y: point.y)
        let events: [(CGEventType, CGPoint)] =
            [
                (CGEventType.leftMouseDown, point),
                (drag ? .leftMouseDragged : .leftMouseUp, end),
            ] + (drag ? [(.leftMouseUp, end)] : [])
        for (index, item) in events.enumerated() {
            let (type, location) = item
            guard
                CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: location, mouseButton: .left)
                    != nil
            else {
                throw PointerFailure.message("cannot create mouse event")
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(index * 150)) {
                CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: location, mouseButton: .left)?
                    .post(tap: .cghidEventTap)
            }
        }
        try await Task.sleep(for: .milliseconds(events.count * 150 + 150))
    }

    @MainActor
    private func verifyPointer() async throws {
        guard CGPreflightPostEventAccess() else {
            throw PointerFailure.message("input posting permission unavailable; no permission was requested")
        }
        guard let screen = NSScreen.main, let original = CGEvent(source: nil)?.location else {
            throw PointerFailure.message("screen or pointer location unavailable")
        }
        defer { CGWarpMouseCursorPosition(original) }
        for width in [900.0, 1280.0] {
            guard screen.visibleFrame.width >= width, screen.visibleFrame.height >= 600 else {
                throw PointerFailure.message("display too small for \(width)x600 pointer fixture")
            }
            for dark in [false, true] {
                for nested in [false, true] {
                    for disabled in [false, true] {
                        let counter = ActionCounter()
                        let content = AnyView(DragFixture(counter: counter, disabled: disabled))
                        let host: NSHostingView<AnyView> =
                            nested ? splitPaneHost() : DockWindowHostingView(rootView: content)
                        host.rootView = content
                        host.safeAreaRegions = []
                        let window = NSWindow(
                            contentRect: NSRect(
                                x: screen.visibleFrame.minX, y: screen.visibleFrame.minY, width: width, height: 600),
                            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
                        window.titlebarAppearsTransparent = true
                        window.titleVisibility = .hidden
                        window.toolbar = NSToolbar(identifier: "window-drag-pointer-fixture")
                        window.toolbarStyle = .unified
                        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                        if nested {
                            let split = NSSplitView(frame: NSRect(x: 0, y: 0, width: width, height: 600))
                            split.addArrangedSubview(host)
                            window.contentView = split
                        } else {
                            window.contentView = host
                        }
                        window.makeKeyAndOrderFront(nil)
                        NSApp.activate(ignoringOtherApps: true)
                        defer { window.orderOut(nil) }
                        try await Task.sleep(for: .milliseconds(300))
                        host.layoutSubtreeIfNeeded()
                        func strips(_ view: NSView) -> [NSView] {
                            (view is TitlebarDoubleClickArea.Strip ? [view] : []) + view.subviews.flatMap(strips)
                        }
                        guard let strip = strips(host).first else { throw PointerFailure.message("strip missing") }
                        let stripRect = host.convert(strip.bounds, from: strip)
                        let icon = NSPoint(x: host.bounds.maxX - 26, y: stripRect.midY)
                        guard let hit = host.hitTest(host.convert(icon, to: host.superview)),
                            !(hit is TitlebarDoubleClickArea.Strip)
                        else {
                            throw PointerFailure.message("icon hit overlaps strip")
                        }
                        func screenPoint(_ point: NSPoint) -> CGPoint {
                            let inWindow = host.convert(point, to: nil)
                            let appKitPoint = window.convertPoint(toScreen: inWindow)
                            let mainHeight = CGDisplayBounds(CGMainDisplayID()).height
                            return CGPoint(x: appKitPoint.x, y: mainHeight - appKitPoint.y)
                        }
                        let iconScreen = screenPoint(icon)
                        let origin = window.frame.origin
                        try await pointerSequence(iconScreen, drag: true)
                        guard window.frame.origin == origin else {
                            throw PointerFailure.message("icon drag moved window")
                        }
                        try await pointerSequence(iconScreen, drag: false)
                        guard counter.count == (disabled ? 0 : 1) else {
                            throw PointerFailure.message("icon click count \(counter.count), disabled=\(disabled)")
                        }
                        let blank = screenPoint(NSPoint(x: stripRect.midX, y: stripRect.midY))
                        try await pointerSequence(blank, drag: true)
                        guard window.frame.origin != origin else {
                            throw PointerFailure.message("blank drag did not move window")
                        }
                        print(
                            "SUMMARY pointer width=\(width) dark=\(dark) pane=\(nested) "
                                + "disabled=\(disabled) click=\(counter.count) blank moved")
                        window.orderOut(nil)
                    }
                }
            }
        }
    }

    @main
    struct DockWindowDragStandalone {
        @MainActor static func main() {
            let arguments = Array(CommandLine.arguments.dropFirst())
            guard arguments.isEmpty || arguments == ["--baseline"] || arguments == ["--pointer"] else {
                print("FAIL unsupported arguments; use --baseline or --pointer")
                exit(2)
            }
            _ = NSApplication.shared
            Task { @MainActor in
                do {
                    let failures = verifyWindowDragAdmission(baseline: arguments.contains("--baseline"))
                    if failures != 0 { exit(1) }
                    if arguments.contains("--pointer") { try await verifyPointer() }
                    exit(0)
                } catch {
                    print("FAIL pointer \(error)")
                    exit(1)
                }
            }
            NSApp.run()
        }
    }
#else
    @MainActor
    struct DockWindowDragNativeTests {
        @Test func hostingViewsExcludeWindowDragging() {
            #expect(verifyWindowDragAdmission(baseline: false) == 0)
        }
    }
#endif
