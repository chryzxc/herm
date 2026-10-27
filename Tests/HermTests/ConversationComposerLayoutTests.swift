import AppKit
import SwiftUI
import Testing

@testable import Herm

@MainActor
struct ConversationComposerLayoutTests {
    private struct ComposerProbe: NSViewRepresentable {
        let field: NSTextField
        func makeNSView(context: Context) -> NSTextField { field }
        func updateNSView(_ nsView: NSTextField, context: Context) {}
    }

    @Test(arguments: [CGFloat(420), CGFloat(980)], [CGFloat(400), CGFloat(700)])
    func composerMovesFromWelcomeToBottomWithoutReplacingEditor(width: CGFloat, height: CGFloat) async throws {
        _ = NSApplication.shared
        let field = NSTextField(string: "Unsent draft")
        func content(empty: Bool) -> some View {
            ConversationComposerLayout(showsWelcome: empty, hermFaceID: nil) {
                Text("First message")
            } composer: {
                ComposerProbe(field: field).frame(height: 100)
            }
            .transaction { $0.disablesAnimations = true }
        }
        let host = NSHostingView(rootView: content(empty: true))
        host.sizingOptions = []
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.orderOut(nil) }

        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        host.layoutSubtreeIfNeeded()
        let centered = field.convert(field.bounds, to: host)
        #expect(centered.minY > 0)
        #expect(centered.maxY < height - 20)
        #expect(centered.midY > height / 2)
        #expect(centered.midY < height / 2 + 150)
        let editorParent = try #require(field.superview)

        host.rootView = content(empty: false)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        host.layoutSubtreeIfNeeded()
        let bottom = field.convert(field.bounds, to: host)
        #expect(abs(bottom.midY - (host.bounds.maxY - 50)) < 1)
        #expect(field.superview === editorParent)
        #expect(field.stringValue == "Unsent draft")

        host.rootView = content(empty: true)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        host.layoutSubtreeIfNeeded()
        #expect(abs(field.convert(field.bounds, to: host).minY - centered.minY) < 1)
        #expect(field.superview === editorParent)
    }
}
