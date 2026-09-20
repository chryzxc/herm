import SwiftUI
import Testing
@testable import HermesAgentDock

struct WorkspaceActivitySidebarTests {
    @MainActor
    @Test func kanbanBoardScrollContractReachesTrailingCardsAndActions() {
        #expect(WorkspaceActivitySidebar.kanbanScrollAxes.contains(.vertical))
        #expect(WorkspaceActivitySidebar.kanbanScrollAxes.contains(.horizontal))
    }

    @MainActor
    @Test func kanbanModeBuildsTheProductionSidebarViewPath() {
        let sidebar = WorkspaceActivitySidebar(
            model: DockModel(),
            botMode: BotModeModel(),
            store: WorkspaceStore(fileURL: URL(fileURLWithPath: "/tmp/hermes-agent-dock-kanban-tests.json")),
            control: ControlCenterModel(),
            workflow: DeveloperWorkflowModel(),
            initialMode: .kanban,
            agentUpdateService: HermesUpdateService()
        )

        let bodyType = String(reflecting: type(of: sidebar.body))
        #expect(bodyType.contains("ScrollView<SwiftUI.VStack"))
        #expect(WorkspaceActivitySidebar.kanbanScrollAxes == [.vertical, .horizontal])
    }
}
