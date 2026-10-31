import AppKit
import SwiftUI
import Testing

@testable import Herm

@MainActor
struct MessagePinFeedbackTests {
    @Test func completionOpensPresentation() async throws {
        let rpc = MessagePinRPCClient()
        let model = try await MessagePinTests().loaded(rpc)
        defer { model.shutdown() }
        var presented = false
        let binding = Binding(get: { presented }, set: { presented = $0 })
        let host = NSHostingView(
            rootView: MessagePinsView(model: model, onSelect: { _ in })
                .modifier(MessagePinFeedbackPresentation(model: model, isPresented: binding)))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        defer { window.orderOut(nil) }
        let message = try #require(model.messages.last)
        await model.toggleMessagePinned(message)
        try await waitUntil { presented }
        #expect(model.pinnedMessages.first?.uid == "reply")
        model.newChat()
        #expect(model.messagePinMutationFeedback == nil)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition() {
            guard Date() < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
