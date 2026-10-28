import AppKit
import SwiftUI
import Testing
import Vision

@testable import Herm

@MainActor
struct ForwardToBotPopoverTests {
    @Test(arguments: ["plain", "output", "empty", "message", "send", "skill", "retry"])
    func successfulForwardDismissesPopover(scenario: String) async throws {
        _ = NSApplication.shared
        let suite = "ForwardToBotPopoverTests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let rpc = ForwardPopoverRPC(scenario: scenario)
        let model = DockModel(
            sessionAgentStateFileURL: directory.appendingPathComponent("agents.json"), defaults: defaults,
            botActivityFileURL: directory.appendingPathComponent("bots.json"), rpcClient: rpc)
        defer { model.shutdown() }
        model.status = .idle
        let botMode = BotModeModel()
        let bot = BotSummary(
            id: "forward-fixture", name: "Forward Fixture", title: nil, description: nil, model: nil, isActive: true,
            chat: nil, avatarURL: nil, preview: nil, lastActive: nil, isHidden: false, hasAvatar: false,
            isDefault: false)
        var dismissCount = 0
        let host = NSHostingView(
            rootView: ForwardToBotPopover(
                model: model, botMode: botMode, bot: bot, messageText: "Forwarded fixture message",
                dismiss: { dismissCount += 1 }))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 300),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        func find(_ view: NSView) -> ComposerInputTextView? {
            if let text = view as? ComposerInputTextView { return text }
            return view.subviews.lazy.compactMap(find).first
        }
        let text = try #require(find(host))
        window.makeFirstResponder(text)
        let note = scenario == "plain" || scenario == "retry" ? "Review this" : "/fixture inspect"
        text.insertText(note, replacementRange: NSRange(location: NSNotFound, length: 0))
        await Task.yield()
        host.layoutSubtreeIfNeeded()
        let enter = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "\r",
                charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        text.keyDown(with: enter)
        text.keyDown(with: enter)
        for _ in 0..<100 {
            if rpc.finished { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(rpc.finished, "The forward must complete before checking dismissal")
        await Task.yield()
        if scenario == "retry" {
            #expect(dismissCount == 0, "Failure must leave the popover open")
            #expect(text.string == note, "Failure must preserve the note")
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let image = try #require(bitmap.cgImage)
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            try VNImageRequestHandler(cgImage: image).perform([request])
            let visibleText = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            #expect(
                visibleText.contains { $0.contains("Fixture forward rejected") },
                "Failure must display the error before retry: \(visibleText)")
            rpc.finished = false
            text.keyDown(with: enter)
            for _ in 0..<100 {
                if rpc.finished { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(rpc.finished, "The retry must complete before checking dismissal")
            await Task.yield()
        }
        #expect(dismissCount == 1, "Successful forwarding must dismiss even when slash.exec returns output")
        #expect(rpc.createdProfiles == Array(repeating: bot.id, count: scenario == "retry" ? 2 : 1))
        if scenario == "plain" || scenario == "retry" {
            let expectedText = GenerativeUIIntegration.preparePrompt(
                "Review this\n\nForwarded message:\nForwarded fixture message")
            let expected = Array(repeating: expectedText, count: scenario == "retry" ? 2 : 1)
            #expect(rpc.submittedTexts == expected)
        }
    }
}

@MainActor
private final class ForwardPopoverRPC: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    var finished = false
    private(set) var createdProfiles: [String] = []
    private(set) var submittedTexts: [String] = []
    private let scenario: String

    init(scenario: String) { self.scenario = scenario }

    func connect() async throws {}
    func close() {}

    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        switch method {
        case "session.create":
            createdProfiles.append(params["profile"] as? String ?? "")
            return ["session_id": "forward-created-fixture"]
        case "slash.exec":
            switch scenario {
            case "send", "skill":
                return ["type": scenario, "message": "Fixture prompt"]
            case "empty":
                finished = true
                return ["type": "output", "output": ""]
            case "message":
                finished = true
                return ["message": "Fixture command completed"]
            default:
                finished = true
                return ["type": "output", "output": "Fixture command completed"]
            }
        case "prompt.submit":
            submittedTexts.append(params["text"] as? String ?? "")
            finished = true
            if scenario == "retry", submittedTexts.count == 1 {
                let details = [NSLocalizedDescriptionKey: "Fixture forward rejected"]
                throw NSError(domain: "ForwardPopoverFixture", code: 1, userInfo: details)
            }
            return [:]
        default:
            return [:]
        }
    }
}
