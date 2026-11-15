import Foundation
import Testing

@testable import Herm

@MainActor
private final class FloatingThinkingRPC: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    var calls: [(String, [String: Any])] = []

    func connect() async throws {}
    func close() {}

    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        calls.append((method, params))
        switch method {
        case "config.get": return ["value": "high"]
        case "session.resume":
            return ["session_id": "runtime", "stored_session_id": "linked", "profile": "default", "running": false]
        case "model.options":
            return [
                "provider": "openai", "model": "gpt-6",
                "providers": [
                    ["slug": "openai", "models": ["gpt-6"], "capabilities": ["gpt-6": ["reasoning": true]]]
                ],
            ]
        default: return [:]
        }
    }

    func fetchHTTP(_ path: String) async throws -> [String: Any] { ["messages": []] }
}

@MainActor
struct FloatingChatThinkingReproductionTests {
    @Test func preparingFloatingChatLoadsDefaultWithoutManualSelection() async throws {
        let suite = "FloatingChatThinkingReproductionTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let rpc = FloatingThinkingRPC()
        let runtime = DockModel(
            sessionAgentStateFileURL: directory.appendingPathComponent("agents.json"), defaults: defaults,
            botActivityFileURL: directory.appendingPathComponent("bots.json"), rpcClient: rpc)
        defer { runtime.shutdown() }
        runtime.defaultReasoningVariant = .high
        let record = try #require(
            PullRequestCenterAPI().parse(
                [
                    "number": 193, "title": "Thinking default", "state": "open",
                    "body": "Use the configured default", "user": ["login": "author"],
                    "head": ["ref": "fix", "sha": "abc"], "base": ["ref": "main", "sha": "def"],
                ], repository: GitHubReferenceParser.repository("owner/repo")!, localPath: ""))
        let chat = PullRequestChatModel(links: defaults)
        defer { chat.shutdown() }
        await chat.prepareConversation(for: record, runtime: runtime)
        let model = try #require(chat.conversation)
        let composer = ChatComposerView(
            model: model, composer: model.composer, speechInput: SpeechInput(), botMode: BotModeModel(), onStop: {})
        #expect(composer.selectedReasoningVariant == .high)
        runtime.defaultReasoningVariant = .medium
        #expect(composer.selectedReasoningVariant == .medium)
        let choices = try #require(
            HermesEffortCatalog(result: [
                "providers": [["slug": "openai", "models": ["gpt-6"], "capabilities": ["gpt-6": ["reasoning": true]]]]
            ]).choices(for: HermesModelOption(provider: "openai", model: "gpt-6").id))
        #expect(choices.contains(.high))
        composer.reasoningVariantSelection.wrappedValue = .high
        runtime.defaultReasoningVariant = .low
        #expect(composer.selectedReasoningVariant == .high)
        #expect(model.sessionID == nil)
        #expect(!rpc.calls.contains { $0.0 == "config.set" || $0.0 == "session.create" })
        chat.shutdown()
        runtime.defaultReasoningVariant = .medium
        #expect(model.defaultReasoningVariant == .low)
    }

    @Test func linkedSessionUsesSessionReasoningInsteadOfRuntimeDefault() async throws {
        let suite = "FloatingChatThinkingReproductionTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let rpc = FloatingThinkingRPC()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let runtime = DockModel(
            sessionAgentStateFileURL: directory.appendingPathComponent("agents.json"), defaults: defaults,
            botActivityFileURL: directory.appendingPathComponent("bots.json"), rpcClient: rpc)
        defer { runtime.shutdown() }
        runtime.defaultReasoningVariant = .low
        let record = try #require(
            PullRequestCenterAPI().parse(
                [
                    "number": 193, "title": "Thinking", "state": "open", "user": ["login": "author"],
                    "head": ["ref": "fix", "sha": "abc"], "base": ["ref": "main", "sha": "def"],
                ],
                repository: GitHubReferenceParser.repository("owner/repo")!, localPath: ""))
        let destination = QuickDestination(
            profileID: "default", sessionID: "linked", runtimeID: "runtime", title: "PR #193", projectPath: nil)
        defaults.set(try JSONEncoder().encode(destination), forKey: "herm.pull-request-chat." + record.id)
        let chat = PullRequestChatModel(links: defaults)
        defer { chat.shutdown() }
        await chat.prepareConversation(for: record, runtime: runtime)
        let model = try #require(chat.conversation)
        #expect(model.sessionID != nil)
        // Session reasoning is loaded through the runtime gateway, not this RPC fake.
        model.sessionReasoningVariant = .high
        let composer = ChatComposerView(
            model: model, composer: model.composer, speechInput: SpeechInput(), botMode: BotModeModel(), onStop: {})
        runtime.defaultReasoningVariant = .medium
        #expect(composer.selectedReasoningVariant == .high)
    }

    @Test func issueChatRouteKeepsRegularComposerDefaultAndManualOverride() async throws {
        let suite = "FloatingChatThinkingReproductionTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let runtime = DockModel(
            sessionAgentStateFileURL: directory.appendingPathComponent("agents.json"), defaults: defaults,
            botActivityFileURL: directory.appendingPathComponent("bots.json"), rpcClient: FloatingThinkingRPC())
        defer { runtime.shutdown() }
        runtime.defaultReasoningVariant = .high
        let issue = GitHubIssueRecord(
            repository: GitHubReferenceParser.repository("owner/" + UUID().uuidString)!, localPath: "", number: 193,
            title: "Thinking", body: "", state: "open", author: "author", assignee: nil, updatedAt: nil, webURL: nil)
        let popover = DockPopover(
            model: runtime, panelPresentation: DockPanelPresentation(), controlCenter: ControlCenterModel(),
            botMode: runtime.botMode)
        popover.openIssueChat(issue)
        for _ in 0..<200 where runtime.draft.isEmpty { await Task.yield() }
        #expect(runtime.draft == IssueContext(issue: issue).prompt)
        let composer = ChatComposerView(
            model: runtime, composer: runtime.composer, speechInput: SpeechInput(), botMode: runtime.botMode,
            onStop: {})
        #expect(composer.selectedReasoningVariant == .high)
        runtime.defaultReasoningVariant = .medium
        #expect(composer.selectedReasoningVariant == .medium)
        composer.reasoningVariantSelection.wrappedValue = .high
        runtime.defaultReasoningVariant = .low
        #expect(composer.selectedReasoningVariant == .high)
    }
}
