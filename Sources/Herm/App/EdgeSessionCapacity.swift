import SwiftUI

struct SessionCapacitySnapshot {
  let session: HermesSession
  let runtimeID: String
  let running: Bool
  let options: [HermesModelOption]
  let modelID: String?
  let allowance: Double?
  let resetsAt: String?
  let attribution: String
  let readAt: Date
  var low: Bool { allowance.map { $0 <= 20 } ?? false }

  static func parse(session: HermesSession, runtimeID: String, running: Bool, result: [String: Any])
    throws -> Self
  {
    let options = try DockModel.runtimeModelOptions(from: result)
    let provider = result["provider"] as? String ?? ""
    let model = result["model"] as? String ?? ""
    let row = (result["providers"] as? [[String: Any]])?.first {
      ($0["slug"] as? String) == provider
    }
    let usage = row?["usage"] as? [String: Any] ?? [:]
    let accounts = usage["accounts"] as? [[String: Any]] ?? []
    let account = accounts.count == 1 ? accounts.first : nil
    let valid =
      (account?["id"] as? String)?.isEmpty == false
      && ["ready", "limited"].contains(account?["state"] as? String ?? "")
    let windows = valid ? account?["windows"] as? [[String: Any]] ?? [] : []
    let relevant = windows.filter { ($0["scope"] as? String ?? "account") == "account" }
    let lowest = relevant.compactMap { row -> (Double, String?)? in
      guard let used = (row["used_percent"] as? NSNumber)?.doubleValue, used.isFinite,
        (0...100).contains(used)
      else { return nil }
      return (100 - used, row["resets_at"] as? String)
    }.min { $0.0 < $1.0 }
    return Self(
      session: session, runtimeID: runtimeID, running: running, options: options,
      modelID: model.isEmpty ? nil : HermesModelOption(provider: provider, model: model).id,
      allowance: lowest?.0, resetsAt: lowest?.1,
      attribution: valid
        ? "Reported account: \(account?["label"] as? String ?? account?["id"] as? String ?? "")"
        : "Session account mapping is unavailable. Provider quota remains an aggregate advisory.",
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
            Text(snapshot.attribution)
            if let allowance = snapshot.allowance {
              Text("\(Int(allowance))% allowance remaining").font(
                .system(size: 12, weight: .semibold)
              ).foregroundStyle(snapshot.low ? Color.dockWarning : Color.dockPrimaryText)
              if let resets = snapshot.resetsAt {
                Text("Resets: \(HumanDateFormatting.dateAndTime(resets))")
              }
            }
            Text(
              "Read \(snapshot.readAt.formatted(date: .omitted, time: .shortened)). Hermes returns cached usage; snapshot age is not supplied."
            ).font(.system(size: 11)).foregroundStyle(Color.dockSecondaryText)
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
