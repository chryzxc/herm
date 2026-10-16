import SwiftUI

@MainActor
final class WorkflowIntegrationModel: ObservableObject {
  @Published private(set) var service: HermesWorkflowRPC
  let client: HermesRPCClientProtocol
  @Published var skills: [WorkflowIntegrationItem] = []
  @Published var servers: [WorkflowIntegrationItem] = []
  @Published var plugins: [WorkflowPlugin] = []
  @Published var connectors: [WorkflowConnector] = []
  @Published var catalog: [WorkflowPluginCatalogEntry] = []
  @Published private(set) var catalogLoading = false
  /// `owner/name` → GitHub stars; empty without a launch GitHub token.
  @Published private(set) var stars: [String: Int] = [:]
  @Published var toolsets: [WorkflowToolset] = []
  @Published var hub: [WorkflowIntegrationItem] = []
  private var connectTask: Task<Void, Never>?
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
    self.client = client
    service = HermesWorkflowRPC(client: client, profileID: profileID)
  }
  /// Capabilities' "Configuring:" picker: drop the old profile's inventory, then reload.
  func useProfile(_ profileID: String?) async {
    guard profileID != service.profileID, !busy else { return }
    cancelActiveReads()
    service = HermesWorkflowRPC(client: client, profileID: profileID)
    (skills, servers, plugins, connectors, toolsets, hub, preview) = ([], [], [], [], [], [], nil)
    await refresh()
  }
  func searchHub(_ query: String) async {
    guard !busy, !query.isEmpty else { return }
    busy = true
    defer { busy = false }
    do { hub = try await service.skills(query: query) } catch {
      status = "Skills Hub: \(HermesDiagnosticsService.safeSummary(error.localizedDescription))"
    }
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
    guard query == nil else { return }
    do { plugins = try await service.plugins() } catch {
      status += "\nPlugins: \(HermesDiagnosticsService.safeSummary(error.localizedDescription))"
    }
    do { connectors = try await service.connectors() } catch {
      connectors = []
      status += "\nConnectors: \(HermesDiagnosticsService.safeSummary(error.localizedDescription))"
    }
    do { toolsets = try await service.toolsets() } catch {
      toolsets = []
      status += "\nTools: \(HermesDiagnosticsService.safeSummary(error.localizedDescription))"
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
      case "Enable plugin", "Disable plugin":
        let restart = try await service.togglePlugin(item.id, enabled: action == "Enable plugin")
        await refresh()
        status =
          restart
          ? "Change saved. Restart the Hermes gateway to apply it."
          : "Change acknowledged. New sessions use the updated plugin set."
        return
      case "Enable toolset", "Disable toolset":
        try await service.setToolset(item.id, enabled: action == "Enable toolset")
        await refresh()
        status = "\(item.detail) \(action == "Enable toolset" ? "enabled" : "disabled"). Changes apply to new sessions."
        return
      case "Remove plugin": try await service.removePlugin(item.detail)
      case "Install plugin":
        try await service.installPlugin(catalogName: item.id)
        catalog = (try? await service.pluginCatalog()) ?? catalog
      case "Enable connector", "Disable connector":
        try await service.setConnectorAllowed(item.id, enabled: action == "Enable connector")
      case "Rename account": try await service.renameConnectorAccount(item.id, alias: item.detail)
      case "Disconnect": try await service.removeConnectorAccount(item.id)
      case "Connect", "Reconnect":
        let started = try await service.connectConnector(item.id, reconnect: action == "Reconnect")
        status = "Waiting for authorization…"
        connectTask?.cancel()
        connectTask = Task { [weak self] in
          guard let self else { return }
          var operation = started
          var opened = false
          // ponytail: 5-minute poll ceiling; Hermes' own deadline settles the operation sooner.
          for _ in 0..<150 {
            if !opened, let url = operation.url {
              ExternalOpen.open(url)
              opened = true
            }
            if operation.settled { break }
            do {
              try await Task.sleep(for: .seconds(2))
              operation = try await service.connectorOperation(operation.id)
            } catch {
              if !Task.isCancelled {
                status = "Authorization could not be confirmed. Refresh before retrying."
              }
              return
            }
          }
          await refresh()
          status =
            operation.connected
            ? "\(item.detail) connected."
            : operation.settled
              ? "Authorization did not complete. Try again when ready."
              : "Authorization is still pending. Refresh to check."
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
  func loadCatalog() async {
    guard catalog.isEmpty, !catalogLoading else { return }
    catalogLoading = true
    defer { catalogLoading = false }
    do { catalog = try await service.pluginCatalog() } catch {
      status = "Plugin catalog: \(HermesDiagnosticsService.safeSummary(error.localizedDescription))"
      return
    }
    // ponytail: in-memory only, refetched per page open; persist with a TTL if GitHub rate limits bite.
    if stars.isEmpty { stars = await HermesWorkflowRPC.githubStars(catalog.compactMap(\.githubSlug)) }
  }
  /// Plain fields go through `plugins.manage settings`; secrets through Hermes' env store.
  func saveSettings(_ plugin: WorkflowPlugin, drafts: [String: String]) async {
    guard !busy else { return }
    busy = true
    defer { busy = false }
    do {
      let values = HermesWorkflowRPC.pluginSettingValues(plugin.settings, drafts: drafts)
      if !values.isEmpty { try await service.savePluginSettings(plugin.id, values: values) }
      for setting in plugin.settings where setting.kind == "secret" {
        guard let env = setting.env, let secret = drafts[setting.id], !secret.isEmpty else { continue }
        try await service.setPluginSecret(env: env, value: secret)
      }
      await refresh()
      status = "\(plugin.name) settings saved. Restart the Hermes gateway if the plugin reads them at startup."
    } catch {
      status = HermesDiagnosticsService.safeSummary(error.localizedDescription)
    }
  }
  func cancelActiveReads() {
    removalTasks.values.forEach { $0.cancel() }
    removalTasks = [:]
    connectTask?.cancel()
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
  /// Mirrors Hermes Desktop's Capabilities tabs, plus MCP servers which Desktop keeps elsewhere.
  enum Section: String, CaseIterable, Identifiable {
    case skills = "Skills", tools = "Tools", connectors = "Connectors", plugins = "Plugins", mcp = "MCP"
    var id: String { rawValue }
  }
  /// One master-list row on the Capabilities page.
  private struct Entry: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    var badge: (DockStatusTone, String)?
    /// Non-nil shows a switch driving `toggle`'s enable/disable actions.
    var on: Bool?
    var actions = ("", "")
    /// Discover-only: list section header, GitHub stars, curated-tier mark.
    var group = ""
    var stars: Int?
    var official = false
  }
  let destination: IntegrationDestination
  /// Non-nil renders the full-page Capabilities surface with tabs instead of the modal.
  var pageSection: Binding<Section>?
  @StateObject private var model: WorkflowIntegrationModel
  @Environment(\.dismiss) private var dismiss
  @State private var query = ""
  @State private var request: (String, WorkflowIntegrationItem)?
  @State private var selectedServer: WorkflowIntegrationItem?
  @State private var customName = ""
  @State private var customURL = ""
  @State private var credentialKey = ""
  @State private var credential = ""
  @State private var pluginQuery = ""
  @State private var editingPlugin: String?
  @State private var pluginDrafts: [String: String] = [:]
  @State private var renaming: String?
  @State private var alias = ""
  @State private var selection: String?
  @State private var filter = ""
  @State private var discover = false
  @State private var category = ""
  @State private var byStars = true
  @State private var profiles: [BotSummary] = []
  init(
    destination: IntegrationDestination, client: HermesRPCClientProtocol,
    pageSection: Binding<Section>? = nil
  ) {
    self.destination = destination
    self.pageSection = pageSection
    _model = StateObject(
      wrappedValue: WorkflowIntegrationModel(client: client, profileID: destination.profileID))
  }
  var body: some View {
    Group {
      if let pageSection {
        page(pageSection)
      } else {
        DockModal(
          title: "Integrations", subtitle: "Profile: \(destination.profileID ?? "Launch profile")",
          width: 520, contentPadding: 0
        ) {
          ScrollView { sections }.frame(height: 440)
        } footer: {
          HStack {
            if model.busy { ProgressView().controlSize(.small) }
            Spacer()
            Button("Done") { dismiss() }.buttonStyle(.dockSecondary)
          }
        }
      }
    }
    .task { await model.refresh() }
    .onDisappear {
      credential = ""
      pluginDrafts = [:]
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
        "\(request?.0 == "Reload live sessions" ? "Reload affects all live sessions connected to this Hermes runtime. " : "")\((request?.0.hasSuffix(" plugin") == true || request?.0.hasSuffix(" connector") == true || ["Disconnect", "Reconnect"].contains(request?.0) ? request?.1.detail : request?.1.id) ?? "Integration") in profile \(model.service.profileID ?? "Launch profile"). Hermes performs its own installation and authorization checks."
      )
    }
  }
  private var sections: some View {
    VStack(alignment: .leading, spacing: 18) {
      group("Connectors", count: model.connectors.count) {
        ForEach(model.connectors) { connector in connectorRow(connector) }
      }
      Group {
        group("Plugins", count: model.plugins.count) {
          ForEach(model.plugins) { plugin in pluginRow(plugin) }
        }
        DisclosureGroup("Install from the plugin catalog") {
          VStack(alignment: .leading, spacing: 8) {
            DockTextField("Search plugins", text: $pluginQuery).textFieldStyle(.dockGlass)
            Text("Plugins that only extend Hermes Desktop, or don't run on macOS, are hidden.")
              .font(.system(size: 11)).foregroundStyle(Color.dockMetadataText)
            card {
              ForEach(catalogMatches(pluginQuery, limit: 20)) { entry in
                row(entry.title, entry.detail) {
                  action("Install plugin", WorkflowIntegrationItem(id: entry.id, detail: entry.title))
                }
              }
            }
          }.padding(.top, 8)
        }.font(.system(size: 12)).task { await model.loadCatalog() }
      }
      Group {
        HStack {
          DockTextField("Search skill hub", text: $query).textFieldStyle(.dockGlass)
            .onSubmit { Task { await model.refresh(query: query.isEmpty ? nil : query) } }
          Button("Search") { Task { await model.refresh(query: query.isEmpty ? nil : query) } }
            .buttonStyle(.dockSecondary).controlSize(.small)
          if !query.isEmpty {
            Button("Installed") {
              query = ""
              Task { await model.refresh() }
            }.buttonStyle(.dockHover)
          }
        }.disabled(model.busy)
        group("Skills", count: model.skills.count) {
          ForEach(model.skills) { item in
            row(item.id, item.detail) {
              if item.installed {
                toggle(item.enabled, enable: "Enable skill", disable: "Disable skill", item)
              } else {
                action("Install skill", item)
              }
              moreMenu {
                Button("Inspect") { Task { await model.perform("Inspect", item: item) } }
                if item.installed {
                  Button("Remove skill…", role: .destructive) { request = ("Remove skill", item) }
                    .disabled(model.pendingRemovals.contains(item.id))
                }
              }
            }
          }
        }
        if let preview = model.preview {
          Text(preview).font(.system(size: 12)).textSelection(.enabled)
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.dockSurface))
        }
        MemoryCorrectionView(service: model.service)
        group("MCP servers", count: model.servers.count) {
          ForEach(model.servers) { item in
            row(item.id, item.detail) {
              if item.installed {
                action("Test", item, confirm: false)
                moreMenu {
                  Button("Authorize…") { request = ("Authorize", item) }.disabled(model.oauth != nil)
                  if !item.requiredKeys.isEmpty {
                    Button("Credential…") {
                      selectedServer = item
                      credentialKey = item.requiredKeys.first ?? ""
                      credential = ""
                    }
                  }
                  Divider()
                  Button("Remove server…", role: .destructive) { request = ("Remove server", item) }
                }
              } else {
                action("Add server", item)
              }
            }
          }
        }
        if let item = selectedServer {
          VStack(alignment: .leading, spacing: 8) {
            Text("Credential for \(item.id)").font(.system(size: 12, weight: .semibold))
            Picker("Required key", selection: $credentialKey) {
              ForEach(item.requiredKeys, id: \.self) { Text($0).tag($0) }
            }
            SecureField("Credential", text: $credential).textFieldStyle(.dockGlass)
            Button("Save credential…") { request = ("Save credential", item) }
              .buttonStyle(.dockSecondary).controlSize(.small).disabled(credential.isEmpty)
          }
        }
        DisclosureGroup("Add an HTTP MCP server") {
          VStack(alignment: .leading, spacing: 8) {
            DockTextField("Server name", text: $customName).textFieldStyle(.dockGlass)
            DockTextField("HTTP or HTTPS URL", text: $customURL).textFieldStyle(.dockGlass)
            Button("Add custom server…") {
              request = ("Custom server", WorkflowIntegrationItem(id: customName, detail: customURL))
            }.buttonStyle(.dockSecondary).controlSize(.small).disabled(
              model.busy || customName.isEmpty || customURL.isEmpty)
          }.padding(.top, 8)
        }.font(.system(size: 12))
        HStack {
          Button("Reload live sessions…") {
            request = ("Reload live sessions", WorkflowIntegrationItem(id: "Live runtime sessions", detail: ""))
          }.buttonStyle(.dockSecondary).controlSize(.small).disabled(
            model.busy || model.unsupported.contains("Reload live sessions"))
          if model.oauth != nil {
            Button("Cancel authorization") { Task { await model.cancelOAuth() } }
              .buttonStyle(.dockSecondary).controlSize(.small)
          }
        }
      }
      if !model.status.isEmpty {
        Text(model.status).font(.system(size: 12)).foregroundStyle(Color.dockSecondaryText)
      }
    }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
  }
  // MARK: Capabilities page
  // One list per kind with an Installed / Discover scope, a themed inspector beside it.
  // Built from Dock tokens (dockListRow, dockCard, dockSwitch, DockTabBar) so every skin restyles it.

  private func page(_ tab: Binding<Section>) -> some View {
    let section = tab.wrappedValue
    let canDiscover = [.skills, .plugins, .mcp].contains(section)
    let list = visibleEntries(section, discovering: canDiscover && discover)
    let current = list.first { $0.id == selection } ?? list.first
    return VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 10) {
        DockTabBar(options: Section.allCases, selection: tab) { "\($0.rawValue)  \(entries($0).count)" }
        Spacer(minLength: 8)
        if model.busy { ProgressView().controlSize(.small) }
        DockMenu {
          DockMenuSection("Configure profile") {
            profileOption("Launch profile", nil)
            ForEach(profiles) { bot in profileOption(bot.name, bot.id) }
          }
        } label: {
          HStack(spacing: 6) {
            DockIcon(.user, size: 12, color: .dockSecondaryText)
            Text(profileName(model.service.profileID)).font(.system(size: 12, weight: .medium))
              .foregroundStyle(Color.dockPrimaryText)
            DockIcon(.caretDown, size: 9, color: .dockMetadataText)
          }.padding(.horizontal, 10).frame(height: 30)
            .background(DockThemeShape(cornerRadius: DockLayout.controlRadius).dockInputFill())
        }.buttonStyle(.dockHover).disabled(model.busy).help("Which Hermes profile these changes apply to")
        Button { Task { await model.refresh() } } label: {
          DockIcon(.arrowClockwise, size: 13, color: .dockSecondaryText).frame(width: 28, height: 28)
        }.buttonStyle(.dockHover).disabled(model.busy).help("Refresh")
      }.padding(.horizontal, 20).padding(.vertical, 10)
      Color.dockBorderLight.frame(height: DockLayout.hairline)
      HStack(spacing: 0) {
        VStack(alignment: .leading, spacing: 8) {
          if canDiscover {
            DockTabBar(options: [false, true], selection: $discover) { $0 ? "Discover" : "Installed" }
          }
          DockTextField(
            discover && section == .skills ? "Search the Skills Hub, press Return" : "Filter \(section.rawValue.lowercased())",
            text: $filter
          ).textFieldStyle(.dockGlass)
            .onSubmit { if discover && section == .skills { Task { await model.searchHub(filter) } } }
          if discover && section == .plugins && !model.catalog.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
              DockTabBar(options: [""] + catalogCategories, selection: $category) {
                $0.isEmpty ? "All" : $0.capitalized
              }
            }
          }
          HStack {
            Text(summary(section, list: list)).font(.system(size: 11)).foregroundStyle(Color.dockMetadataText)
            Spacer(minLength: 6)
            if discover && section == .plugins && !model.stars.isEmpty {
              DockSegmentedPicker(selection: $byStars, options: [(true, "Stars"), (false, "A–Z")])
                .controlSize(.small)
            }
          }
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
              ForEach(grouped(list), id: \.0) { name, rows in
                if !name.isEmpty {
                  DockSectionLabel(title: name.uppercased(), count: rows.count)
                    .padding(.top, 10).padding(.bottom, 4).padding(.horizontal, 10)
                }
                ForEach(rows) { entry in listRow(entry, selected: entry.id == current?.id) }
              }
            }
            if list.isEmpty || (discover && section == .plugins && model.catalogLoading) {
              emptyList(section, loading: model.busy || (discover && section == .plugins && model.catalogLoading))
            }
            if section == .mcp && discover { customServerCard.padding(.top, 12) }
          }
        }.padding(14).frame(width: 330)
        Color.dockBorderLight.frame(width: DockLayout.hairline)
        ScrollView {
          VStack(alignment: .leading, spacing: 14) {
            if let current { inspector(section, current) }
            let status = statusLines(section)
            if !status.isEmpty {
              DockCallout(tone: .info, icon: .info, title: "Hermes", message: status) { EmptyView() }
            }
          }.padding(20).frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: section == .skills && !discover ? current?.id : nil) {
          model.preview = nil
          guard section == .skills, !discover, let current else { return }
          await model.perform("Inspect", item: WorkflowIntegrationItem(id: current.id, detail: current.subtitle))
        }
      }
    }
    .onChange(of: tab.wrappedValue) {
      selection = nil
      filter = ""
      discover = false
      category = ""
    }
    .onChange(of: discover) { selection = nil }
    .onChange(of: category) { selection = nil }
    .task(id: discover && section == .plugins) { if discover && section == .plugins { await model.loadCatalog() } }
    .task { profiles = await BotService(client: model.client).list().bots }
  }
  private func profileOption(_ title: String, _ id: String?) -> some View {
    Button { Task { await model.useProfile(id) } } label: {
      HStack {
        Text(title)
        if model.service.profileID == id { DockIcon(.check) }
      }
    }
  }
  private func profileName(_ id: String?) -> String {
    guard let id else { return "Launch profile" }
    return profiles.first { $0.id == id }?.name ?? id
  }
  private func summary(_ section: Section, list: [Entry]) -> String {
    if discover && section == .plugins && model.catalogLoading { return "Fetching the catalog from Hermes…" }
    if discover && section == .skills && model.hub.isEmpty { return "Search to find skills to install." }
    if discover && section == .plugins && model.stars.isEmpty && !model.catalog.isEmpty {
      return "\(list.count) available · set GH_TOKEN to rank by stars"
    }
    if discover { return "\(list.count) available" }
    let switches = list.compactMap(\.on)
    let attention = list.filter { $0.badge?.0 == .attention }.count
    var parts = ["\(list.count) \(list.count == 1 ? "item" : "items")"]
    if !switches.isEmpty { parts.append("\(switches.filter { $0 }.count) on") }
    if attention > 0 { parts.append("\(attention) need attention") }
    return parts.joined(separator: " · ")
  }
  @ViewBuilder
  private func emptyList(_ section: Section, loading: Bool) -> some View {
    if loading {
      DockLoadingState(
        title: discover && section == .plugins ? "Loading plugin catalog…" : "Loading \(section.rawValue.lowercased())…",
        minHeight: 160)
    } else {
      Text(filter.isEmpty ? "Nothing here yet." : "No matches for “\(filter)”.").font(.system(size: 12))
        .foregroundStyle(Color.dockMetadataText).frame(maxWidth: .infinity).padding(.top, 24)
    }
  }
  /// Installed rows for a tab; Discover swaps in hub, catalog, or not-yet-added MCP servers.
  private func visibleEntries(_ section: Section, discovering: Bool) -> [Entry] {
    var rows: [Entry]
    if discovering {
      switch section {
      case .skills:
        let installed = Set(model.skills.map(\.id))
        rows = model.hub.filter { !installed.contains($0.id) }.map {
          Entry(id: $0.id, title: $0.id, subtitle: $0.detail)
        }
        return unique(rows)
      case .plugins:
        let rows = catalogMatches(filter).filter { category.isEmpty || $0.category == category }.map {
          Entry(
            id: $0.id, title: $0.title, subtitle: $0.detail, group: category.isEmpty ? $0.category : "",
            stars: $0.githubSlug.flatMap { model.stars[$0] }, official: $0.official)
        }
        // Category sections, each ranked by stars (or A–Z); official entries break star ties.
        return unique(rows.sorted {
          if $0.group != $1.group { return $0.group < $1.group }
          if byStars, ($0.stars ?? -1) != ($1.stars ?? -1) { return ($0.stars ?? -1) > ($1.stars ?? -1) }
          if $0.official != $1.official { return $0.official }
          return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        })
      default:
        rows = model.servers.filter { !$0.installed }.map { Entry(id: $0.id, title: $0.id, subtitle: $0.detail) }
      }
    } else {
      rows = entries(section).filter { section != .mcp || $0.badge != nil }
    }
    return unique(rows.filter {
      filter.isEmpty || "\($0.title) \($0.subtitle)".localizedCaseInsensitiveContains(filter)
    })
  }
  /// Consecutive runs of one `group`; rows arrive sorted by group, so each name appears once.
  private func grouped(_ rows: [Entry]) -> [(String, [Entry])] {
    var out: [(String, [Entry])] = []
    for row in rows {
      if out.last?.0 == row.group { out[out.count - 1].1.append(row) } else { out.append((row.group, [row])) }
    }
    return out
  }
  private var catalogCategories: [String] { Array(Set(catalogMatches("").map(\.category))).sorted() }
  /// Load errors are tagged by kind ("Connectors: …"); show a tab only its own, plus untagged results.
  private func statusLines(_ section: Section) -> String {
    let tags = ["Skills", "Skills Hub", "Tools", "Connectors", "Plugins", "Plugin catalog", "MCP"]
    let own: Set<String> = switch section {
    case .skills: ["Skills", "Skills Hub"]
    case .plugins: ["Plugins", "Plugin catalog"]
    default: [section.rawValue]
    }
    return model.status.split(separator: "\n").filter { line in
      guard let tag = line.split(separator: ":").first.map(String.init), tags.contains(tag) else { return true }
      return own.contains(tag)
    }.joined(separator: "\n")
  }
  /// ForEach needs unique ids; Hermes can list a name twice (e.g. a skill in two categories).
  private func unique(_ rows: [Entry]) -> [Entry] {
    var seen = Set<String>()
    return rows.filter { seen.insert($0.id).inserted }
  }
  private func entries(_ section: Section) -> [Entry] {
    switch section {
    case .skills:
      return model.skills.map {
        Entry(id: $0.id, title: $0.id, subtitle: $0.detail, on: $0.enabled, actions: ("Enable skill", "Disable skill"))
      }
    case .tools:
      return model.toolsets.map {
        Entry(
          id: $0.id, title: $0.label, subtitle: "\($0.tools.count) tools",
          badge: $0.configured ? nil : (.attention, "Setup"), on: $0.enabled,
          actions: ("Enable toolset", "Disable toolset"))
      }
    case .connectors:
      return model.connectors.map {
        Entry(id: $0.id, title: $0.name, subtitle: $0.detail, badge: connectorBadge($0))
      }
    case .plugins:
      return model.plugins.map {
        Entry(id: $0.id, title: $0.name, subtitle: $0.detail, on: $0.enabled, actions: ("Enable plugin", "Disable plugin"))
      }
    case .mcp:
      return model.servers.filter(\.installed).map {
        Entry(id: $0.id, title: $0.id, subtitle: $0.detail, badge: (.complete, "Added"))
      }
    }
  }
  private func connectorBadge(_ connector: WorkflowConnector) -> (DockStatusTone, String) {
    if !connector.allowed { return (.inactive, "Blocked") }
    if ["failed", "expired", "revoked"].contains(connector.status ?? "") { return (.attention, "Reconnect") }
    return connector.connected ? (.complete, "Connected") : (.queued, "Available")
  }
  private func listRow(_ entry: Entry, selected: Bool) -> some View {
    HStack(spacing: 10) {
      Circle().fill(dotColor(entry)).frame(width: 7, height: 7)
      VStack(alignment: .leading, spacing: 2) {
        Text(entry.title).font(.system(size: 13, weight: .medium)).foregroundStyle(Color.dockPrimaryText)
          .lineLimit(1)
        if !entry.subtitle.isEmpty, entry.subtitle != entry.title {
          Text(entry.subtitle).font(.system(size: 11)).foregroundStyle(Color.dockMetadataText).lineLimit(1)
        }
      }
      Spacer(minLength: 6)
      if entry.official { DockIcon(.sealCheck, size: 12, color: .dockAccent).help("Official Hermes plugin") }
      if let stars = entry.stars { starCount(stars) }
      if let badge = entry.badge, badge.0 == .attention { DockStatusPill(tone: badge.0, text: badge.1) }
      if let on = entry.on {
        toggle(on, enable: entry.actions.0, disable: entry.actions.1,
          WorkflowIntegrationItem(id: entry.id, detail: entry.title))
      }
    }
    .dockListRow(isHighlighted: selected)
    .onTapGesture { selection = entry.id }
  }
  private func starCount(_ stars: Int) -> some View {
    HStack(spacing: 3) {
      DockIcon(.star, size: 10, color: .dockMetadataText)
      Text(stars.formatted(.number.notation(.compactName))).font(.system(size: 11).monospacedDigit())
        .foregroundStyle(Color.dockMetadataText)
    }.help("\(stars) GitHub stars")
  }
  /// Quiet state cue in the theme's own success/warning/neutral colours.
  private func dotColor(_ entry: Entry) -> Color {
    if let badge = entry.badge {
      switch badge.0 {
      case .attention: return .dockWarning
      case .complete: return .dockSuccess
      default: return .dockBorderStrong
      }
    }
    guard let on = entry.on else { return .dockAccent.opacity(0.6) }
    return on ? .dockSuccess : .dockBorderStrong
  }
  private func inspectorHeader(_ entry: Entry, pills: [(DockStatusTone, String)], _ text: String) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(entry.title).font(.system(size: 20, weight: .semibold)).foregroundStyle(Color.dockPrimaryText)
          .textSelection(.enabled)
        ForEach(pills.indices, id: \.self) { DockStatusPill(tone: pills[$0].0, text: pills[$0].1) }
      }
      if !text.isEmpty {
        Text(text).font(.system(size: 13)).foregroundStyle(Color.dockSecondaryText).textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
  private func panel<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.dockSectionText)
      content()
    }.frame(maxWidth: .infinity, alignment: .leading).dockCard()
  }
  private func enabledPill(_ on: Bool) -> (DockStatusTone, String) { on ? (.complete, "On") : (.inactive, "Off") }
  private var appliesNote: some View {
    Label("Changes apply to new sessions.", systemImage: "info.circle").font(.system(size: 11))
      .foregroundStyle(Color.dockMetadataText)
  }
  private func destructive(_ title: String, _ request: (String, WorkflowIntegrationItem)) -> some View {
    Button(title, role: .destructive) { self.request = request }
      .buttonStyle(.dockSecondary).controlSize(.small).foregroundStyle(Color.dockDestructive)
      .disabled(model.busy)
  }
  @ViewBuilder
  private func inspector(_ section: Section, _ entry: Entry) -> some View {
    if discover {
      inspectorHeader(entry, pills: [(.queued, "Not installed")] + (entry.official ? [(.review, "Official")] : []), entry.subtitle)
      switch section {
      case .skills: action("Install skill", WorkflowIntegrationItem(id: entry.id, detail: entry.subtitle))
      case .plugins:
        HStack {
          action("Install plugin", WorkflowIntegrationItem(id: entry.id, detail: entry.title))
          if let plugin = model.catalog.first(where: { $0.id == entry.id }) {
            if let repo = plugin.repo {
              Button { ExternalOpen.open(repo) } label: {
                Label { Text(plugin.githubSlug == nil ? "Source" : "GitHub") } icon: { DockIcon(.githubLogo, size: 12) }
              }.buttonStyle(.dockHover)
            }
            if let docs = plugin.docs, docs != plugin.repo {
              Button { ExternalOpen.open(docs) } label: {
                Label { Text("Docs") } icon: { DockIcon(.bookOpen, size: 12) }
              }.buttonStyle(.dockHover)
            }
          }
        }
        if let plugin = model.catalog.first(where: { $0.id == entry.id }) { catalogDetails(plugin, stars: entry.stars) }
      default:
        if let server = model.servers.first(where: { $0.id == entry.id }) { action("Add server", server) }
      }
      appliesNote
    } else {
      switch section {
      case .skills:
        if let skill = model.skills.first(where: { $0.id == entry.id }) {
          inspectorHeader(entry, pills: [enabledPill(skill.enabled)], skill.detail)
          HStack {
            action(skill.enabled ? "Disable skill" : "Enable skill", skill, confirm: false)
            destructive("Remove…", ("Remove skill", skill))
              .disabled(model.pendingRemovals.contains(skill.id))
          }
          panel("SKILL.md") {
            if let preview = model.preview {
              Text(preview).font(.system(size: 12, design: .monospaced)).foregroundStyle(Color.dockPrimaryText)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            } else {
              ProgressView().controlSize(.small)
            }
          }
          appliesNote
        }
      case .tools:
        if let toolset = model.toolsets.first(where: { $0.id == entry.id }) {
          inspectorHeader(
            entry, pills: [enabledPill(toolset.enabled)] + (toolset.configured ? [] : [(.attention, "Needs setup")]),
            toolset.detail)
          action(toolset.enabled ? "Disable toolset" : "Enable toolset",
            WorkflowIntegrationItem(id: toolset.id, detail: toolset.label), confirm: false)
          if !toolset.configured {
            DockCallout(tone: .warning, icon: .warning, title: "Needs setup",
              message: "Add this toolset's provider keys in Hermes before enabling it.") { EmptyView() }
          }
          if !toolset.tools.isEmpty {
            panel("\(toolset.tools.count) TOOLS") {
              Text(toolset.tools.joined(separator: "  ·  ")).font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color.dockSecondaryText).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
          appliesNote
        }
      case .connectors:
        if let connector = model.connectors.first(where: { $0.id == entry.id }) {
          inspectorHeader(entry, pills: [connectorBadge(connector)], connector.detail)
          panel(connector.accounts.isEmpty ? "CONNECTION" : "ACCOUNTS") { connectorRow(connector) }
        }
      case .plugins:
        if let plugin = model.plugins.first(where: { $0.id == entry.id }) {
          let item = WorkflowIntegrationItem(id: plugin.id, detail: plugin.name)
          inspectorHeader(entry, pills: [enabledPill(plugin.enabled)], plugin.detail)
          HStack {
            action(plugin.enabled ? "Disable plugin" : "Enable plugin", item, confirm: false)
            if plugin.removable { destructive("Remove…", ("Remove plugin", item)) }
          }
          if plugin.desktopHalf {
            DockCallout(tone: .info, icon: .info, title: "Desktop panel unavailable",
              message: "Its Hermes Desktop panel can't run in Herm; the plugin's agent tools still load.") { EmptyView() }
          }
          if !plugin.settings.isEmpty { panel("SETTINGS") { settingsForm(plugin).padding(-10) } }
        }
      case .mcp:
        if let server = model.servers.first(where: { $0.id == entry.id }) {
          inspectorHeader(entry, pills: [(.complete, "Added")], server.detail)
          HStack {
            action("Test", server, confirm: false)
            action("Authorize", server)
            if !server.requiredKeys.isEmpty {
              Button("Credential…") {
                selectedServer = server
                credentialKey = server.requiredKeys.first ?? ""
                credential = ""
              }.buttonStyle(.dockSecondary).controlSize(.small)
            }
            destructive("Remove…", ("Remove server", server))
          }
          if let item = selectedServer, item.id == server.id {
            panel("CREDENTIAL") {
              Picker("Required key", selection: $credentialKey) {
                ForEach(item.requiredKeys, id: \.self) { Text($0).tag($0) }
              }
              SecureField("Credential", text: $credential).textFieldStyle(.dockGlass)
              Button("Save credential…") { request = ("Save credential", item) }
                .buttonStyle(.dockSecondary).controlSize(.small).disabled(credential.isEmpty)
            }.font(.system(size: 12))
          }
          HStack {
            Button("Reload live sessions…") {
              request = ("Reload live sessions", WorkflowIntegrationItem(id: "Live runtime sessions", detail: ""))
            }.buttonStyle(.dockHover).disabled(model.busy || model.unsupported.contains("Reload live sessions"))
            if model.oauth != nil {
              Button("Cancel authorization") { Task { await model.cancelOAuth() } }.buttonStyle(.dockHover)
            }
          }
        }
      }
    }
  }
  private func catalogDetails(_ plugin: WorkflowPluginCatalogEntry, stars: Int?) -> some View {
    let rows = [
      ("Category", plugin.category.capitalized), ("Tier", plugin.official ? "Official" : "Community"),
      ("Maintainer", plugin.maintainer), ("Version", plugin.version), ("Package", plugin.id),
      ("GitHub stars", stars.map { $0.formatted() } ?? ""),
    ].filter { !$0.1.isEmpty }
    return panel("DETAILS") {
      Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
        ForEach(rows, id: \.0) { label, value in
          GridRow {
            Text(label).foregroundStyle(Color.dockMetadataText)
            Text(value).foregroundStyle(Color.dockPrimaryText).textSelection(.enabled)
          }
        }
      }.font(.system(size: 12))
    }
  }
  private var customServerCard: some View {
    panel("CUSTOM HTTP SERVER") {
      DockTextField("Server name", text: $customName).textFieldStyle(.dockGlass)
      DockTextField("https://…", text: $customURL).textFieldStyle(.dockGlass)
      Button("Add server…") {
        request = ("Custom server", WorkflowIntegrationItem(id: customName, detail: customURL))
      }.buttonStyle(.dockSecondary).controlSize(.small).disabled(
        model.busy || customName.isEmpty || customURL.isEmpty)
    }
  }
  private func connectorRow(_ connector: WorkflowConnector) -> some View {
    let item = WorkflowIntegrationItem(id: connector.id, detail: connector.name)
    let broken = ["failed", "expired", "revoked"].contains(connector.status ?? "")
    return VStack(alignment: .leading, spacing: 0) {
      row(connector.name, connector.detail) {
        if !connector.allowed {
          DockStatusPill(tone: .inactive, text: "Blocked")
        } else if broken {
          DockStatusPill(tone: .attention, text: "Needs reconnect")
          action("Reconnect", item)
        } else if connector.connected {
          DockStatusPill(tone: .complete, text: "Connected")
        } else {
          action("Connect", item, confirm: false)
        }
        moreMenu {
          if connector.allowed {
            Button("Disable connector…") { request = ("Disable connector", item) }
          } else {
            Button("Enable connector…") { request = ("Enable connector", item) }
          }
        }
      }
      ForEach(connector.accounts) { account in
        HStack(spacing: 8) {
          DockIcon(.user, size: 11, color: .dockMetadataText)
          if renaming == account.id {
            DockTextField("account-name", text: $alias).textFieldStyle(.dockGlass)
              .onSubmit { saveAlias(account.id) }
            Button("Save") { saveAlias(account.id) }.buttonStyle(.dockSecondary).controlSize(.small)
              .disabled(model.busy || !HermesWorkflowRPC.validConnectorAlias(alias))
            Button("Cancel") { renaming = nil }.buttonStyle(.dockHover)
          } else {
            Text(account.label).font(.system(size: 12))
            Text(account.status).font(.system(size: 11)).foregroundStyle(Color.dockMetadataText)
            Spacer()
            moreMenu {
              Button("Rename…") {
                renaming = account.id
                alias = ""
              }
              Button("Disconnect…", role: .destructive) {
                request = ("Disconnect", WorkflowIntegrationItem(id: account.id, detail: account.label))
              }
            }
          }
        }.padding(.leading, 12).padding(.bottom, 8)
      }
    }
  }
  private func pluginRow(_ plugin: WorkflowPlugin) -> some View {
    let item = WorkflowIntegrationItem(id: plugin.id, detail: plugin.name)
    return VStack(alignment: .leading, spacing: 0) {
      row(
        plugin.name, plugin.detail,
        note: plugin.desktopHalf ? "Its Hermes Desktop panel isn't available in Herm; agent tools still load." : nil
      ) {
        if !plugin.settings.isEmpty {
          Button(editingPlugin == plugin.id ? "Done" : "Settings") {
            editingPlugin = editingPlugin == plugin.id ? nil : plugin.id
            pluginDrafts = [:]
          }.buttonStyle(.dockSecondary).controlSize(.small)
        }
        toggle(plugin.enabled, enable: "Enable plugin", disable: "Disable plugin", item)
        if plugin.removable {
          moreMenu {
            Button("Remove plugin…", role: .destructive) { request = ("Remove plugin", item) }
          }
        }
      }
      if editingPlugin == plugin.id { settingsForm(plugin) }
    }
  }
  private func saveAlias(_ id: String) {
    guard HermesWorkflowRPC.validConnectorAlias(alias) else { return }
    renaming = nil
    Task { await model.perform("Rename account", item: WorkflowIntegrationItem(id: id, detail: alias)) }
  }
  private func group<Content: View>(_ title: String, count: Int, @ViewBuilder _ content: () -> Content)
    -> some View
  {
    VStack(alignment: .leading, spacing: 8) {
      DockSectionLabel(title: title, count: count)
      if count == 0 {
        Text(model.busy ? "Loading…" : "Nothing here yet.").font(.system(size: 12))
          .foregroundStyle(Color.dockMetadataText)
      } else {
        card(content)
      }
    }
  }
  private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 0, content: content)
      .padding(.horizontal, 12)
      .background(RoundedRectangle(cornerRadius: 10).fill(Color.dockSurface))
      .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.dockBorderLight, lineWidth: 0.5))
  }
  /// One line per item: name (plus a description only when it adds something), controls trailing.
  private func row<Trailing: View>(
    _ title: String, _ detail: String, note: String? = nil, @ViewBuilder trailing: () -> Trailing
  ) -> some View {
    HStack(spacing: 10) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(Color.dockPrimaryText)
          .lineLimit(1)
        if !detail.isEmpty, detail != title {
          Text(detail).font(.system(size: 12)).foregroundStyle(Color.dockSecondaryText).lineLimit(2)
        }
        if let note {
          Text(note).font(.system(size: 11)).foregroundStyle(Color.dockMetadataText)
        }
      }
      Spacer(minLength: 8)
      trailing()
    }
    .padding(.vertical, 9)
    .overlay(alignment: .bottom) { Rectangle().fill(Color.dockBorderLight).frame(height: 0.5) }
  }
  /// Reversible on/off, so it applies directly rather than through the confirmation dialog.
  private func toggle(_ on: Bool, enable: String, disable: String, _ item: WorkflowIntegrationItem)
    -> some View
  {
    Toggle("", isOn: Binding(get: { on }, set: { value in
      Task { await model.perform(value ? enable : disable, item: item) }
    }))
    .toggleStyle(.dockSwitch).labelsHidden()
    .disabled(model.busy || model.unsupported.contains(on ? disable : enable))
    .help(on ? disable : enable)
  }
  private func moreMenu<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    Menu(content: content) { DockIcon(.dotsThree, size: 14, color: .dockSecondaryText) }
      .menuStyle(.button).buttonStyle(DockPressButtonStyle()).menuIndicator(.hidden)
      .frame(width: 26, height: 26).contentShape(Rectangle())
      .disabled(model.busy).help("More actions")
  }
  private func catalogMatches(_ query: String, limit: Int = .max) -> [WorkflowPluginCatalogEntry] {
    let installed = Set(model.plugins.map(\.name))
    let needle = query.lowercased()
    // ponytail: the modal shows the first 20 matches; ~570 entries, so search narrows rather than paging.
    return Array(
      model.catalog.lazy.filter {
        !$0.installed && !installed.contains($0.id)
          && (needle.isEmpty || "\($0.id) \($0.title) \($0.detail)".lowercased().contains(needle))
      }.prefix(limit))
  }
  private func settingsForm(_ plugin: WorkflowPlugin) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(plugin.settings) { setting in
        let draft = Binding(
          get: { pluginDrafts[setting.id] ?? (setting.kind == "secret" ? "" : setting.value) },
          set: { pluginDrafts[setting.id] = $0 })
        VStack(alignment: .leading, spacing: 3) {
          switch setting.kind {
          case "boolean":
            Toggle(setting.label, isOn: Binding(get: { draft.wrappedValue == "true" }, set: { draft.wrappedValue = $0 ? "true" : "false" }))
          case "enum":
            Picker(setting.label, selection: draft) {
              ForEach(setting.choices, id: \.self) { Text($0).tag($0) }
            }
          case "secret":
            Text(setting.label).font(.system(size: 12))
            SecureField(setting.hasValue ? "Saved — leave blank to keep" : "Not set", text: draft)
              .textFieldStyle(.dockGlass)
          default:
            Text(setting.label).font(.system(size: 12))
            DockTextField(setting.label, text: draft).textFieldStyle(.dockGlass)
          }
          if !setting.detail.isEmpty {
            Text(setting.detail).font(.system(size: 11)).foregroundStyle(Color.dockMetadataText)
          }
        }
      }
      Button("Save settings") {
        let drafts = pluginDrafts
        pluginDrafts = [:]
        editingPlugin = nil
        Task { await model.saveSettings(plugin, drafts: drafts) }
      }.buttonStyle(.dockSecondary).controlSize(.small).disabled(model.busy || pluginDrafts.isEmpty)
    }.font(.system(size: 12)).padding(10)
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
    }.buttonStyle(.dockSecondary).controlSize(.small).disabled(
      model.busy || model.unsupported.contains(action)
        || (action == "Remove skill" && model.pendingRemovals.contains(item.id))
        || (action == "Authorize" && model.oauth != nil)
    )
    .help(
      model.unsupported.contains(action)
        ? "This installed runtime does not support this operation." : action)
  }
}
