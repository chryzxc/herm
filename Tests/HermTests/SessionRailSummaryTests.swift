import Foundation
import Testing

@testable import Herm

@MainActor
private final class SummaryRPC: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    func connect() async throws {}
    func close() {}
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] { [:] }
    func fetchHTTP(_ path: String) async throws -> [String: Any] { [:] }
}

@Suite @MainActor
struct SessionRailSummaryTests {
    private func model() -> DockModel {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = DockModel(
            sessionAgentStateFileURL: root.appendingPathComponent("agents.json"),
            defaults: UserDefaults(suiteName: "rail-summary-\(UUID())")!, initialSessionID: "session",
            botActivityFileURL: root.appendingPathComponent("bots.json"), rpcClient: SummaryRPC())
        model.sessionProfileID = "profile"
        return model
    }

    private func output(_ session: String = "session", profile: String = "profile") -> ArtifactRecord {
        .init(value: "/tmp/report.md", sessionID: session, sessionTitle: "Session", timestamp: .now, profileID: profile)
    }

    @Test func emptySessionOmitsSummarySections() {
        let summary = SessionRailSummary.make(
            model: model(), repositoryPath: nil, repository: .empty, outputs: [], outputsError: nil)
        #expect(summary.isEmpty)
    }

    @Test func scopesPlanOutputsAndWorkspaceToTheSelectedSession() {
        let model = model()
        model.todoPlan = .init(sessionID: "another", items: [.init(content: "Other task", status: "pending")])
        let repository = RepositorySnapshot(
            path: "/tmp/other", branch: "other-branch", changedFiles: 1, latestCommit: "Other commit",
            isGitRepository: true)
        let summary = SessionRailSummary.make(
            model: model, repositoryPath: "/tmp/project", repository: repository,
            outputs: [output(), output("another"), output(profile: "another")], outputsError: nil)
        #expect(summary.plan == nil)
        #expect(summary.outputs.count == 1)
        #expect(summary.workspace?.path == "/tmp/project")
        #expect(summary.workspace?.branch == nil)
        #expect(summary.workspace?.latestCommit == nil)

        model.todoPlan = .init(sessionID: "session", items: [.init(content: "Current task", status: "in_progress")])
        let current = SessionRailSummary.make(
            model: model, repositoryPath: "/tmp/other", repository: repository, outputs: [], outputsError: nil)
        #expect(current.plan?.current?.content == "Current task")
        #expect(current.workspace?.branch == "other-branch")
    }

    @Test func attentionDisappearsWhenRequestsAreResolvedAndPinsUseCanonicalData() {
        let model = model()
        model.approvalTitle = "Run command"
        model.approvalText = "swift test"
        model.clarificationQuestion = "Which target?"
        model.status = .needsClarification
        model.pinnedMessages = [.init(rowID: 4, uid: "pin", role: "assistant", preview: "Decision")]
        func summary() -> SessionRailSummary {
            .make(model: model, repositoryPath: nil, repository: .empty, outputs: [], outputsError: nil)
        }
        #expect(summary().attention.map(\.id) == ["approval", "question"])
        #expect(summary().pins == model.pinnedMessages)
        model.approvalText = nil
        model.status = .idle
        #expect(summary().attention.isEmpty)
    }

    @Test func failedOutputRefreshRetainsPreviousDataAndSwitchingClearsIt() async {
        let outputs = SessionRailOutputsModel()
        let session = HermesSession(
            id: "session", profileID: "profile", title: "Session", preview: "", startedAt: nil, messageCount: 1,
            source: HermesFeatureIDs.sessionSource)
        await outputs.refresh(session: session) {
            .init(sessionID: "session", profileID: "profile", records: [output()], error: nil)
        }
        #expect(outputs.records.count == 1)
        await outputs.refresh(session: session) {
            .init(sessionID: "session", profileID: "profile", records: [], error: "Unavailable")
        }
        #expect(outputs.records.count == 1)
        #expect(outputs.error == "Unavailable")
        let other = HermesSession(
            id: "other", profileID: "profile", title: "Other", preview: "", startedAt: nil, messageCount: 0,
            source: HermesFeatureIDs.sessionSource)
        await outputs.refresh(session: other) {
            .init(sessionID: "other", profileID: "profile", records: [], error: nil)
        }
        #expect(outputs.records.isEmpty && outputs.error == nil && !outputs.isRefreshing)
    }

    @Test func lateOutputResponseCannotReplaceTheNewSessionsData() async {
        let outputs = SessionRailOutputsModel()
        let first = HermesSession(
            id: "session", profileID: "profile", title: "First", preview: "", startedAt: nil, messageCount: 1,
            source: HermesFeatureIDs.sessionSource)
        let next = HermesSession(
            id: "next", profileID: "profile", title: "Next", preview: "", startedAt: nil, messageCount: 1,
            source: HermesFeatureIDs.sessionSource)
        var continuation: CheckedContinuation<ArtifactIndexLoader.SessionResult, Never>?
        let delayed = Task {
            await outputs.refresh(session: first) {
                await withCheckedContinuation { continuation = $0 }
            }
        }
        while continuation == nil { await Task.yield() }
        await outputs.refresh(session: next) {
            .init(sessionID: "next", profileID: "profile", records: [output("next")], error: nil)
        }
        continuation?.resume(
            returning: .init(sessionID: "session", profileID: "profile", records: [output()], error: nil))
        await delayed.value
        #expect(outputs.records.map(\.sessionID) == ["next"])
    }
}
