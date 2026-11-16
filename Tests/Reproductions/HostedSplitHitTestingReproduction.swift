import AppKit
import SwiftUI

@MainActor
private final class CountingHost: NSHostingView<AnyView> {
    var calls = 0

    override func hitTest(_ point: NSPoint) -> NSView? {
        calls += 1
        return super.hitTest(point)
    }
}

@MainActor
private final class CountingPane: NSView {
    var calls = 0

    override func hitTest(_ point: NSPoint) -> NSView? {
        calls += 1
        return super.hitTest(point)
    }
}

private struct HostedSplit: NSViewRepresentable {
    let split: FractionPreservingSplitView

    func makeNSView(context: Context) -> FractionPreservingSplitView { split }
    func updateNSView(_ view: FractionPreservingSplitView, context: Context) {}
}

@MainActor
private final class ExtendedDividerDelegate: NSObject, NSSplitViewDelegate {
    func splitView(_ splitView: NSSplitView, additionalEffectiveRectOfDividerAt dividerIndex: Int) -> NSRect {
        NSRect(x: 100, y: 100, width: 20, height: 20)
    }
}

@main
struct HostedSplitHitTestingReproduction {
    @MainActor
    static func main() {
        _ = NSApplication.shared
        let parent = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 700))
        let window = NSWindow(contentRect: parent.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = parent
        defer { window.orderOut(nil) }

        let outer = FractionPreservingSplitView(frame: NSRect(x: 40, y: 30, width: 1000, height: 600))
        outer.isVertical = true
        outer.dividerStyle = .thin
        parent.addSubview(outer)
        let inner = FractionPreservingSplitView(frame: .zero)
        inner.isVertical = true
        inner.dividerStyle = .thin
        let first = CountingPane()
        let second = CountingPane()
        inner.addArrangedSubview(first)
        inner.addArrangedSubview(second)
        let host = CountingHost(rootView: AnyView(HostedSplit(split: inner).padding(25)))
        host.sizingOptions = []
        let other = CountingHost(rootView: AnyView(Color.clear))
        other.sizingOptions = []
        outer.addArrangedSubview(host)
        outer.addArrangedSubview(other)
        outer.adjustSubviews()
        outer.setPosition(600, ofDividerAt: 0)
        outer.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()
        inner.adjustSubviews()
        inner.setPosition(240, ofDividerAt: 0)
        inner.layoutSubtreeIfNeeded()

        var failures = 0
        func check(_ condition: Bool, _ description: String) {
            print("\(condition ? "PASS" : "FAIL"): \(description)")
            if !condition { failures += 1 }
        }
        let innerOrigin = inner.convert(NSPoint.zero, to: outer)
        check(
            inner.superview != nil && innerOrigin.x > 0 && innerOrigin.y > 0,
            "SwiftUI-hosted inner split origin in outer: \(innerOrigin)"
        )
        for (target, sibling, name) in [(first, second, "leading"), (second, first, "trailing")] {
            first.calls = 0
            second.calls = 0
            host.calls = 0
            other.calls = 0
            let point = target.convert(NSPoint(x: target.bounds.midX, y: target.bounds.midY), to: parent)
            let hit = outer.hitTest(point)
            let isolated =
                hit === target && target.calls == 1 && sibling.calls == 0
                && host.calls == 1 && other.calls == 0
            let counts = "target=\(target.calls) sibling=\(sibling.calls) host=\(host.calls) other=\(other.calls)"
            check(isolated, "hosted \(name): \(counts) hit=\(hit === target)")
        }

        let plain = NSSplitView(frame: outer.frame)
        plain.isVertical = true
        plain.dividerStyle = .thin
        let plainFirst = NSView()
        let plainSecond = NSView()
        plain.addArrangedSubview(plainFirst)
        plain.addArrangedSubview(plainSecond)
        parent.addSubview(plain)
        plain.adjustSubviews()
        plain.setPosition(600, ofDividerAt: 0)
        plain.layoutSubtreeIfNeeded()
        let left = host.frame.maxX
        let right = other.frame.minX
        check(
            right > left && abs(plainFirst.frame.maxX - left) < 0.01
                && abs(plainSecond.frame.minX - right) < 0.01,
            "native and production divider geometry match"
        )
        for (x, name) in [(left - 0.25, "leading edge"), ((left + right) / 2, "gap"), (right + 0.25, "trailing edge")] {
            let point = outer.convert(NSPoint(x: x, y: outer.bounds.midY), to: parent)
            let actual = outer.hitTest(point)
            let reference = plain.hitTest(point)
            let actualKind = actual === outer ? "divider" : actual == nil ? "nil" : "pane"
            let referenceKind = reference === plain ? "divider" : reference == nil ? "nil" : "pane"
            check(actualKind == referenceKind, "\(name): production=\(actualKind) native=\(referenceKind)")
        }
        let extended = ExtendedDividerDelegate()
        outer.delegate = extended
        plain.delegate = extended
        let extendedPoint = outer.convert(NSPoint(x: 110, y: 110), to: parent)
        check(
            outer.hitTest(extendedPoint) === outer && plain.hitTest(extendedPoint) === plain,
            "delegate additional divider area matches native"
        )
        print("\(failures == 0 ? "PASS" : "FAIL"): \(failures) failed checks")
        exit(failures == 0 ? 0 : 1)
    }
}
