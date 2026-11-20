import Foundation
import Testing

@testable import Herm

@MainActor
struct ComposerCompletionAsyncTests {
    @Test func delayedSuccessKeepsSessionAndProfileScope() async throws {
        for profile in [nil, "target"] as [String?] {
            let fixture = try CompletionAsyncFixture(profile: profile)
            defer { fixture.close() }
            fixture.controller.update(for: "/", caret: 1)
            #expect(fixture.isOpen && fixture.controller.isLoading)
            let params = await fixture.rpc.waitForRequest("/")
            #expect(params["profile"] as? String == profile)
            #expect(params["session_id"] as? String == (profile == nil ? "session-a" : nil))
            fixture.rpc.respond("/", .success(Self.payload("help")))
            await fixture.waitForSettlement()
            #expect(fixture.isOpen)
            #expect(fixture.controller.result.items.map(\.text) == ["help"])
        }
    }

    @Test func emptyAndErrorDismiss() async throws {
        for fails in [false, true] {
            let fixture = try CompletionAsyncFixture()
            defer { fixture.close() }
            fixture.controller.update(for: "/", caret: 1)
            _ = await fixture.rpc.waitForRequest("/")
            let result: Result<[String: Any], Error> = fails ? .failure(CompletionFixtureError.failed) : .success([:])
            fixture.rpc.respond("/", result)
            await fixture.waitForSettlement()
            #expect(!fixture.isOpen && !fixture.controller.isPresented)
            #expect(fixture.controller.result.items.isEmpty)
        }
    }

    @Test func refinementAndEscapeDiscardEarlierReplies() async throws {
        let fixture = try CompletionAsyncFixture()
        defer { fixture.close() }
        fixture.draft = "/"
        fixture.controller.update(for: "/", caret: 1)
        _ = await fixture.rpc.waitForRequest("/")
        let oldTask = try #require(fixture.controller.task)
        fixture.controller.update(for: "/h", caret: 2)
        _ = await fixture.rpc.waitForRequest("/h")
        fixture.rpc.respond("/h", .success(Self.payload("help")))
        await fixture.waitForSettlement()
        fixture.rpc.respond("/", .success(Self.payload("old")))
        await oldTask.value
        #expect(fixture.controller.result.items.map(\.text) == ["help"])
        fixture.controller.close()
        fixture.controller.update(for: "/x", caret: 2)
        _ = await fixture.rpc.waitForRequest("/x")
        let cancelledTask = try #require(fixture.controller.task)
        #expect(fixture.controller.handleKey(.escape))
        fixture.rpc.respond("/x", .success(Self.payload("late")))
        await cancelledTask.value
        #expect(fixture.draft == "/")
        #expect(!fixture.isOpen && fixture.controller.result.items.isEmpty)
    }

    private static func payload(_ text: String) -> [String: Any] {
        ["items": [["text": text, "kind": "command"]]]
    }
}

private enum CompletionFixtureError: Error { case failed }

@MainActor
private final class CompletionAsyncFixture {
    let rpc = CompletionControlledRPC()
    let controller = ComposerCompletionController()
    let model: DockModel
    let defaults: UserDefaults
    let suite: String
    var isOpen = false
    var draft = ""
    private var waiter: CheckedContinuation<Void, Never>?

    init(profile: String? = nil) throws {
        suite = "CompletionAsync-" + UUID().uuidString
        defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        model = DockModel(
            sessionAgentStateFileURL: directory.appendingPathComponent("agents.json"), defaults: defaults,
            initialSessionID: "session-a", botActivityFileURL: directory.appendingPathComponent("bots.json"),
            rpcClient: rpc)
        controller.configure(
            model: model, botMode: BotModeModel(), profileID: profile,
            text: { [unowned self] in self.draft }, apply: { [unowned self] text, _ in self.draft = text },
            onOpenChanged: { [unowned self] value in
                self.isOpen = value
                if !self.controller.isLoading {
                    self.waiter?.resume()
                    self.waiter = nil
                }
            })
    }

    func waitForSettlement() async {
        if !controller.isLoading { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func close() {
        controller.close()
        rpc.close()
        model.shutdown()
        defaults.removePersistentDomain(forName: suite)
    }
}

@MainActor
private final class CompletionControlledRPC: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    private var pending: [String: CheckedContinuation<[String: Any], Error>] = [:]
    private var parameters: [String: [String: Any]] = [:]
    private var waiters: [String: CheckedContinuation<[String: Any], Never>] = [:]

    func connect() async throws {}
    func close() {
        for continuation in pending.values { continuation.resume(throwing: CompletionFixtureError.failed) }
        pending.removeAll()
    }

    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        guard method == HermesFeatureIDs.ID.completeSlash.rawValue, let text = params["text"] as? String else {
            return [:]
        }
        parameters[text] = params
        return try await withCheckedThrowingContinuation { continuation in
            pending[text] = continuation
            // Test-only hand-off on the main actor; the dictionary is never mutated afterwards.
            nonisolated(unsafe) let sent = params
            waiters.removeValue(forKey: text)?.resume(returning: sent)
        }
    }

    func waitForRequest(_ text: String) async -> [String: Any] {
        if let params = parameters[text] { return params }
        return await withCheckedContinuation { waiters[text] = $0 }
    }

    func respond(_ text: String, _ result: Result<[String: Any], Error>) {
        nonisolated(unsafe) let sent = result
        pending.removeValue(forKey: text)?.resume(with: sent)
    }
}
