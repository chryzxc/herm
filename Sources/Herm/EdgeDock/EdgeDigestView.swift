import SwiftUI

struct EdgeQuietMenu: View {
  @ObservedObject var coordinator: HermInterruptionCoordinator
  let showDigest: () -> Void
  var body: some View {
    Menu {
      if coordinator.quiet {
        Button("End quiet period") { coordinator.end() }
      } else {
        Button("Quiet for 60 minutes") { coordinator.start() }
        Button("Quiet for 30 minutes") { coordinator.start(minutes: 30) }
        Button("Quiet until I end it") { coordinator.start(minutes: nil) }
      }
      if !coordinator.entries.isEmpty || coordinator.overflow > 0 {
        Divider()
        Button("Review digest (\(coordinator.entries.count))", action: showDigest)
      }
    } label: {
      Text(coordinator.quiet ? "Quiet on" : "Quiet").dockFont(.metadata, weight: .medium)
    }
    .menuStyle(.borderlessButton).fixedSize()
    .accessibilityLabel(
      coordinator.quiet ? "Quiet period active. Manage interruptions" : "Start a quiet period")
  }
}

struct EdgeDigestView: View {
  @ObservedObject var coordinator: HermInterruptionCoordinator
  let back: () -> Void
  let open: (HermNotice) -> Void
  let openActivity: () -> Void
  @State private var confirmsClear = false
  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("While quiet").dockFont(.body, weight: .semibold)
        Spacer()
        Button("Back", action: back).buttonStyle(.dockCompact)
      }.padding(10).frame(height: 40)
      Divider().overlay(Color.dockBorderLight)
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 6) {
          if coordinator.entries.isEmpty {
            Text("No activity waiting").dockFont(.body, weight: .semibold)
            Text("Completions and ordinary quota changes will appear here.").dockFont(.body)
              .foregroundStyle(Color.dockSecondaryText)
          }
          ForEach(coordinator.entries.reversed()) { entry in
            Button {
              open(entry)
            } label: {
              VStack(alignment: .leading, spacing: 3) {
                Text(entry.kind.title).dockFont(.body, weight: .semibold)
                Text(
                  entry.unavailable
                    ? (entry.canCheckCompletedSession
                      ? "Check saved reply in its original profile."
                      : "Source unavailable. Reconnect or open Herm.")
                    : "\(entry.profileID ?? "Launch profile") · \(entry.source == .repository ? URL(fileURLWithPath: entry.sourceID).lastPathComponent : entry.sourceID)"
                )
                .dockFont(.metadata).foregroundStyle(Color.dockSecondaryText).lineLimit(2)
              }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }.buttonStyle(.dockHover).disabled(entry.unavailable && !entry.canCheckCompletedSession)
              .accessibilityLabel(
                "\(entry.kind.title). \(entry.unavailable && !entry.canCheckCompletedSession ? "Source unavailable" : "Open source")"
              )
          }
          if coordinator.overflow > 0 {
            Text("\(coordinator.overflow) earlier updates. Open activity to review their sources.")
              .dockFont(.metadata).foregroundStyle(Color.dockSecondaryText)
          }
        }.padding(10)
      }.frame(maxWidth: .infinity, maxHeight: .infinity)
      Divider().overlay(Color.dockBorderLight)
      HStack {
        Button("Clear…") { confirmsClear = true }.buttonStyle(.dockCompact)
        Spacer()
        Button("Open Herm", action: openActivity).buttonStyle(.dockCompact)
      }.dockFont(.body, weight: .medium).padding(10)
    }
    .foregroundStyle(Color.dockPrimaryText)
    .confirmationDialog("Clear this digest?", isPresented: $confirmsClear) {
      Button("Clear digest", role: .destructive) { coordinator.clearDigest() }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "This removes Herm's saved activity references. The sessions, reports and outputs remain in Hermes."
      )
    }
  }
}
