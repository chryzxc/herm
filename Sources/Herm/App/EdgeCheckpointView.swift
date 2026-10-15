import SwiftUI

struct EdgeCheckpointView: View {
  let setID: UUID
  @ObservedObject var state: EdgeNotchState
  @ObservedObject var model: DockModel
  let back: () -> Void
  let activate: () -> Void
  @State private var note = ""
  @State private var destinationKey = ""
  @State private var status: String?
  @State private var confirmsClear = false
  @State private var loaded = false
  private var workingSet: WorkingSet? { state.preferences.workingSets.first { $0.id == setID } }
  private var checkpoint: WorkingSetCheckpoint? {
    state.workflowContent.checkpoints.first { $0.workingSetID == setID }
  }
  init(
    setID: UUID, state: EdgeNotchState, model: DockModel, back: @escaping () -> Void,
    activate: @escaping () -> Void
  ) {
    self.setID = setID
    self.state = state
    self.model = model
    self.back = back
    self.activate = activate
    let saved = state.workflowContent.checkpoints.first { $0.workingSetID == setID }
    _note = State(initialValue: saved?.note ?? "")
    _destinationKey = State(initialValue: saved?.destinationKey ?? "")
    _loaded = State(initialValue: true)
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text(workingSet?.name ?? "Checkpoint unavailable").font(
          .system(size: 12, weight: .semibold))
        Spacer()
        Button("Back", action: back).buttonStyle(.dockHover)
      }.padding(10).frame(maxWidth: .infinity).frame(height: 40)
      Divider().overlay(Color.dockBorderLight)
      ScrollView {
        VStack(alignment: .leading, spacing: 10) {
          if let set = workingSet {
            DockTextField("Where did you leave this work?", text: $note, axis: .vertical)
              .textFieldStyle(.dockGlass).lineLimit(3...7)
              .accessibilityLabel("Working-set checkpoint note")
              .simultaneousGesture(TapGesture().onEnded(activate))
            Picker("Resume destination", selection: $destinationKey) {
              Text("Choose a destination").tag("")
              ForEach(set.destinations, id: \.key) { destination in
                Text("\(destination.profileID ?? "Launch profile") · \(destination.title)")
                  .tag(destination.key)
              }
              if !destinationKey.isEmpty,
                !set.destinations.contains(where: { $0.key == destinationKey })
              {
                Text("Saved reference unavailable").tag(destinationKey)
              }
            }.pickerStyle(.menu).accessibilityLabel("Checkpoint destination")
            if !set.destinations.contains(where: { $0.key == state.captureRecord().destination.key }
            ) {
              Button("Add current destination to this set") {
                let destination = state.captureRecord().destination
                state.preferences.saveWorkingSet(
                  name: set.name, destination: destination, addingTo: setID)
                destinationKey = destination.key
              }.buttonStyle(.dockHover)
            }
            Button("Save checkpoint") { save(captureCurrentDraft: true) }.buttonStyle(.dockHover)
              .help(
                "Save the note and associate the current quick draft when its destination matches."
              )
              .disabled(
                destinationKey.isEmpty || !state.workflowContent.canWrite || state.quickSending
                  || state.quickPreparing > 0 || state.quickNeedsReview)
            if let saved = checkpoint {
              Text("Saved \(saved.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.system(size: 11)).foregroundStyle(Color.dockSecondaryText)
              Text(
                saved.draftID.map { id in
                  state.draftStore.records.contains(where: { $0.id == id })
                    ? "Restores the referenced quick draft."
                    : "Saved draft unavailable. The note remains."
                } ?? "No draft was associated with this checkpoint."
              )
              .font(.system(size: 11)).foregroundStyle(Color.dockSecondaryText)
              Button("Insert note into current quick draft") {
                guard !state.quickSending, !state.quickNeedsReview else { return }
                state.quickDraft += (state.quickDraft.isEmpty ? "" : "\n\n") + saved.note
                state.checkpointSetID = nil
                state.composing = true
                activate()
              }.buttonStyle(.dockHover).disabled(
                state.quickSending || state.quickPreparing > 0 || state.quickNeedsReview
                  || saved.note.isEmpty)
              Button("Clear checkpoint…") { confirmsClear = true }.buttonStyle(.dockHover)
                .disabled(!state.workflowContent.canWrite)
            }
          } else {
            Text("Working set unavailable").font(.system(size: 12, weight: .semibold))
            Text("The checkpoint note remains saved until you clear it.")
              .foregroundStyle(Color.dockSecondaryText)
            if let checkpoint { Text(checkpoint.note).textSelection(.enabled) }
          }
          if let message = status ?? state.workflowContent.error {
            Text(message).foregroundStyle(Color.dockWarning)
          }
        }.font(.system(size: 12)).padding(10)
      }.frame(maxWidth: .infinity, maxHeight: .infinity)
      Divider().overlay(Color.dockBorderLight)
      HStack {
        Text("Restores notch context").foregroundStyle(Color.dockSecondaryText)
        Spacer()
        Button("Restore") {
          if let saved = checkpoint, let set = workingSet, state.restoreCheckpoint(saved, from: set)
          {
            activate()
          }
        }.buttonStyle(.dockHover).disabled(!canRestore)
      }.font(.system(size: 12)).padding(10).frame(height: 44)
    }.foregroundStyle(Color.dockPrimaryText)
      .onChange(of: note) { _, _ in if loaded, !destinationKey.isEmpty { save() } }
      .onChange(of: destinationKey) { _, _ in if loaded, !destinationKey.isEmpty { save() } }
      .confirmationDialog("Clear this working-set checkpoint?", isPresented: $confirmsClear) {
        Button("Clear checkpoint", role: .destructive) {
          state.workflowContent.clearCheckpoint(setID)
          state.workflowContent.flush()
          loaded = false
          note = ""
          destinationKey = ""
          loaded = true
        }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text(
          "This removes the local note and its references. Quick drafts and Hermes sessions remain."
        )
      }
  }

  private var canRestore: Bool {
    guard !state.quickSending, state.quickPreparing == 0, let saved = checkpoint,
      let set = workingSet,
      let destination = set.destinations.first(where: { $0.key == saved.destinationKey })
    else { return false }
    return !state.destinationUnavailable(
      destination, sessions: model.sessions, profileID: model.profileScopeID)
  }

  private func save(captureCurrentDraft: Bool = false) {
    guard
      !captureCurrentDraft
        || (!state.quickSending && state.quickPreparing == 0 && !state.quickNeedsReview)
    else { return }
    guard let set = workingSet, set.destinations.contains(where: { $0.key == destinationKey })
    else {
      status = "Repair the destination reference before saving."
      return
    }
    let current = state.captureRecord()
    let draftID =
      captureCurrentDraft && current.destination.key == destinationKey && !current.isEmpty
      ? current.id : checkpoint?.destinationKey == destinationKey ? checkpoint?.draftID : nil
    if captureCurrentDraft, draftID == current.id {
      state.draftStore.save(current)
      state.draftStore.flush()
    }
    guard !captureCurrentDraft || state.draftStore.error == nil else {
      status = state.draftStore.error
      return
    }
    do {
      try state.workflowContent.save(
        WorkingSetCheckpoint(
          workingSetID: setID,
          note: note, destinationKey: destinationKey, draftID: draftID))
      status = nil
    } catch { status = error.localizedDescription }
  }
}
