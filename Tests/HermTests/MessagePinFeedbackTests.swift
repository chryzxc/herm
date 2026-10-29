import AppKit
import SwiftUI
import Testing

@testable import Herm

@MainActor
struct MessagePinFeedbackTests {
    @Test func failedVerificationRetainsPinsAndRetryClearsError() async throws {
        let rpc = MessagePinRPCClient()
        let model = try await MessagePinTests().loaded(rpc)
        defer { model.shutdown() }
        let message = try #require(model.messages.last)
        await model.toggleMessagePinned(message)
        rpc.failReadAfterWrite = true
        await model.toggleMessagePinned(message)
        #expect(!model.messagePinsSupported)
        #expect(model.isMessagePinned(message))
        #expect(model.messagePinMutationFeedback?.error != nil)
        let error = model.messagePinError
        rpc.supported = true
        rpc.failReadAfterWrite = false
        await model.refreshMessagePins()
        #expect(model.messagePinError == error)
        await model.toggleMessagePinned(message)
        #expect(model.messagePinError == nil)
        #expect(model.messagePinMutationFeedback?.error == nil)
    }

    @Test func completionOpensAndRepeatedFailureReopensPresentation() async throws {
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
        presented = false
        rpc.failWrite = true
        await model.toggleMessagePinned(message)
        try await waitUntil { presented }
        let error = model.messagePinError
        presented = false
        await model.toggleMessagePinned(message)
        try await waitUntil { presented }
        #expect(model.messagePinError == error)
        model.newChat()
        #expect(model.messagePinMutationFeedback == nil)
    }

    @Test(arguments: 0..<8)
    func lateMutationCannotEnterNewSelection(scenario: Int) async throws {
        let verification = scenario & 1 != 0
        let profile = scenario & 2 != 0
        let failure = scenario & 4 != 0
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
        rpc.suspendWrite = !verification
        rpc.suspendVerification = verification
        rpc.failSuspendedResponse = failure
        let pending = Task { await model.toggleMessagePinned(message) }
        try await waitUntil { rpc.suspendedResponse != nil }
        if profile {
            model.setProfileScope("other-profile")
            #expect(model.sessionProfileID == "other-profile")
        } else {
            model.newChat()
        }
        let response = try #require(rpc.suspendedResponse)
        rpc.suspendedResponse = nil
        response.resume()
        await pending.value
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        #expect(model.pinnedMessages.isEmpty)
        #expect(model.messagePinError == nil)
        #expect(model.messagePinMutationFeedback == nil)
        #expect(!presented)
        #expect(!model.isUpdatingMessagePin)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition() {
            guard Date() < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
