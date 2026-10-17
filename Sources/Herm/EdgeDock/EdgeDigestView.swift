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
      Text(coordinator.quiet ? "Quiet on" : "Quiet").font(.system(size: 11, weight: .medium))
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
        Text("While quiet").font(.system(size: 12, weight: .semibold))
        Spacer()
        Button("Back", action: back).buttonStyle(.dockHover)
      }.padding(10).frame(height: 40)
      Divider().overlay(Color.dockBorderLight)
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 6) {
          if coordinator.entries.isEmpty {
            Text("No activity waiting").font(.system(size: 12, weight: .semibold))
            Text("Completions and ordinary quota changes will appear here.").font(.system(size: 12))
              .foregroundStyle(Color.dockSecondaryText)
          }
          ForEach(coordinator.entries.reversed()) { entry in
            Button {
              open(entry)
            } label: {
              VStack(alignment: .leading, spacing: 3) {
                Text(entry.kind.title).font(.system(size: 12, weight: .semibold))
                Text(
                  entry.unavailable
                    ? (entry.canCheckCompletedSession
                      ? "Check saved reply in its original profile."
                      : "Source unavailable. Reconnect or open Herm.")
                    : "\(entry.profileID ?? "Launch profile") · \(entry.source == .repository ? URL(fileURLWithPath: entry.sourceID).lastPathComponent : entry.sourceID)"
                )
                .font(.system(size: 11)).foregroundStyle(Color.dockSecondaryText).lineLimit(2)
              }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }.buttonStyle(.dockHover).disabled(entry.unavailable && !entry.canCheckCompletedSession)
              .accessibilityLabel(
                "\(entry.kind.title). \(entry.unavailable && !entry.canCheckCompletedSession ? "Source unavailable" : "Open source")"
              )
          }
          if coordinator.overflow > 0 {
            Text("\(coordinator.overflow) earlier updates. Open activity to review their sources.")
              .font(.system(size: 11)).foregroundStyle(Color.dockSecondaryText)
          }
        }.padding(10)
      }.frame(maxWidth: .infinity, maxHeight: .infinity)
      Divider().overlay(Color.dockBorderLight)
      HStack {
        Button("Clear…") { confirmsClear = true }.buttonStyle(.dockHover)
        Spacer()
        Button("Open Herm", action: openActivity).buttonStyle(.dockHover)
      }.font(.system(size: 12, weight: .medium)).padding(10)
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
