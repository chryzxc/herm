import AppKit
import SwiftUI
import Testing

@testable import Herm

@MainActor
struct SettingsConstructionTests {
    @Test func generalSettingsDoesNotLoadRuntimeCatalog() async throws {
        let model = DockModel(rpcClient: SettingsConstructionRPC())
        defer { model.shutdown() }
        let sidebar = WorkspaceActivitySidebar(
            model: model, botMode: BotModeModel(),
            store: WorkspaceStore(fileURL: URL(fileURLWithPath: "/tmp/herm-settings-construction-tests.json")),
            control: ControlCenterModel(capabilities: []), workflow: DeveloperWorkflowModel(),
            initialMode: .core, agentUpdateService: HermesUpdateService()
        )
        let host = NSHostingView(rootView: sidebar.settingsWorkspaceContent)
        host.frame = CGRect(x: 0, y: 0, width: 1000, height: 600)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.runtimeModelOptionsRefreshGeneration == 0)

        let runtimeHost = NSHostingView(rootView: sidebar.runtimeSettingsSection)
        runtimeHost.frame = CGRect(x: 0, y: 0, width: 700, height: 600)
        runtimeHost.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.runtimeModelOptionsRefreshGeneration == 1)
        withExtendedLifetime((host, runtimeHost)) {}
    }

    @Test func settingsDetailBuildsAndLaysOut() {
        let sidebar = WorkspaceActivitySidebar(
            model: DockModel(), botMode: BotModeModel(),
            store: WorkspaceStore(fileURL: URL(fileURLWithPath: "/tmp/herm-settings-construction-tests.json")),
            control: ControlCenterModel(capabilities: []), workflow: DeveloperWorkflowModel(),
            initialMode: .core, agentUpdateService: HermesUpdateService()
        )
        let host = NSHostingView(rootView: sidebar.settingsDetailScroll)
        host.frame = CGRect(x: 0, y: 0, width: 700, height: 600)
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width > 0)
    }
}

@MainActor
private final class SettingsConstructionRPC: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    func connect() async throws {}
    func close() {}
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] { [:] }
}
