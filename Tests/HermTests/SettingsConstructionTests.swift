import AppKit
import SwiftUI
import Testing

@testable import Herm

@MainActor
struct SettingsConstructionTests {
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
