import AppKit
import SwiftUI
import Testing

@testable import Herm

enum ForwardCaretResume: CaseIterable, Sendable {
    case settledTyping, immediateTyping, immediateLeft, immediateMarkedText
}

@MainActor
struct ForwardComposerCaretTests {
    @Test(arguments: ForwardCaretResume.allCases)
    func realForwardPopoverKeepsCaretThroughCompletionAndTyping(resume: ForwardCaretResume) async throws {
        _ = NSApplication.shared
        let suite = "ForwardComposerCaretTests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let rpc = ForwardCaretRPC()
        let model = DockModel(
            sessionAgentStateFileURL: directory.appendingPathComponent("agents.json"), defaults: defaults,
            botActivityFileURL: directory.appendingPathComponent("bots.json"), rpcClient: rpc)
        defer { model.shutdown() }
        let botMode = BotModeModel()
        let bot = BotSummary(
            id: "caret-fixture", name: "Caret Fixture", title: nil, description: nil, model: nil, isActive: true,
            chat: nil, avatarURL: nil, preview: nil, lastActive: nil, isHidden: false, hasAvatar: false,
            isDefault: false)
        let host = NSHostingView(
            rootView: ForwardToBotPopover(
                model: model, botMode: botMode, bot: bot, messageText: "Forwarded fixture message", dismiss: {}))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 300),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        func find(_ view: NSView) -> NSTextView? {
            if let text = view as? NSTextView { return text }
            return view.subviews.lazy.compactMap(find).first
        }
        let text = try #require(find(host))
        window.makeFirstResponder(text)
        for character in "/cp" {
            text.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
            await Task.yield()
        }
        // Wait for this query, not merely an earlier, cancelled prefix request.
        for _ in 0..<100 {
            if rpc.completedQueries.contains("/cp") { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(rpc.completedQueries.contains("/cp"))
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        try #require(text.string == "/cp")
        try #require(rpc.completionRequests > 0)
        try #require(rpc.profiles.allSatisfy { $0 == bot.id })
        let tab = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "\t",
                charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48))
        text.keyDown(with: tab)
        // A queued native keystroke can arrive before SwiftUI redraws the accepted completion.
        if resume == .immediateLeft {
            let left = try #require(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, characters: "\u{f702}",
                    charactersIgnoringModifiers: "\u{f702}", isARepeat: false, keyCode: 123))
            text.keyDown(with: left)
            text.insertText("r", replacementRange: NSRange(location: NSNotFound, length: 0))
        } else if resume == .immediateMarkedText {
            text.setMarkedText(
                "あ", selectedRange: NSRange(location: 1, length: 0),
                replacementRange: NSRange(location: NSNotFound, length: 0))
        } else if resume == .immediateTyping {
            text.insertText("r", replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        await Task.yield()
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let accepted: String
        switch resume {
        case .settledTyping: accepted = "/cpipe "
        case .immediateTyping: accepted = "/cpipe r"
        case .immediateLeft: accepted = "/cpiper "
        case .immediateMarkedText: accepted = "/cpipe あ"
        }
        try #require(
            text.string == accepted,
            "Native draft=\(text.string.debugDescription), expected=\(accepted.debugDescription), caret=\(text.selectedRange())"
        )
        let caret = resume == .immediateLeft ? 7 : (accepted as NSString).length
        try #require(text.selectedRange() == NSRange(location: caret, length: 0))
        if resume == .immediateMarkedText {
            try #require(text.markedRange() == NSRange(location: 7, length: 1))
            text.insertText("あ", replacementRange: text.markedRange())
            try #require(text.string == accepted)
            return
        }
        if resume == .immediateLeft { return }
        var expected = text.string
        let continuation =
            resume == .immediateTyping
            ? "eview 👩🏽‍💻 e\u{301}\nThen check the result." : "review 👩🏽‍💻 e\u{301}\nThen check the result."
        for character in continuation {
            let insertion = String(character)
            text.insertText(insertion, replacementRange: NSRange(location: NSNotFound, length: 0))
            expected += insertion
            if resume == .settledTyping { try await Task.sleep(for: .milliseconds(5)) }
            host.layoutSubtreeIfNeeded()
            try #require(text.string == expected)
            try #require(text.selectedRange() == NSRange(location: (expected as NSString).length, length: 0))
        }
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        try #require(find(host) === text)
        try #require(text.string == expected)
        try #require(text.selectedRange() == NSRange(location: (expected as NSString).length, length: 0))
        // Selection replacement must not be mistaken for an end-of-draft caret request.
        let replacement = NSRange(location: 7, length: 6)
        text.setSelectedRange(replacement)
        text.insertText("inspect", replacementRange: NSRange(location: NSNotFound, length: 0))
        expected = (expected as NSString).replacingCharacters(in: replacement, with: "inspect")
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        #expect(text.string == expected)
        #expect(text.selectedRange() == NSRange(location: 14, length: 0))
    }

    @Test
    func matchingDraftDiscardsLateCaretBeforeInput() async throws {
        _ = NSApplication.shared
        let pending = ForwardPendingCaret()
        let host = NSHostingView(rootView: ForwardMatchingDraftFixture(pending: pending))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 180),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        func find(_ view: NSView) -> NSTextView? {
            if let text = view as? NSTextView { return text }
            return view.subviews.lazy.compactMap(find).first
        }
        let text = try #require(find(host))
        window.makeFirstResponder(text)
        text.setSelectedRange(NSRange(location: 1, length: 1))
        pending.value = 4
        text.insertText("X", replacementRange: NSRange(location: NSNotFound, length: 0))
        await Task.yield()
        host.layoutSubtreeIfNeeded()
        #expect(text.string == "aXcd")
        #expect(text.selectedRange() == NSRange(location: 2, length: 0))
    }
}

@MainActor
private final class ForwardPendingCaret { var value: Int? }

private struct ForwardMatchingDraftFixture: View {
    let pending: ForwardPendingCaret
    @State private var note = "abcd"

    var body: some View {
        ComposerInputEditor(
            text: $note, isFocused: true, onSubmit: {}, onCompletionKey: { _ in false },
            onFocusChanged: { _ in }, onCaretMoved: { _, _ in },
            takePendingCaret: {
                defer { pending.value = nil }
                return pending.value
            },
            onTextChanged: { _, _ in }, onContentHeightChanged: { _ in }
        )
        .frame(width: 340, height: 100)
    }
}

@MainActor
private final class ForwardCaretRPC: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    private(set) var completionRequests = 0
    private(set) var profiles: [String] = []
    private(set) var completedQueries: [String] = []

    func connect() async throws {}
    func close() {}

    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        guard method == "complete.slash" else { return [:] }
        completionRequests += 1
        profiles.append(params["profile"] as? String ?? "")
        try await Task.sleep(for: .milliseconds(5))
        completedQueries.append(params["text"] as? String ?? "")
        return ["replace_from": 1, "items": [["text": "cpipe", "kind": "skill", "meta": "Fixture skill"]]]
    }
}
