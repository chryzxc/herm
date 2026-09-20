import SwiftUI
import Testing
@testable import HermesAgentDock

struct WorkspaceActivitySidebarTests {
    @MainActor
    @Test func kanbanBoardScrollContractReachesTrailingCardsAndActions() {
        #expect(WorkspaceActivitySidebar.kanbanScrollAxes.contains(.vertical))
        #expect(WorkspaceActivitySidebar.kanbanScrollAxes.contains(.horizontal))
    }
}