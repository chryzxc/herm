import SwiftUI

struct HermesSubagentSettings: View {
    let rpc: HermesControlRPC?
    let profile: String?
    let bots: [BotSummary]
    let avatarImages: [String: Data]
    @State private var selectedProfile: String?

    private struct Owner: Hashable {
        let connection: ObjectIdentifier?
        let profile: String
    }

    var body: some View {
        let scope = selectedProfile ?? profile ?? "default"
        VStack(alignment: .leading, spacing: 20) {
            SettingsPreferenceRow(
                title: "Applies to", detail: "Choose the profile whose subagents you want to configure."
            ) {
                DockMenuPicker(title: scope, selection: Binding(get: { scope }, set: { selectedProfile = $0 })) {
                    DockMenuOption(scope, value: scope)
                    ForEach(bots.filter { $0.id != scope }) { DockMenuOption($0.name, value: $0.id) }
                }
            }
            HermesSubagentPage(
                service: rpc.map { HermesSubagentService(rpc: $0, profile: scope) },
                bots: bots, avatarImages: avatarImages
            )
            .id(Owner(connection: rpc.map(ObjectIdentifier.init), profile: scope))
        }
        .onChange(of: profile) { _, _ in selectedProfile = nil }
        .onChange(of: rpc.map(ObjectIdentifier.init)) { _, _ in selectedProfile = nil }
    }
}

private struct HermesSubagentPage: View {
    @StateObject private var model: HermesSubagentModel
    let bots: [BotSummary]
    let avatarImages: [String: Data]
    @State private var choosingBackend: String?
    @State private var installingPlugin = false
    @State private var enablingPlugin = false
    @State private var editingRoutes = false

    init(service: HermesSubagentService?, bots: [BotSummary], avatarImages: [String: Data]) {
        self.bots = bots
        self.avatarImages = avatarImages
        _model = StateObject(wrappedValue: HermesSubagentModel(service: service))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 12) {
                Text(model.notice).dockFont(.body).foregroundStyle(Color.dockSecondaryText)
                    .lineLimit(3).help(model.notice)
                Spacer(minLength: 0)
                Button(model.busy ? "Refreshing…" : "Refresh") { Task { await model.load() } }
                    .buttonStyle(.dockSecondary).disabled(model.busy)
            }.frame(height: 54, alignment: .top)
            SettingsSection(title: "Routing", subtitle: "How each subagent gets its model", tint: .dockAccent) {
                if let routing = model.routing {
                    routingOptions(routing)
                    if routing.blocked {
                        Text(
                            "The saved routing mode cannot run. Enable its plugin or choose Default to allow new delegations."
                        )
                        .dockFont(.body).foregroundStyle(Color.dockWarning)
                    }
                    if ["model_map", "profile_routes"].contains(routing.configured) {
                        SettingsPreferenceRow(
                            title: "Routes",
                            detail: routing.configured == "model_map"
                                ? "Named models the agent can choose for each task."
                                : "Profiles the agent can delegate to, with their own tools and credentials."
                        ) {
                            Button("Edit routes") { editingRoutes = true }.buttonStyle(.dockSecondary)
                                .disabled(!model.routingAvailable || model.busy)
                        }
                    }
                    if model.routingPlugin != nil {
                        SettingsPreferenceRow(
                            title: "Advanced Delegation", detail: "Adds model routes and profile routes to Hermes."
                        ) {
                            Button("Install plugin") { installingPlugin = true }.buttonStyle(.dockSecondary)
                                .disabled(model.busy || !model.routingAvailable)
                        }
                    } else if model.disabledRoutingPlugin != nil {
                        SettingsPreferenceRow(
                            title: "Advanced Delegation", detail: "Installed but disabled for this profile."
                        ) {
                            Button("Enable plugin") { enablingPlugin = true }.buttonStyle(.dockSecondary)
                                .disabled(model.busy || !model.routingAvailable)
                        }
                    } else if !routing.backends.contains(where: { $0.id == "model_map" && $0.available }) {
                        Text(
                            "Model routes and profile routes require the Advanced Delegation plugin enabled for this profile. Manage installed plugins in Integrations."
                        )
                        .dockFont(.body).foregroundStyle(Color.dockSecondaryText)
                    }
                } else {
                    Text("Routing unavailable. Connect a Hermes backend that supports delegation routing.")
                        .dockFont(.body).foregroundStyle(Color.dockSecondaryText)
                }
            }
            if let defaults = model.defaults {
                HermesSubagentDefaultsEditor(model: model, saved: defaults)
                    .id(defaults)
            } else {
                SettingsSection(title: "Subagent defaults", subtitle: "", tint: .dockAccent) {
                    Text("Subagent defaults unavailable. Refresh to try again.")
                        .dockFont(.body).foregroundStyle(Color.dockSecondaryText)
                }
            }
        }
        .dockButtonSize(.compact)
        .task { await model.load() }
        .confirmationDialog(
            "Change subagent routing?",
            isPresented: Binding(get: { choosingBackend != nil }, set: { if !$0 { choosingBackend = nil } })
        ) {
            if let id = choosingBackend {
                Button("Use \(backendTitle(id))") {
                    choosingBackend = nil
                    Task { await model.perform { try await $0.selectBackend(id) } }
                }
            }
        } message: {
            Text(
                "Changes future delegations for profile “\(model.service?.profile ?? "")”. Running subagents keep their current model and tools."
            )
        }
        .confirmationDialog("Install Advanced Delegation?", isPresented: $installingPlugin) {
            Button("Install and enable plugin") {
                Task {
                    await model.perform { service in
                        try await service.rpc.workflow(profileID: service.profile).installPlugin(
                            catalogName: "advanced-delegation")
                    }
                }
            }
        } message: {
            Text(
                "Installs the official catalog plugin and enables it for profile “\(model.service?.profile ?? "")”. Routing is rechecked after installation; running subagents are unchanged."
            )
        }
        .dockSheet(isPresented: $editingRoutes) {
            if let routing = model.routing {
                HermesSubagentRoutesEditor(model: model, routing: routing, bots: bots, avatarImages: avatarImages)
            }
        }
        .confirmationDialog("Enable Advanced Delegation?", isPresented: $enablingPlugin) {
            if let plugin = model.disabledRoutingPlugin {
                Button("Enable plugin") { Task { await model.enableRoutingPlugin(plugin) } }
            }
        } message: {
            Text(
                "Enables this installed plugin for profile “\(model.service?.profile ?? "")”. Hermes may require a gateway restart before routing is available; Herm will show the result."
            )
        }
    }

    private func backendTitle(_ id: String) -> String {
        switch id {
        case "default": "Default"
        case "model_map": "Model routes"
        case "profile_routes": "Profile routes"
        default: model.routing?.backends.first { $0.id == id }?.label ?? id
        }
    }

    @ViewBuilder private func routingOptions(_ routing: HermesSubagentRouting) -> some View {
        let known = ["default", "model_map", "profile_routes"]
        let choices =
            known + routing.backends.map(\.id).filter { !known.contains($0) }
            + (known.contains(routing.configured) || routing.backends.contains { $0.id == routing.configured }
                ? [] : [routing.configured])
        ForEach(choices, id: \.self) { id in
            let backend = routing.backends.first { $0.id == id }
            let selected = routing.configured == id
            SettingsPreferenceRow(title: backendTitle(id), detail: routingDetail(id, backend: backend)) {
                if selected {
                    DockIconLabel(
                        routing.blocked ? "Unavailable" : "In use", icon: routing.blocked ? .warning : .checkCircle
                    )
                    .dockFont(.body).foregroundStyle(routing.blocked ? Color.dockWarning : Color.dockSecondaryText)
                } else {
                    Button("Use") { choosingBackend = id }.buttonStyle(.dockSecondary)
                        .disabled(backend?.available != true || !model.routingAvailable || model.busy)
                        .accessibilityLabel("Use \(backendTitle(id)) routing")
                }
            }
        }
    }

    private func routingDetail(_ id: String, backend: HermesSubagentBackend?) -> String {
        switch id {
        case "default": "Every subagent uses the model defaults below."
        case "model_map": "The agent chooses from named model routes for each task."
        case "profile_routes": "Subagents run as a profile with its own model, tools, and credentials."
        default: backend?.detail ?? "This saved routing backend is not registered on Hermes."
        }
    }
}

private struct HermesSubagentDefaultsEditor: View {
    @ObservedObject var model: HermesSubagentModel
    let saved: HermesSubagentDefaults
    @State private var draft: HermesSubagentDefaults
    @State private var confirming = false

    init(model: HermesSubagentModel, saved: HermesSubagentDefaults) {
        self.model = model
        self.saved = saved
        _draft = State(initialValue: saved)
    }

    private var routeInactive: Bool { model.routing.map { $0.configured != "default" } ?? false }

    var body: some View {
        SettingsSection(title: "Subagent defaults", subtitle: "", tint: .dockAccent) {
            if routeInactive {
                Text(
                    "The selected routing mode chooses each subagent’s model. Provider and model defaults apply only with Default routing."
                )
                .dockFont(.body).foregroundStyle(Color.dockSecondaryText)
            }
            if saved.directEndpoint {
                Text(
                    "A direct endpoint is configured. Its provider and model are preserved; edit that endpoint in Hermes Agent Desktop."
                )
                .dockFont(.body).foregroundStyle(Color.dockSecondaryText)
            }
            SettingsPreferenceRow(title: "Provider", detail: "Inherit the main agent or choose a configured provider.")
            {
                DockMenuPicker(
                    title: ["", "auto"].contains(draft.provider) ? "Inherit from main agent" : draft.provider,
                    selection: $draft.provider
                ) {
                    DockMenuOption("Inherit from main agent", value: saved.provider == "auto" ? "auto" : "")
                    ForEach(model.providers) { DockMenuOption($0.name, value: $0.slug) }
                    if !["", "auto"].contains(saved.provider),
                        !model.providers.contains(where: { $0.slug == saved.provider })
                    {
                        DockMenuOption(saved.provider, value: saved.provider)
                    }
                }
                .disabled(routeInactive || saved.directEndpoint)
            }
            .dockPadding(.vertical, 6)
            SettingsPreferenceRow(title: "Model", detail: "Leave inherited to use the main agent’s model.") {
                DockMenuPicker(
                    title: draft.model.isEmpty || draft.model == "auto" ? "Inherit from main agent" : draft.model,
                    selection: $draft.model
                ) {
                    DockMenuOption("Inherit from main agent", value: saved.model == "auto" ? "auto" : "")
                    ForEach(model.providers.first { $0.slug == draft.provider }?.models ?? [], id: \.self) {
                        DockMenuOption($0, value: $0)
                    }
                    if !saved.model.isEmpty, saved.model != "auto" { DockMenuOption(saved.model, value: saved.model) }
                }
                .disabled(routeInactive || saved.directEndpoint)
            }
            .dockPadding(.vertical, 6)
            number("Turn limit", detail: "Maximum tool-calling turns per subagent.", value: $draft.turns)
            number("Parallel subagents", detail: "Maximum children running at the same time.", value: $draft.parallel)
            number("Timeout", detail: "Seconds per child. Zero means no time limit.", value: $draft.timeout)
            SettingsPreferenceRow(title: "Reasoning effort", detail: "Applied when the subagent’s model supports it.") {
                DockMenuPicker(
                    title: draft.effort.isEmpty ? "Inherit" : draft.effort.capitalized, selection: $draft.effort
                ) {
                    DockMenuOption("Inherit", value: "")
                    ForEach(
                        Array(Set(["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra", saved.effort]))
                            .filter { !$0.isEmpty }.sorted(), id: \.self
                    ) { DockMenuOption($0.capitalized, value: $0) }
                }
            }
            HStack {
                Button("Reset draft") { draft = saved }.buttonStyle(.dockSecondary).disabled(draft == saved)
                Spacer()
                Button(model.busy ? "Saving…" : "Apply changes") { confirming = true }
                    .buttonStyle(.dockPrimary).disabled(draft == saved || !draft.valid)
            }
        }
        .disabled(!model.available || model.busy)
        .onChange(of: draft.provider) { _, _ in
            if draft.provider != saved.provider { draft.model = "" }
        }
        .confirmationDialog("Apply subagent defaults?", isPresented: $confirming) {
            Button("Apply changes") {
                let draft = draft
                Task { await model.perform { try await $0.saveDefaults(draft, previous: saved) } }
            }
        } message: {
            Text(
                "Applies to future delegations for profile “\(model.service?.profile ?? "")”. Running subagents are unchanged."
            )
        }
    }

    private func number(_ title: String, detail: String, value: Binding<Int>) -> some View {
        SettingsPreferenceRow(title: title, detail: detail) {
            TextField(title, value: value, format: .number.grouping(.never))
                .textFieldStyle(.dockGlass).multilineTextAlignment(.trailing).frame(width: 92)
        }
    }
}
