import SwiftUI

struct EdgeSubagentSteering: View {
  let origin: HermesSession
  let service: HermesWorkflowRPC
  let back: () -> Void
  let open: () -> Void
  @State private var agents: [WorkflowSubagent] = []
  @State private var selected = ""
  @State private var text = ""
  @State private var status: String?
  @State private var pending = false
  @State private var queued = Set<String>()
  @State private var revision = 0
  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("Steer a live subagent").font(.system(size: 12, weight: .semibold))
        Spacer()
        Button("Back", action: back).buttonStyle(.dockHover)
      }.padding(10).frame(height: 40)
      Divider().overlay(Color.dockBorderLight)
      ScrollView {
        VStack(alignment: .leading, spacing: 10) {
          Text("\(origin.profileID ?? "Launch profile") · \(origin.displayTitle)").font(
            .system(size: 11)
          ).foregroundStyle(Color.dockSecondaryText)
          ForEach(agents) { agent in
            Button {
              selected = agent.id
            } label: {
              Text("\(selected == agent.id ? "✓ " : "")\(agent.goal)")
            }.buttonStyle(.dockHover).disabled(!agent.accepting)
          }
          if agents.isEmpty { Text("No live subagents are available through this runtime.") }
          DockTextField("Correction for the selected subagent", text: $text, axis: .vertical)
            .textFieldStyle(.dockGlass).lineLimit(2...4)
          Button("Send steering") { Task { await send() } }.buttonStyle(.dockHover)
            .disabled(
              pending || selected.isEmpty || queued.contains(selected)
                || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          if let status { Text(status).foregroundStyle(Color.dockSecondaryText) }
          Text(
            "Queued steering is not confirmed delivery. Review the parent session for delivered or missed steering."
          ).font(.system(size: 11)).foregroundStyle(Color.dockSecondaryText)
          Button("Refresh live agents") { revision += 1 }.buttonStyle(.dockHover).disabled(pending)
        }.font(.system(size: 12)).padding(10).frame(maxWidth: .infinity, alignment: .leading)
      }
      Divider().overlay(Color.dockBorderLight)
      HStack {
        if pending { ProgressView().controlSize(.mini) }
        Spacer()
        Button("Open parent session", action: open).buttonStyle(.dockHover)
      }.font(.system(size: 12)).padding(10)
    }.foregroundStyle(Color.dockPrimaryText).task(id: revision) { await load() }
  }
  private func load() async {
    pending = true
    defer { pending = false }
    do {
      let result = try await service.liveSubagents(origin)
      guard !Task.isCancelled else { return }
      agents = result.1
      if !agents.contains(where: { $0.id == selected }) { selected = "" }
    } catch {
      if !Task.isCancelled {
        status = HermesDiagnosticsService.safeSummary(error.localizedDescription)
      }
    }
  }
  private func send() async {
    guard !pending, !queued.contains(selected) else { return }
    let target = selected
    let correction = text
    pending = true
    defer { pending = false }
    do {
      let current = try await service.liveSubagents(origin)
      guard current.1.contains(where: { $0.id == target && $0.accepting }) else {
        status = "Rejected: that subagent is no longer accepting steering."
        return
      }
      let result = try await service.steer(
        sessionID: current.0, subagentID: target, text: correction)
      if result == .queued {
        queued.insert(target)
        text = ""
        status = "Queued. Delivery remains unconfirmed."
      } else {
        status = "Rejected by Hermes. The correction remains available."
      }
    } catch {
      queued.insert(target)
      status =
        "The steering acknowledgment is uncertain. Check the parent session before submitting another correction."
    }
  }
}
