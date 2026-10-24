import Foundation
import Testing

@testable import Herm

@MainActor
private final class DirectBotRoutingRPCClient: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    var onResume: (() -> Void)?
    var resumeResult: [String: Any]?
    var submitError: Error?
    private(set) var requests: [(method: String, params: [String: Any])] = []

    func connect() async throws {}

    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        requests.append((method, params))
        switch method {
        case "profiles.list":
            return ["profiles": [["id": "default", "display_name": "Nexus"]]]
        case "session.resume":
            onResume?()
            return resumeResult ?? [
                "session_id": "recipient-chat", "resumed": params["session_id"] ?? "",
                "info": ["profile_name": params["profile"] ?? "default"], "running": false,
            ]
        case "prompt.submit":
            if let submitError { throw submitError }
            return ["status": "streaming"]
        default:
            return [:]
        }
    }

    func close() {}
}

@MainActor
struct DirectBotRoutingTests {
    private var nexus: BotSummary {
        BotSummary(
            id: "default", name: "Nexus", title: nil, description: nil, model: nil,
            isActive: true, chat: nil, avatarURL: nil, preview: nil, lastActive: nil,
            isHidden: false, hasAvatar: false, isDefault: true)
    }

    private func pickNexus(in model: DockModel) {
        let controller = ComposerCompletionController()
        model.draft = "@ne"
        controller.configure(
            model: model, botMode: BotModeModel(), text: { model.draft },
            apply: { text, _ in model.draft = text }, onBotSelected: { model.composer.selectBot($0, range: $1) })
        controller.update(for: model.draft, caret: model.draft.utf16.count)
        let items = ComposerCompletion.mentionResult(
            from: ["items": [["text": "@Nexus"]]],
            bots: [ComposerCompletionItem(text: "@default", display: "Nexus", meta: "", group: "", bot: nexus)]
        ).items
        controller.accept(items[0])
        model.draft += "hey"
    }

    private func model(_ rpc: DirectBotRoutingRPCClient) -> DockModel {
        DockModel(
            initialSessionID: "cypher-chat",
            botActivityFileURL: FileManager.default.temporaryDirectory.appendingPathComponent(
                "direct-bot-\(UUID().uuidString).json"),
            rpcClient: rpc)
    }

    private func waitForSubmission(_ rpc: DirectBotRoutingRPCClient) async {
        for _ in 0..<50 where !rpc.requests.contains(where: { $0.method == "prompt.submit" }) {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func pressingEnterOnAFullyTypedPickerRowStillSelectsTheBot() async {
        let rpc = DirectBotRoutingRPCClient()
        let model = model(rpc)
        defer { model.shutdown() }
        let bots = BotModeModel()
        bots.bind(to: rpc, capabilityAvailable: true)
        await bots.refreshNow(force: true)
        bots.searchText = "Cypher"
        #expect(bots.visibleBots.isEmpty)
        let controller = ComposerCompletionController()
        controller.configure(
            model: model, botMode: bots, text: { model.draft }, apply: { text, _ in model.draft = text },
            onBotSelected: { model.composer.selectBot($0, range: $1) })
        model.draft = "@default"
        controller.update(for: model.draft, caret: model.draft.utf16.count)

        #expect(controller.result.items.first?.display == "Nexus")
        #expect(controller.result.items.first?.text == "@default")
        #expect(controller.handleKey(.enter))
        #expect(model.composer.selectedBots.map(\.id) == ["default"])
        #expect(model.draft == "@default ")
        #expect(!rpc.requests.contains { $0.method == "prompt.submit" })
    }

    @Test func pickerAcceptanceMarksOnlyTheTokenAtItsCaret() {
        let rpc = DirectBotRoutingRPCClient()
        let model = model(rpc)
        defer { model.shutdown() }
        let controller = ComposerCompletionController()
        controller.configure(
            model: model, botMode: BotModeModel(), text: { model.draft }, apply: { text, _ in model.draft = text },
            onBotSelected: { model.composer.selectBot($0, range: $1) })
        model.draft = "@default and @ne hey"
        controller.update(for: model.draft, caret: 16)
        controller.accept(ComposerCompletionItem(text: "@default", display: "Nexus", meta: "", group: "", bot: nexus))

        #expect(model.draft == "@default and @default hey")
        #expect(model.composer.botMentions.map(\.range) == [NSRange(location: 13, length: 8)])
    }

    @Test func pickerSelectionRoutesToItsHermesProfileAfterTheRosterChanges() async throws {
        let rpc = DirectBotRoutingRPCClient()
        let model = model(rpc)
        defer { model.shutdown() }
        model.sessionProfileID = "cypher"
        pickNexus(in: model)

        model.submitComposerInput(bots: [])
        await waitForSubmission(rpc)

        let submit = try #require(rpc.requests.first { $0.method == "prompt.submit" })
        #expect(submit.params["session_id"] as? String == "recipient-chat")
        #expect(submit.params["profile"] as? String == "default")
        #expect(submit.params["text"] as? String == "hey")
        #expect(model.messages.first?.text == "@default hey")
        #expect(model.messages.first?.botMentions.map(\.bot.id) == ["default"])
        #expect(model.composer.selectedBots.isEmpty)
        model.receiveGatewayEvent(
            "message.complete", params: ["session_id": "recipient-chat", "payload": ["text": "Hello from Nexus."]])
        #expect(model.messages.last?.botProfileID == "default")
        #expect(model.messages.last?.botDisplayName == "Nexus")
    }

    @Test func typedHandleRoutesWithoutPickerMetadata() async throws {
        let rpc = DirectBotRoutingRPCClient()
        let model = model(rpc)
        defer { model.shutdown() }
        model.draft = "@default hey"

        model.submitComposerInput(bots: [nexus])
        await waitForSubmission(rpc)

        #expect(model.messages.first?.text == "@default hey")
        #expect(model.messages.first?.botMentions.isEmpty == true)
        #expect(rpc.requests.last?.params["profile"] as? String == "default")
    }

    @Test func pickedBotOwnsDeliveryWhenTheRequestAlsoTypesAnotherHandle() async throws {
        let rpc = DirectBotRoutingRPCClient()
        let model = model(rpc)
        defer { model.shutdown() }
        pickNexus(in: model)
        model.draft += ", ask @cypher about the audit"
        let cypher = BotSummary(
            id: "cypher", name: "Cypher", title: nil, description: nil, model: nil, isActive: false, chat: nil,
            avatarURL: nil, preview: nil, lastActive: nil, isHidden: false, hasAvatar: false, isDefault: false)

        model.submitComposerInput(bots: [nexus, cypher])
        await waitForSubmission(rpc)

        #expect(rpc.requests.last?.params["profile"] as? String == "default")
        #expect(model.messages.first?.botMentions.map(\.bot.id) == ["default"])
    }

    @Test func queuedPickerSelectionKeepsItsRecipientAndDoesNotConsumeTheNextDraft() async throws {
        let rpc = DirectBotRoutingRPCClient()
        let model = model(rpc)
        defer { model.shutdown() }
        model.status = .working
        model.isSending = true
        model.draft = "Earlier message"
        model.queueDraft()
        pickNexus(in: model)
        model.submitComposerInput(bots: [nexus])
        #expect(model.currentSessionQueuedPrompts.last?.botRecipient?.id == "default")
        #expect(model.currentSessionQueuedPrompts.last?.botMentions.map(\.bot.id) == ["default"])
        #expect(!model.canSteerQueuedPrompt(try #require(model.currentSessionQueuedPrompts.last)))
        model.draft = "Later message"
        model.submitComposerInput(bots: [])
        model.draft = "Unsent draft"
        for count in 1...2 {
            model.receiveGatewayEvent(
                "message.complete", params: ["session_id": "cypher-chat", "payload": ["text": "Done"]])
            for _ in 0..<50 where rpc.requests.filter({ $0.method == "prompt.submit" }).count < count {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        let submits = rpc.requests.filter { $0.method == "prompt.submit" }
        #expect(submits.count == 2)
        #expect(submits.last?.params["session_id"] as? String == "recipient-chat")
        #expect(submits.last?.params["profile"] as? String == "default")
        #expect(model.currentSessionQueuedPrompts.map(\.text) == ["Later message"])
        #expect(model.draft == "Unsent draft")
        #expect(model.messages.last?.botMentions.map(\.bot.id) == ["default"])

        model.receiveGatewayEvent(
            "message.complete", params: ["session_id": "recipient-chat", "payload": ["text": "Hello"]])
        for _ in 0..<50 where rpc.requests.filter({ $0.method == "prompt.submit" }).count < 3 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(rpc.requests.last { $0.method == "prompt.submit" }?.params["session_id"] as? String == "cypher-chat")
        #expect(model.draft == "Unsent draft")
    }

    @Test func unsupportedPickerPayloadKeepsTheDraftInsteadOfAskingTheCurrentBot() {
        let rpc = DirectBotRoutingRPCClient()
        let model = model(rpc)
        defer { model.shutdown() }
        pickNexus(in: model)
        model.pendingPDFURL = URL(fileURLWithPath: "/tmp/mention-document.pdf")

        model.submitComposerInput(bots: [nexus])

        #expect(rpc.requests.isEmpty)
        #expect(model.draft == "@default hey")
        #expect(model.composer.selectedBots.map(\.id) == ["default"])
        #expect(model.pendingAttachmentError?.contains("text only") == true)
    }

    @Test(arguments: ["@default start working on RO2 using /cpipe", "hey @default start working on RO2 using /cpipe"])
    func leadingAndEmbeddedMentionsSubmitToTheNamedBot(text: String) async throws {
        let rpc = DirectBotRoutingRPCClient()
        let model = model(rpc)
        defer { model.shutdown() }
        model.sessionProfileID = "cypher"
        model.draft = text
        let nexus = BotSummary(
            id: "default", name: "Nexus", title: nil, description: nil, model: nil,
            isActive: true, chat: nil, avatarURL: nil, preview: nil, lastActive: nil,
            isHidden: false, hasAvatar: false, isDefault: true)

        model.submitComposerInput(bots: [nexus])
        await waitForSubmission(rpc)

        let resume = try #require(rpc.requests.first(where: { $0.method == "session.resume" }))
        #expect(resume.params["profile"] as? String == "default")
        #expect(resume.params["session_id"] as? String == "Bot Chat")
        let submit = try #require(rpc.requests.first(where: { $0.method == "prompt.submit" }))
        #expect(submit.params["profile"] as? String == "default")
        #expect(submit.params["session_id"] as? String == "recipient-chat")
        #expect((submit.params["text"] as? String)?.contains("start working on RO2 using /cpipe") == true)
        #expect(!rpc.requests.contains(where: { $0.method == "bot_relay.deliver" }))
        #expect(model.sessionID == "cypher-chat")
        #expect(model.sessionProfileID == "cypher")

        model.receiveGatewayEvent(
            "message.complete", params: ["session_id": "recipient-chat", "payload": ["text": "I’ll handle RO2."]])
        #expect(model.messages.last?.text == "I’ll handle RO2.")
        #expect(model.messages.last?.botProfileID == "default")
        #expect(model.messages.last?.botDisplayName == "Nexus")
        #expect(model.botActivityBySessionID["cypher-chat"]?.first?.state == .completed)
    }

    @Test func explicitBotChatIsValidatedBeforeOneSubmission() async throws {
        let rpc = DirectBotRoutingRPCClient()
        let model = model(rpc)
        defer { model.shutdown() }

        model.sendDirectBotRequest(
            profileID: "sentry", displayName: "Sentry", text: "audit", chatSessionID: "sentry-chat")
        await waitForSubmission(rpc)

        #expect(rpc.requests.map(\.method) == ["session.resume", "prompt.submit"])
        #expect(rpc.requests.first?.params["session_id"] as? String == "sentry-chat")
        #expect(rpc.requests.last?.params["profile"] as? String == "sentry")
        #expect(model.botActivityBySessionID["cypher-chat"]?.first?.botChatSessionID == "recipient-chat")
    }

    @Test func botRequestDuringBusyTurnDoesNotIdleTheCurrentBot() async throws {
        let rpc = DirectBotRoutingRPCClient()
        let model = model(rpc)
        defer { model.shutdown() }
        model.status = .working
        model.isSending = true

        model.sendDirectBotRequest(profileID: "default", displayName: "Nexus", text: "start task 4")
        await waitForSubmission(rpc)
        model.receiveGatewayEvent(
            "message.complete", params: ["session_id": "recipient-chat", "payload": ["text": "Done"]])

        #expect(model.messages.last?.botDisplayName == "Nexus")
        #expect(model.status == .working)
        #expect(model.isSending)
    }

    @Test func unrelatedEventsCannotSupplyTheMentionedBotsReply() async throws {
        let rpc = DirectBotRoutingRPCClient()
        let model = model(rpc)
        defer { model.shutdown() }
        model.sendDirectBotRequest(profileID: "sentry", displayName: "Sentry", text: "audit")
        await waitForSubmission(rpc)

        model.receiveGatewayEvent(
            "message.complete", params: ["session_id": "unrelated", "payload": ["text": "Wrong bot"]])
        #expect(model.messages.count == 1)
        #expect(model.botActivityBySessionID["cypher-chat"]?.first?.state == .working)
    }

    @Test func streamedReplyCompletesOnceWithoutCompletionText() async throws {
        let rpc = DirectBotRoutingRPCClient()
        let model = model(rpc)
        defer { model.shutdown() }
        model.sendDirectBotRequest(profileID: "sentry", displayName: "Sentry", text: "audit")
        await waitForSubmission(rpc)

        model.receiveGatewayEvent(
            "message.delta", params: ["session_id": "recipient-chat", "payload": ["text": "Audit "]])
        model.receiveGatewayEvent(
            "message.delta", params: ["session_id": "recipient-chat", "payload": ["delta": "complete."]])
        for _ in 0..<2 {
            model.receiveGatewayEvent(
                "message.complete", params: ["session_id": "recipient-chat", "payload": ["text": ""]])
        }
        #expect(model.messages.map(\.text) == ["@Sentry audit", "Audit complete."])
        #expect(model.botActivityBySessionID["cypher-chat"]?.first?.result == "Audit complete.")
    }

    @Test(arguments: ["wrong-session", "wrong-profile", "busy"])
    func unconfirmedOrBusyDestinationsNeverReceiveTheMessage(reason: String) async throws {
        let rpc = DirectBotRoutingRPCClient()
        rpc.resumeResult = [
            "session_id": "recipient-chat", "resumed": reason == "wrong-session" ? "other" : "Bot Chat",
            "profile": reason == "wrong-profile" ? "cypher" : "default", "running": reason == "busy",
        ]
        let model = model(rpc)
        defer { model.shutdown() }
        model.sendDirectBotRequest(profileID: "default", displayName: "Nexus", text: "start task 4")
        for _ in 0..<50 where model.messages.last?.isError != true {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.messages.last?.isError == true)
        #expect(!rpc.requests.contains(where: { $0.method == "prompt.submit" }))
        #expect(model.botActivityBySessionID["cypher-chat"]?.first?.state == .failed)
    }

    @Test func submissionFailureNeverRetriesOrUsesTheCurrentBot() async throws {
        let rpc = DirectBotRoutingRPCClient()
        rpc.submitError = NSError(domain: "Hermes", code: 408, userInfo: [NSLocalizedDescriptionKey: "connection lost"])
        let model = model(rpc)
        defer { model.shutdown() }
        model.sendDirectBotRequest(profileID: "default", displayName: "Nexus", text: "start task 4")
        for _ in 0..<50 where model.messages.last?.isError != true {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(rpc.requests.map(\.method) == ["session.resume", "prompt.submit"])
        #expect(model.messages.last?.isError == true)
        #expect(model.sessionID == "cypher-chat")
    }

    @Test func recipientFailureIsAttributedToTheMentionedBot() async throws {
        let rpc = DirectBotRoutingRPCClient()
        let model = model(rpc)
        defer { model.shutdown() }
        model.sendDirectBotRequest(profileID: "default", displayName: "Nexus", text: "start task 4")
        await waitForSubmission(rpc)
        model.receiveGatewayEvent(
            "error", params: ["session_id": "recipient-chat", "payload": ["error": "Request failed"]])
        #expect(model.messages.last?.isError == true)
        #expect(model.messages.last?.botDisplayName == "Nexus")
        #expect(model.botActivityBySessionID["cypher-chat"]?.first?.state == .failed)
    }

    @Test func switchingChatsDuringResumePreventsSubmission() async throws {
        let rpc = DirectBotRoutingRPCClient()
        let model = model(rpc)
        defer { model.shutdown() }
        rpc.onResume = { model.newChat() }
        model.sendDirectBotRequest(profileID: "default", displayName: "Nexus", text: "start task 4")
        for _ in 0..<50 where !rpc.requests.contains(where: { $0.method == "session.resume" }) {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(!rpc.requests.contains(where: { $0.method == "prompt.submit" }))
        #expect(model.messages.isEmpty)
        #expect(model.botActivityBySessionID["cypher-chat"]?.first?.state == .canceled)
    }

    @Test func everyBotReceivesTheCurrentSessionContext() {
        let context = [
            ChatMessage(role: .user, text: "Review origin."), ChatMessage(role: .hermes, text: "Repository loaded."),
        ]
        let message = DockModel.botRelayMessage(request: "check security", transcript: context)
        #expect(message.contains("User: Review origin."))
        #expect(message.contains("Assistant: Repository loaded."))
        #expect(message.contains("Respond to this request: check security"))
    }
}
