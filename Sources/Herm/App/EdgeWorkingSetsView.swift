import SwiftUI

struct EdgeWorkingSetsView: View {
  @ObservedObject var state: EdgeNotchState
  @ObservedObject var model: DockModel
  @ObservedObject private var preferences = CommandCenterPreferencesStore.shared
  let back: () -> Void
  let openWorkspace: () -> Void
  @State private var name = ""
  @State private var removal: UUID?
  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("Saved working sets").font(.system(size: 12, weight: .semibold))
        Spacer()
        Button("Back", action: back).buttonStyle(.dockHover)
      }.padding(10).frame(height: 40)
      Divider().overlay(Color.dockBorderLight)
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          Text("Save the current destination: \(state.captureRecord().destination.title)").font(
            .system(size: 11)
          ).foregroundStyle(Color.dockSecondaryText)
          HStack {
            DockTextField("Set name", text: $name).textFieldStyle(.dockGlass)
            Button("Save") {
              preferences.saveWorkingSet(name: name, destination: state.captureRecord().destination)
              name = ""
            }.buttonStyle(.dockHover).disabled(
              name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          }
          ForEach(preferences.workingSets) { set in
            VStack(alignment: .leading, spacing: 6) {
              HStack {
                Text(set.name).font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("Add current") {
                  preferences.saveWorkingSet(
                    name: set.name, destination: state.captureRecord().destination, addingTo: set.id
                  )
                }.buttonStyle(.dockHover)
                Button("Remove…") { removal = set.id }.buttonStyle(.dockHover)
              }
              ForEach(Array(set.destinations.enumerated()), id: \.offset) { _, destination in
                let unavailable = state.destinationUnavailable(
                  destination, sessions: model.sessions, profileID: model.profileScopeID)
                Button {
                  state.useSavedDestination(destination)
                } label: {
                  VStack(alignment: .leading, spacing: 3) {
                    Text("\(destination.profileID ?? "Launch profile") · \(destination.title)")
                    if let path = destination.projectPath {
                      Text(path).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                    }
                    if unavailable {
                      Text(
                        "Unavailable in current inventory. Open Herm to refresh or repair this set."
                      ).font(.system(size: 11)).foregroundStyle(Color.dockWarning)
                    }
                  }.frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.dockHover).disabled(unavailable)
                HStack {
                  Button("Replace with current") {
                    preferences.removeDestination(destination.key, from: set.id)
                    preferences.saveWorkingSet(
                      name: set.name, destination: state.captureRecord().destination,
                      addingTo: set.id)
                  }.buttonStyle(.dockHover)
                  Button("Remove reference") {
                    preferences.removeDestination(destination.key, from: set.id)
                  }.buttonStyle(.dockHover)
                }.font(.system(size: 11))
              }
            }
          }
        }.font(.system(size: 12)).padding(10)
      }
      Divider().overlay(Color.dockBorderLight)
      HStack {
        Spacer()
        Button("Open Herm", action: openWorkspace).buttonStyle(.dockHover)
      }.font(.system(size: 12)).padding(10)
    }.foregroundStyle(Color.dockPrimaryText)
      .confirmationDialog(
        "Remove this working set?",
        isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } })
      ) {
        Button("Remove set", role: .destructive) {
          if let removal { preferences.removeWorkingSet(removal) }
          removal = nil
        }
        Button("Cancel", role: .cancel) { removal = nil }
      } message: {
        Text("This removes Herm's grouping only. Hermes sessions and pins remain.")
      }
  }
}
