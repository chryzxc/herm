import SwiftUI

@MainActor
final class WorkflowIntegrationModel: ObservableObject {
  let service: HermesWorkflowRPC
  @Published var skills: [WorkflowIntegrationItem] = []
  @Published var servers: [WorkflowIntegrationItem] = []
  @Published var status = "Loading integrations…"
  @Published var busy = false
  @Published var preview: String?
  @Published var oauth: WorkflowOAuthFlow?
  private var removalTasks: [String: Task<Void, Never>] = [:]
  private var removalProcesses: [String: WorkflowSkillRemoval] = [:]
  @Published private(set) var pendingRemovals = Set<String>()
  private var oauthName: String?
  private var oauthTask: Task<Void, Never>?
  @Published var unsupported = Set<String>()
  init(client: HermesRPCClientProtocol, profileID: String?) {
    service = HermesWorkflowRPC(client: client, profileID: profileID)
  }
  func refresh(query: String? = nil) async {
    busy = true
    defer { busy = false }
    do {
      skills = try await service.skills(query: query)
      status = ""
      if query == nil {
        for (id, process) in removalProcesses {
          if let outcome = try? await service.skillRemovalOutcome(process) {
            pendingRemovals.remove(id)
            removalProcesses.removeValue(forKey: id)
            status =
              outcome == 0
              ? "Removal acknowledged. Inventory refreshed."
              : "Hermes refused or failed the removal."
          }
        }
        if !pendingRemovals.isEmpty {
          status =
            "Removal outcomes remain uncertain. Inspect Hermes activity or refresh again before retrying."
        }
      }
    } catch {
      status = "Skills: \(HermesDiagnosticsService.safeSummary(error.localizedDescription))"
    }
    do { servers = try await service.mcpCatalog() } catch {
      status += "\nMCP: \(HermesDiagnosticsService.safeSummary(error.localizedDescription))"
    }
  }
  func perform(
    _ action: String, item: WorkflowIntegrationItem, credentialKey: String = "",
    credential: String = ""
  ) async {
    guard !busy, !unsupported.contains(action) else { return }
    busy = true
    defer { busy = false }
    do {
      switch action {
      case "Inspect":
        preview = try await service.inspectSkill(item.id)
        return
      case "Install skill": try await service.installSkill(item.id)
      case "Enable skill", "Disable skill":
        try await service.toggleSkill(item.id, enabled: action == "Enable skill")
      case "Remove skill":
        guard !pendingRemovals.contains(item.id) else { return }
        let removal = try await service.removeSkill(item.id)
        pendingRemovals.insert(item.id)
        status = "Removal started. Waiting for Hermes' recorded outcome."
        removalProcesses[item.id] = removal
        removalTasks[item.id] = Task { [weak self] in
          guard let self else { return }
          defer { removalTasks.removeValue(forKey: item.id) }
          for _ in 0..<30 {
            do {
              try await Task.sleep(for: .seconds(2))
              if let code = try await service.skillRemovalOutcome(removal) {
                pendingRemovals.remove(item.id)
                removalProcesses.removeValue(forKey: item.id)
                await refresh()
                status =
                  code == 0
                  ? "Removal acknowledged. Inventory refreshed."
                  : "Hermes refused or failed the removal. Review the installed skill before retrying."
                return
              }
            } catch {
              if !Task.isCancelled {
                status = "Removal outcome is uncertain. Refresh installed skills before retrying."
              }
              return
            }
          }
          status = "Removal is still unconfirmed. Refresh installed skills before retrying."
        }
        return
      case "Reload live sessions": try await service.reloadMCP()
      case "Custom server": try await service.addCustomMCP(name: item.id, url: item.detail)
      case "Add server": try await service.addMCP(item.id)
      case "Remove server": try await service.removeMCP(item.id)
      case "Save credential":
        try await service.setMCPCredential(item.id, key: credentialKey, value: credential)
      case "Test":
        status = try await service.testMCP(item.id)
        return
      case "Authorize":
        let flow = try await service.startOAuth(item.id)
        oauth = flow
        oauthName = item.id
        ExternalOpen.open(flow.url)
        oauthTask = Task { [weak self] in
          guard let self else { return }
          for _ in 0..<120 {
            do {
              try await Task.sleep(for: .seconds(2))
              guard !Task.isCancelled else { return }
              let result = try await service.pollOAuth(item.id, flow: flow.id)
              if result != .pending {
                oauth = nil
                oauthName = nil
                await refresh()
                status =
                  result == .approved
                  ? "Authorization confirmed. Test the connection."
                  : "Authorization failed. Try again when ready."
                return
              }
            } catch {
              if !Task.isCancelled {
                status = "Authorization could not be confirmed. Cancel or check the provider."
              }
              return
            }
          }
          await cancelOAuth()
        }
        status = "Waiting for authorization…"
        return
      default: return
      }
      await refresh()
      status =
        "Change acknowledged. New sessions use the updated configuration; an explicit runtime reload may be needed for existing sessions."
    } catch {
      if BotService.isUnsupportedMethod(error) { unsupported.insert(action) }
      status =
        action == "Save credential"
        ? "Credential change could not be confirmed. Review configuration before retrying."
        : HermesDiagnosticsService.safeSummary(error.localizedDescription)
    }
  }
  func cancelActiveReads() {
    removalTasks.values.forEach { $0.cancel() }
    removalTasks = [:]
  }
  func cancelOAuth() async {
    oauthTask?.cancel()
    guard let flow = oauth, let name = oauthName else { return }
    do {
      try await service.cancelOAuth(name, flow: flow.id)
      oauth = nil
      oauthName = nil
      status = "Authorization cancelled."
    } catch {
      status = "Cancellation could not be confirmed. Close the provider authorization page."
    }
  }
}

struct WorkflowIntegrationView: View {
  let destination: IntegrationDestination
  @StateObject private var model: WorkflowIntegrationModel
  @Environment(\.dismiss) private var dismiss
  @State private var query = ""
  @State private var request: (String, WorkflowIntegrationItem)?
  @State private var selectedServer: WorkflowIntegrationItem?
  @State private var customName = ""
  @State private var customURL = ""
  @State private var credentialKey = ""
  @State private var credential = ""
  init(destination: IntegrationDestination, client: HermesRPCClientProtocol) {
    self.destination = destination
    _model = StateObject(
      wrappedValue: WorkflowIntegrationModel(client: client, profileID: destination.profileID))
  }
  var body: some View {
    DockModal(
      title: "Skills & MCP", subtitle: "Profile: \(destination.profileID ?? "Launch profile")",
      width: 520, contentPadding: 0
    ) {
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          HStack {
            DockTextField("Search skill hub", text: $query).textFieldStyle(.dockGlass)
            Button("Search") { Task { await model.refresh(query: query.isEmpty ? nil : query) } }
              .buttonStyle(.dockHover)
            Button("Installed") {
              query = ""
              Task { await model.refresh() }
            }.buttonStyle(.dockHover)
          }.disabled(model.busy)
          Text("Skills").font(.system(size: 12, weight: .semibold))
          ForEach(model.skills) { item in
            VStack(alignment: .leading, spacing: 6) {
              Text(item.id).font(.system(size: 12, weight: .semibold))
              Text(item.detail).font(.system(size: 12)).foregroundStyle(Color.dockSecondaryText)
              HStack {
                action("Inspect", item, confirm: false)
                if item.installed {
                  action(item.enabled ? "Disable skill" : "Enable skill", item)
                  action("Remove skill", item)
                } else {
                  action("Install skill", item)
                }
              }
            }.padding(.vertical, 6)
          }
          if let preview = model.preview {
            Text(preview).font(.system(size: 12)).textSelection(.enabled)
          }
          Divider()
          MemoryCorrectionView(service: model.service)
          Text("MCP catalog & setup").font(.system(size: 12, weight: .semibold))
          ForEach(model.servers) { item in
            VStack(alignment: .leading, spacing: 6) {
              Text(item.id).font(.system(size: 12, weight: .semibold))
              Text(item.detail).font(.system(size: 12)).foregroundStyle(Color.dockSecondaryText)
              HStack {
                if item.installed {
                  action("Test", item, confirm: false)
                  action("Authorize", item)
                  action("Remove server", item)
                  if !item.requiredKeys.isEmpty {
                    Button("Credential…") {
                      selectedServer = item
                      credentialKey = item.requiredKeys.first ?? ""
                      credential = ""
                    }.buttonStyle(.dockHover)
                  }
                } else {
                  action("Add server", item)
                }
              }
            }.padding(.vertical, 6)
          }
          DisclosureGroup("Add an HTTP MCP server") {
            DockTextField("Server name", text: $customName).textFieldStyle(.dockGlass)
            DockTextField("HTTP or HTTPS URL", text: $customURL).textFieldStyle(.dockGlass)
            Button("Add custom server…") {
              request = (
                "Custom server", WorkflowIntegrationItem(id: customName, detail: customURL)
              )
            }.buttonStyle(.dockHover).disabled(
              model.busy || customName.isEmpty || customURL.isEmpty)
          }.font(.system(size: 12))
          Button("Reload live sessions…") {
            request = (
              "Reload live sessions",
              WorkflowIntegrationItem(id: "Live runtime sessions", detail: "")
            )
          }.buttonStyle(.dockHover).disabled(
            model.busy || model.unsupported.contains("Reload live sessions"))
          if let item = selectedServer {
            Text("Credential for \(item.id)").font(.system(size: 12, weight: .semibold))
            Picker("Required key", selection: $credentialKey) {
              ForEach(item.requiredKeys, id: \.self) { Text($0).tag($0) }
            }
            SecureField("Credential", text: $credential).textFieldStyle(.dockGlass)
            Button("Save credential…") { request = ("Save credential", item) }.buttonStyle(
              .dockHover
            ).disabled(credential.isEmpty)
          }
          if model.oauth != nil {
            Button("Cancel authorization") { Task { await model.cancelOAuth() } }.buttonStyle(
              .dockHover)
          }
          Text(model.status).font(.system(size: 12)).foregroundStyle(Color.dockSecondaryText)
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
      }.frame(height: 440)
    } footer: {
      HStack {
        if model.busy { ProgressView().controlSize(.small) }
        Spacer()
        Button("Done") { dismiss() }.buttonStyle(.dockSecondary)
      }
    }
    .task { await model.refresh() }
    .onDisappear {
      credential = ""
      model.cancelActiveReads()
      Task { await model.cancelOAuth() }
    }
    .confirmationDialog(
      "\(request?.0 ?? "Change integration")?",
      isPresented: Binding(get: { request != nil }, set: { if !$0 { request = nil } })
    ) {
      Button(request?.0 ?? "Confirm") {
        guard let (action, item) = request else { return }
        request = nil
        let value = credential
        credential = ""
        Task {
          await model.perform(action, item: item, credentialKey: credentialKey, credential: value)
        }
      }
      Button("Cancel", role: .cancel) {
        request = nil
        credential = ""
      }
    } message: {
      Text(
        "\(request?.0 == "Reload live sessions" ? "Reload affects all live sessions connected to this Hermes runtime. " : "")\(request?.1.id ?? "Integration") in profile \(destination.profileID ?? "Launch profile"). Hermes performs its own installation and authorization checks."
      )
    }
  }
  private func action(_ action: String, _ item: WorkflowIntegrationItem, confirm: Bool = true)
    -> some View
  {
    Button(action) {
      if confirm {
        request = (action, item)
      } else {
        Task { await model.perform(action, item: item) }
      }
    }.buttonStyle(.dockHover).disabled(
      model.busy || model.unsupported.contains(action)
        || (action == "Remove skill" && model.pendingRemovals.contains(item.id))
        || (action == "Authorize" && model.oauth != nil)
    )
    .help(
      model.unsupported.contains(action)
        ? "This installed runtime does not support this operation." : action)
  }
}
