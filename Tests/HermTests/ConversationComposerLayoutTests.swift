import AppKit
import SwiftUI
import Testing

@testable import Herm

@MainActor
struct ConversationComposerLayoutTests {
    @Test func welcomeIsCenteredWhenItsIdealWidthIsNarrowerThanTheCanvas() async throws {
        _ = NSApplication.shared
        let welcome = NSTextField(labelWithString: "Welcome")
        let host = NSHostingView(
            rootView: ConversationComposerPlacement(progress: 0) {
                ComposerProbe(field: welcome).frame(width: 120, height: 50)
                Color.clear
                Color.clear.frame(height: 100)
            })
        host.sizingOptions = []
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        host.layoutSubtreeIfNeeded()
        #expect(abs(welcome.convert(welcome.bounds, to: host).midX - host.bounds.midX) < 1)
    }

    @Test func composerPositionInterpolatesBetweenCenterAndBottom() {
        let start = ConversationComposerPlacement.composerY(
            height: 700, contentHeight: 200, composerHeight: 100, progress: 0)
        let middle = ConversationComposerPlacement.composerY(
            height: 700, contentHeight: 200, composerHeight: 100, progress: 0.5)
        let end = ConversationComposerPlacement.composerY(
            height: 700, contentHeight: 200, composerHeight: 100, progress: 1)
        #expect(start == 400)
        #expect(middle == 500)
        #expect(end == 600)
    }

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
