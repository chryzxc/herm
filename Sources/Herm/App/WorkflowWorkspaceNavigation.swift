import SwiftUI

/// Keep scoped navigation outside the workspace's large presentation expression.
struct WorkflowWorkspaceNavigation: ViewModifier {
    let repositoryRequest: QuickDestination?
    let isRestoringSession: Bool
    let automationJobID: String?
    let automationError: String?
    let openRepository: () -> Void
    let openAutomation: () async -> Void
    let clearAutomationError: () -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: repositoryRequest, initial: true) { _, _ in openRepository() }
            .onChange(of: isRestoringSession) { _, restoring in if !restoring { openRepository() } }
            .onChange(of: automationJobID, initial: true) { _, id in
                if id != nil { Task { await openAutomation() } }
            }
            .alert(
                "Routine profile unavailable",
                isPresented: Binding(
                    get: { automationError != nil },
                    set: { if !$0 { clearAutomationError() } })
            ) {
                Button("OK", role: .cancel, action: clearAutomationError)
            } message: {
                Text(automationError ?? "")
            }
    }
}
