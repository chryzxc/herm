import Foundation
import Testing

@testable import Herm

@MainActor
@Suite(.serialized)
struct BotDeletionTests {
    @Test func capabilityRequiresDeleteHelpTermsAndSuccessfulExit() async {
        let client = BotDeletionClient()
        let probe = HermesCapabilityService()
        #expect(await probe.probeProfileDeletion(client: client))
        client.help = "usage: hermes profile"
        #expect(await probe.probeProfileDeletion(client: client) == false)
        client.help = "profile_name --yes delete"
        client.helpExitCode = 1
        #expect(await probe.probeProfileDeletion(client: client) == false)
        client.helpExitCode = 0
        client.failsShell = true
        #expect(await probe.probeProfileDeletion(client: client) == false)
    }

    @Test func deletionRefreshesRosterAndClearsDeletedSelection() async throws {
        let client = BotDeletionClient()
        let model = BotModeModel()
        model.bind(to: client, capabilityAvailable: true)
        await model.refreshNow(force: true)
        await model.loadBotDeletionCapability()
        model.selectProfile("worker")
        let bot = try #require(model.botsByID["worker"])
        #expect(model.canDeleteBot(bot))
        #expect(await model.deleteBot(bot))
        #expect(client.deletions == 1)
        #expect(model.botsByID["worker"] == nil)
        #expect(model.selectedProfileID != "worker")
        #expect(model.deletingBotID == nil)
        #expect(model.botDeletionError == nil)
    }

    @Test func deletionProtectsDefaultAndFailsClosedWithoutCapability() async throws {
        let client = BotDeletionClient()
        let model = BotModeModel()
        model.bind(to: client, capabilityAvailable: true)
        await model.refreshNow(force: true)
        let worker = try #require(model.botsByID["worker"])
        #expect(await model.deleteBot(worker) == false)
        await model.loadBotDeletionCapability()
        let defaultBot = try #require(model.botsByID["default"])
        #expect(!model.canDeleteBot(defaultBot))
        #expect(await model.deleteBot(defaultBot) == false)
        model.setCapabilityAvailable(false)
        #expect(!model.canDeleteBot(worker))
        #expect(client.deletions == 0)
    }

    @Test func rejectedDeletionRetainsBotAndReportsFailure() async throws {
        let client = BotDeletionClient()
        client.deleteExitCode = 1
        let model = BotModeModel()
        model.bind(to: client, capabilityAvailable: true)
        await model.refreshNow(force: true)
        await model.loadBotDeletionCapability()
        let bot = try #require(model.botsByID["worker"])
        #expect(await model.deleteBot(bot) == false)
        #expect(model.botsByID["worker"] != nil)
        #expect(model.botDeletionError?.contains("rejected") == true)
        #expect(model.deletingBotID == nil)
    }

    @Test func successfulDeletionWithFailedRefreshMarksRosterStale() async throws {
        let client = BotDeletionClient()
        let model = BotModeModel()
        model.bind(to: client, capabilityAvailable: true)
        await model.refreshNow(force: true)
        await model.loadBotDeletionCapability()
        let bot = try #require(model.botsByID["worker"])
        client.failsRosterAfterDelete = true
        #expect(await model.deleteBot(bot))
        #expect(model.inventory.availability == .stale)
        #expect(!model.canDeleteBot(bot))
    }

    @Test func partialFailureStillReconcilesDeletedProfile() async throws {
        let client = BotDeletionClient()
        client.deleteExitCode = 1
        client.deletesBeforeFailure = true
        let model = BotModeModel()
        model.bind(to: client, capabilityAvailable: true)
        await model.refreshNow(force: true)
        await model.loadBotDeletionCapability()
        let bot = try #require(model.botsByID["worker"])
        #expect(await model.deleteBot(bot) == false)
        #expect(model.botsByID["worker"] == nil)
        #expect(model.botDeletionError != nil)
    }

    @Test func pendingDeletionKeepsBotAndRejectsDuplicateSubmissions() async throws {
        let client = BotDeletionClient()
        client.holdsDeletion = true
        let model = BotModeModel()
        model.bind(to: client, capabilityAvailable: true)
        await model.refreshNow(force: true)
        await model.loadBotDeletionCapability()
        let bot = try #require(model.botsByID["worker"])
        let deletion = Task { await model.deleteBot(bot) }
        while client.deletionContinuation == nil { await Task.yield() }
        #expect(model.deletingBotID == "worker")
        #expect(model.botsByID["worker"] != nil)
        #expect(!model.canDeleteBot(bot))
        #expect(await model.deleteBot(bot) == false)
        #expect(client.deletions == 1)
        client.deletionContinuation?.resume()
        client.deletionContinuation = nil
        #expect(await deletion.value)
    }
}

@MainActor
private final class BotDeletionClient: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    var help = "usage: hermes profile delete [-h] [-y] profile_name --yes"
    var helpExitCode = 0
    var deleteExitCode = 0
    var failsShell = false
    var holdsDeletion = false
    var failsRosterAfterDelete = false
    var deletesBeforeFailure = false
    var deletionContinuation: CheckedContinuation<Void, Never>?
    private(set) var deletions = 0
    private var deleted = false
    func connect() async throws {}
    func close() {}
    func fetchHTTP(_ path: String) async throws -> [String: Any] { [:] }
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        if method == "profiles.list" {
            if deleted && failsRosterAfterDelete { throw URLError(.timedOut) }
            var profiles: [[String: Any]] = [["name": "default", "is_default": true]]
            if !deleted { profiles.append(["name": "worker"]) }
            return ["profiles": profiles]
        }
        guard method == "shell.exec" else { return [:] }
        if failsShell { throw URLError(.timedOut) }
        let command = params["command"] as? String ?? ""
        if command.contains("'--help'") { return ["stdout": help, "code": helpExitCode] }
        deletions += 1
        if holdsDeletion { await withCheckedContinuation { deletionContinuation = $0 } }
        if deleteExitCode == 0 || deletesBeforeFailure { deleted = true }
        return ["stdout": "", "stderr": deleteExitCode == 0 ? "" : "Deletion rejected", "code": deleteExitCode]
    }
}
