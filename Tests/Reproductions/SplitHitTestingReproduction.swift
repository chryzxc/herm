import AppKit
import SwiftUI

/// Compile with FractionPreservingSplitView.swift and DockWindowHostingView.swift.
@main
struct SplitHitTestingReproduction {
    @MainActor
    static func main() {
        _ = NSApplication.shared
        let parent = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 700))
        let split = FractionPreservingSplitView(frame: NSRect(x: 40, y: 30, width: 1000, height: 600))
        split.isVertical = true
        split.dividerStyle = .thin
        parent.addSubview(split)
        let window = NSWindow(
            contentRect: parent.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = parent
        defer { window.orderOut(nil) }
        let leading = CountingPane()
        let trailing = CountingPane()
        split.addArrangedSubview(leading)
        split.addArrangedSubview(trailing)
        split.adjustSubviews()
        split.setPosition(400, ofDividerAt: 0)
        split.layoutSubtreeIfNeeded()
        print("split=\(split.frame) leading=\(leading.frame) trailing=\(trailing.frame)")
        leading.calls = 0
        trailing.calls = 0
        let hit = split.hitTest(leading.convert(NSPoint(x: 100, y: 100), to: parent))
        print("leading_hit=\(hit === leading) leading_calls=\(leading.calls) unrelated_calls=\(trailing.calls)")
        let isolated = hit === leading && leading.calls == 1 && trailing.calls == 0
        print(isolated ? "PASS: unrelated pane skipped" : "FAIL: unrelated pane traversed on input routing")
        exit(isolated ? 0 : 1)
    }

    @MainActor
    private final class CountingPane: NSView {
        var calls = 0

        override func hitTest(_ point: NSPoint) -> NSView? {
            calls += 1
            return super.hitTest(point)
        }
    }
}
