import SwiftUI

struct EdgeQuickActionsView: View {
  @ObservedObject var state: EdgeNotchState
  @ObservedObject var model: DockModel
  let back: () -> Void
  let activate: () -> Void
  @State private var editing: SavedQuickAction?
  @State private var changingDestination: SavedQuickAction?
  @State private var deleting: SavedQuickAction?
  @State private var status: String?

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text(editing == nil ? "Saved quick actions" : "Edit action")
          .font(.system(size: 12, weight: .semibold))
        Spacer()
        Button("Back") { if editing != nil { editing = nil } else { back() } }
          .buttonStyle(.dockHover)
      }.padding(10).frame(height: 40)
      Divider().overlay(Color.dockBorderLight)
      ScrollView {
        VStack(alignment: .leading, spacing: 10) {
          if let editing {
            EdgeQuickActionEditor(
              initial: editing, currentDestination: state.captureRecord().destination,
              activate: activate
            ) { action in
              do {
                try state.workflowContent.save(action)
                state.workflowContent.flush()
                self.editing = nil
                status = nil
              } catch { status = error.localizedDescription }
            }.id(editing.id)
          } else {
            Text("Actions prepare a draft. You review the destination and choose Send.")
              .font(.system(size: 12)).foregroundStyle(Color.dockSecondaryText)
            if state.workflowContent.actions.isEmpty {
              Text("No saved actions").font(.system(size: 12, weight: .semibold))
            }
            ForEach(state.workflowContent.actions) { action in
              VStack(alignment: .leading, spacing: 4) {
                Text(action.title).font(.system(size: 12, weight: .semibold))
                Text(action.instructions).lineLimit(2).foregroundStyle(Color.dockSecondaryText)
                Text(
                  action.destination.map { "\($0.profileID ?? "Launch profile") · \($0.title)" }
                    ?? "Keeps the current recipient"
                ).font(.system(size: 11))
                  .foregroundStyle(Color.dockSecondaryText)
                HStack {
                  Button("Prepare draft") { prepare(action) }.buttonStyle(.dockHover)
                    .disabled(
                      unavailable(action) || state.quickSending || state.quickPreparing > 0
                        || state.quickNeedsReview
                    )
                    .accessibilityLabel("Prepare \(action.title) draft")
                  Spacer()
                  Button("Edit") {
                    activate()
                    editing = action
                  }.buttonStyle(.dockHover)
                    .disabled(!state.workflowContent.canWrite)
                  Button("Remove…") { deleting = action }.buttonStyle(.dockHover)
                    .disabled(!state.workflowContent.canWrite)
                }
                if unavailable(action) {
                  Text("Saved destination unavailable. Edit this action to repair it.")
                    .font(.system(size: 11)).foregroundStyle(Color.dockWarning)
                }
              }
              Divider().overlay(Color.dockBorderLight)
            }
          }
          if let message = status ?? state.workflowContent.error {
            Text(message).foregroundStyle(Color.dockWarning)
          }
        }.font(.system(size: 12)).padding(10)
      }.frame(maxWidth: .infinity, maxHeight: .infinity)
      Divider().overlay(Color.dockBorderLight)
      HStack {
        if editing == nil {
          Button("New action") {
            activate()
            editing = SavedQuickAction(title: "", instructions: "")
          }.buttonStyle(.dockHover).disabled(!state.workflowContent.canWrite)
        }
        Spacer()
        Text("Draft only").foregroundStyle(Color.dockSecondaryText)
      }.font(.system(size: 12)).padding(10).frame(height: 44)
    }.foregroundStyle(Color.dockPrimaryText)
      .confirmationDialog(
        "Use this action's saved destination?",
        isPresented: Binding(
          get: { changingDestination != nil }, set: { if !$0 { changingDestination = nil } })
      ) {
        Button("Save current draft and use destination") {
          if let action = changingDestination {
            _ = state.applyQuickAction(action, confirmDestinationChange: true)
          }
          changingDestination = nil
        }
        Button("Cancel", role: .cancel) { changingDestination = nil }
      } message: {
        Text(
          "\(changingDestination?.destination?.profileID ?? "Launch profile") · \(changingDestination?.destination?.title ?? ""). Your captured material stays in the current saved draft. The new draft contains this action's instructions."
        )
      }
      .confirmationDialog(
        "Remove \(deleting?.title ?? "this action")?",
        isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
      ) {
        Button("Remove action", role: .destructive) {
          if let deleting {
            state.workflowContent.removeAction(deleting.id)
            state.workflowContent.flush()
          }
          deleting = nil
        }
        Button("Cancel", role: .cancel) { deleting = nil }
      }
  }

  private func unavailable(_ action: SavedQuickAction) -> Bool {
    guard let destination = action.destination else { return false }
    return state.destinationUnavailable(
      destination, sessions: model.sessions, profileID: model.profileScopeID)
  }

  private func prepare(_ action: SavedQuickAction) {
    if let destination = action.destination,
      destination.key != state.captureRecord().destination.key
    {
      changingDestination = action
    } else {
      _ = state.applyQuickAction(action)
    }
  }
}

private struct EdgeQuickActionEditor: View {
  @State private var action: SavedQuickAction
  let currentDestination: QuickDestination
  let activate: () -> Void
  let save: (SavedQuickAction) -> Void
  init(
    initial: SavedQuickAction, currentDestination: QuickDestination,
    activate: @escaping () -> Void, save: @escaping (SavedQuickAction) -> Void
  ) {
    _action = State(initialValue: initial)
    self.currentDestination = currentDestination
    self.activate = activate
    self.save = save
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      DockTextField("Action title", text: $action.title).textFieldStyle(.dockGlass)
        .accessibilityLabel("Action title")
      DockTextField("Instructions", text: $action.instructions, axis: .vertical)
        .textFieldStyle(.dockGlass).lineLimit(4...8).accessibilityLabel("Action instructions")
      Toggle(
        "Use a saved destination",
        isOn: Binding(
          get: { action.destination != nil },
          set: {
            action.destination = $0 ? currentDestination : nil
          }))
      if let destination = action.destination {
        Text("\(destination.profileID ?? "Launch profile") · \(destination.title)")
          .foregroundStyle(Color.dockSecondaryText)
        Button("Replace with current destination") { action.destination = currentDestination }
          .buttonStyle(.dockHover)
      }
      Button("Save action") { save(action) }.buttonStyle(.dockHover)
        .disabled(
          action.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || action.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }.simultaneousGesture(TapGesture().onEnded(activate))
  }
}
