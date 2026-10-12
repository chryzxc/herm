import SwiftUI

/// Keep scoped navigation outside the workspace's large presentation expression.
struct WorkflowWorkspaceNavigation: ViewModifier {
  @ObservedObject var model: DockModel
  @ObservedObject var control: ControlCenterModel
  let openRepository: () -> Void
  let openAutomation: () async -> Void
  func body(content: Content) -> some View {
    content
      .onChange(of: control.requestedRepositoryReview, initial: true) { _, _ in openRepository() }
      .onChange(of: model.isRestoringSession) { _, restoring in if !restoring { openRepository() } }
      .onChange(of: control.requestedAutomationJobID, initial: true) { _, id in
        if id != nil { Task { await openAutomation() } }
      }
      .alert(
        "Routine profile unavailable",
        isPresented: Binding(
          get: { control.automationNavigationError != nil },
          set: { if !$0 { control.automationNavigationError = nil } })
      ) {
        Button("OK", role: .cancel) { control.automationNavigationError = nil }
      } message: {
        Text(control.automationNavigationError ?? "")
      }
  }
}
