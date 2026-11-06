import AppKit
import Combine
import SwiftUI
import Testing

@testable import Herm

@MainActor
struct DockDisclosureMotionTests {
    private final class Expansion: ObservableObject {
        @Published var isExpanded = true
    }

    private struct Input: NSViewRepresentable {
        func makeNSView(context: Context) -> NSTextField { NSTextField(string: "Draft") }
        func updateNSView(_ view: NSTextField, context: Context) {}
    }

    private struct Fixture: View {
        @ObservedObject var expansion: Expansion
        var body: some View {
            DockRetainedDisclosureContent(isExpanded: expansion.isExpanded) {
                Input().frame(height: 28)
            }
            .frame(width: 240, height: 100, alignment: .top)
            .dockThemedRoot()
        }
    }

    @Test func animatedDisclosurePreservesTheMountedInputAndItsDraft() async throws {
        let expansion = Expansion()
        let host = NSHostingView(rootView: Fixture(expansion: expansion))
        host.frame = NSRect(x: 0, y: 0, width: 240, height: 100)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        let input = try #require(textField(in: host))
        input.stringValue = "Unsent changes"
        for expanded in [false, true, false, true] {
            expansion.isExpanded = expanded
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(250))
            #expect(textField(in: host) === input)
            #expect(input.stringValue == "Unsent changes")
        }
    }

    private func textField(in view: NSView) -> NSTextField? {
        if let input = view as? NSTextField { return input }
        return view.subviews.lazy.compactMap { textField(in: $0) }.first
    }
}
