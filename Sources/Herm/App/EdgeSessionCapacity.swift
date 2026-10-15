import SwiftUI

struct SessionCapacitySnapshot {
  let session: HermesSession
  let runtimeID: String
  let running: Bool
  let options: [HermesModelOption]
  let modelID: String?
  let readAt: Date

  static func parse(session: HermesSession, runtimeID: String, running: Bool, result: [String: Any])
    throws -> Self
  {
    let options = try DockModel.runtimeModelOptions(from: result)
    let provider = result["provider"] as? String ?? ""
    let model = result["model"] as? String ?? ""
    return Self(
      session: session, runtimeID: runtimeID, running: running, options: options,
      modelID: model.isEmpty ? nil : HermesModelOption(provider: provider, model: model).id,
      readAt: .now)
  }
}

@MainActor
extension HermesWorkflowRPC {
  func sessionCapacity(_ session: HermesSession) async throws -> SessionCapacitySnapshot {
    let resumed = try await resumeOwned(session)
    let runtime = resumed.0
    let result = try await modelOptions(runtime)
    return try SessionCapacitySnapshot.parse(
      session: session, runtimeID: runtime, running: resumed.1, result: result)
  }
}

struct EdgeSessionCapacity: View {
  let destination: HermesSession
  @ObservedObject var control: ControlCenterModel
  let service: HermesWorkflowRPC
  let back: () -> Void
  var loaded: (SessionCapacitySnapshot) -> Void = { _ in }
  let open: () -> Void
  @State private var snapshot: SessionCapacitySnapshot?
  @State private var error: String?
  @State private var pending = false
  @State private var confirmedModel: HermesModelOption?
  @State private var revision = 0
  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text(destination.displayTitle).font(.system(size: 12, weight: .semibold)).lineLimit(1)
        Spacer()
        Button("Back", action: back).buttonStyle(.dockHover)
      }.padding(10).frame(height: 40)
      Divider().overlay(Color.dockBorderLight)
      ScrollView {
        VStack(alignment: .leading, spacing: 10) {
          if let snapshot {
            let provider = snapshot.modelID?.components(separatedBy: "|").first
            if let reading = control.quotaReading(for: provider) {
              Text("\(reading.snapshot.displayName): \(Int(reading.remaining.rounded()))% provider allowance remaining")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(QuotaWorkspaceView.color(for: reading.window.threshold))
              if let resets = reading.window.resetsAt {
                Text("Resets: \(resets.formatted(date: .abbreviated, time: .shortened))")
              }
              Text("Provider advisory · read \(reading.snapshot.updatedAt.formatted(date: .omitted, time: .shortened))")
                .font(.system(size: 11)).foregroundStyle(Color.dockSecondaryText)
            } else {
              Text("Provider quota unavailable. Open Quota to review connected providers.")
            }
            if snapshot.running {
              Button("Stop this turn") { Task { await act(stop: true) } }.buttonStyle(.dockHover)
                .disabled(pending)
            } else {
              Menu("Choose configured session model…") {
                ForEach(snapshot.options) { option in
                  Button(option.displayName) { confirmedModel = option }
                }
              }.menuStyle(.borderlessButton).buttonStyle(.dockHover).disabled(pending)
            }
            if let id = snapshot.modelID {
              Text("Current: \(id.replacingOccurrences(of: "|", with: " / "))").font(
                .system(size: 11))
            }
          } else if pending {
            ProgressView().controlSize(.small)
          }
          if let error { Text(error).foregroundStyle(Color.dockWarning) }
          Button("Refresh") { revision += 1 }.buttonStyle(.dockHover).disabled(pending)
        }.font(.system(size: 12)).padding(10).frame(maxWidth: .infinity, alignment: .leading)
      }
      Divider().overlay(Color.dockBorderLight)
      HStack {
        Spacer()
        Button("Open session", action: open).buttonStyle(.dockHover)
      }.font(.system(size: 12)).padding(10)
    }.foregroundStyle(Color.dockPrimaryText)
      .task(id: revision) { await load() }
      .confirmationDialog(
        "Change the session model?",
        isPresented: Binding(
          get: { confirmedModel != nil }, set: { if !$0 { confirmedModel = nil } })
      ) {
        Button("Use \(confirmedModel?.displayName ?? "model")") {
          let option = confirmedModel
          confirmedModel = nil
          Task { await act(option: option) }
        }
        Button("Cancel", role: .cancel) { confirmedModel = nil }
      } message: {
        Text(
          "Only \(destination.displayTitle) in \(destination.profileID ?? "Launch profile") changes. Hermes must acknowledge the choice."
        )
      }
  }
  private func load() async {
    control.refreshProviderQuota()
    pending = true
    error = nil
    defer { pending = false }
    do {
      let loaded = try await service.sessionCapacity(destination)
      guard !Task.isCancelled else { return }
      snapshot = loaded
      self.loaded(loaded)
    } catch {
      if !Task.isCancelled {
        self.error = HermesDiagnosticsService.safeSummary(error.localizedDescription)
      }
    }
  }
  private func act(stop: Bool = false, option: HermesModelOption? = nil) async {
    guard !pending else { return }
    pending = true
    error = nil
    do {
      if stop {
        try await service.stopSession(destination)
      } else if let option {
        try await service.setSessionModel(destination, option: option)
      }
      let updated = try await service.sessionCapacity(destination)
      snapshot = updated
      loaded(updated)
    } catch { self.error = HermesDiagnosticsService.safeSummary(error.localizedDescription) }
    pending = false
  }
}
