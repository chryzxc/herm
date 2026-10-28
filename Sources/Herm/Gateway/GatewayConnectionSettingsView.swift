import SwiftUI

struct GatewayConnectionSettingsView: View {
    @StateObject private var model: GatewayConnectionModel
    @ObservedObject private var store: GatewayConnectionStore
    @State private var confirmsRestart = false
    @State private var confirmsRemoval = false
    let onRestart: () -> Void

    init(store: GatewayConnectionStore = .shared, onRestart: @escaping () -> Void) {
        self.store = store
        _model = StateObject(wrappedValue: GatewayConnectionModel(store: store))
        self.onRestart = onRestart
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            SettingsSection(title: "Gateway connection", subtitle: "This Mac", tint: .dockAccent) {
                VStack(alignment: .leading, spacing: 12) {
                    if store.environmentOverride {
                        Text(
                            "This connection was set by HERMES_DESKTOP_REMOTE_URL. Restart Herm without that startup setting to change it here."
                        )
                        .dockFont(.body).foregroundStyle(Color.dockWarning)
                    }
                    Text(
                        "Choose the Hermes backend Herm uses for chat, profiles, and agent settings. Connection changes apply after restarting Herm."
                    )
                    .dockFont(.body).foregroundStyle(Color.dockSecondaryText)
                    SettingsPreferenceRow(title: "Connection mode", detail: "") {
                        DockMenuPicker(
                            title: modeTitle(model.draft.mode),
                            selection: Binding(
                                get: { model.draft.mode },
                                set: { mode in
                                    if mode == .cloud && model.draft.mode != .cloud { model.draft.remoteURL = "" }
                                    model.draft.mode = mode
                                }
                            )
                        ) {
                            ForEach(GatewayConnectionSettings.Mode.allCases, id: \.self) { mode in
                                DockMenuOption(modeTitle(mode), value: mode)
                            }
                        }
                    }
                    .disabled(store.environmentOverride)
                    if !store.environmentOverride {
                        field("Connection name", text: $model.draft.name, prompt: "Name")
                    }
                    switch model.draft.mode {
                    case .local:
                        Text("Start a private Hermes backend on this Mac. No remote sign-in is needed.")
                            .dockFont(.body).foregroundStyle(Color.dockSecondaryText)
                    case .remote: remoteFields
                    case .ssh: sshFields
                    case .cloud: cloudFields
                    }
                    if model.draft.mode != .local {
                        Text(
                            "Repository tools, local terminals, agent updates, and General's messaging gateway controls still operate on this Mac."
                        )
                        .dockFont(.body).foregroundStyle(Color.dockSecondaryText)
                    }
                    Divider().overlay(Color.dockBorderLight)
                    actions
                    Text(model.message.isEmpty ? " " : model.message)
                        .dockFont(.body)
                        .foregroundStyle(model.isError ? Color.dockWarning : Color.dockSecondaryText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, minHeight: 36, alignment: .topLeading)
                }
                .disabled(model.isBusy)
            }
            if !store.connections.isEmpty && !store.environmentOverride {
                SettingsSection(title: "Saved connections", subtitle: "", tint: .dockAccent) {
                    VStack(spacing: 4) {
                        ForEach(store.connections) { connection in
                            Button {
                                model.select(connection)
                            } label: {
                                HStack(spacing: 10) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(connection.name).dockFont(.body, weight: .semibold).foregroundStyle(
                                            Color.dockPrimaryText)
                                        Text(modeTitle(connection.mode)).dockFont(.body).foregroundStyle(
                                            Color.dockSecondaryText)
                                    }
                                    Spacer()
                                    if connection.id == model.draft.id {
                                        DockIcon(.check, size: 12, color: .dockAccent)
                                    }
                                }.padding(.vertical, 6).dockListRow(isHighlighted: connection.id == model.draft.id)
                            }.buttonStyle(.dockHover)
                        }
                    }
                    HStack {
                        Button("New connection") { model.select(GatewayConnectionSettings()) }
                        Spacer()
                        if store.connections.contains(where: { $0.id == model.draft.id }) {
                            Button("Remove saved connection", role: .destructive) { confirmsRemoval = true }
                        }
                    }.buttonStyle(.dockSecondary).dockFont(.body, weight: .medium)
                }.disabled(model.isBusy)
            }
        }
        .task {
            await model.refreshAuthentication()
            if model.draft.mode == .cloud && model.portalSignedIn { await model.refreshCloud() }
        }
        .onChange(of: model.draft.remoteURL) { _, _ in Task { await model.refreshAuthentication() } }
        .onChange(of: model.draft.mode) { _, _ in Task { await model.refreshAuthentication() } }
        .confirmationDialog("Save connection and restart Herm?", isPresented: $confirmsRestart) {
            Button("Save and restart Herm", role: .destructive) { Task { if await model.save() { onRestart() } } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Herm will close its current backend connection and reopen using these settings. Unsaved draft text and the current session view will be cleared."
            )
        }
        .confirmationDialog("Remove this saved connection?", isPresented: $confirmsRemoval) {
            Button("Remove saved connection", role: .destructive) {
                model.removeSavedConnection()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The active connection and its sign-in are kept. This removes the shortcut from the saved list.")
        }
        .accessibilityIdentifier("gateway-connection-settings")
    }

    private var remoteFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            field("Remote URL", text: $model.draft.remoteURL, prompt: "https://host.example/hermes")
                .disabled(store.environmentOverride)
            Text(
                "Dashboard base URL; path prefixes are supported. Remote gateways require HTTPS; HTTP is allowed only on loopback. SSH connections use an encrypted tunnel."
            )
            .dockFont(.body).foregroundStyle(Color.dockSecondaryText)
            SettingsPreferenceRow(title: "Authentication", detail: "") {
                DockMenuPicker(
                    title: model.draft.authentication == .token ? "Session token" : "Sign in",
                    selection: $model.draft.authentication
                ) {
                    DockMenuOption("Session token", value: GatewayConnectionSettings.Authentication.token)
                    DockMenuOption("Sign in", value: GatewayConnectionSettings.Authentication.signIn)
                }
            }.disabled(store.environmentOverride)
            if model.draft.authentication == .token {
                SecureField("Leave blank to keep this URL's saved token", text: $model.tokenDraft)
                    .textFieldStyle(.dockGlass).dockFont(.body)
                    .accessibilityLabel("Gateway session token")
                    .disabled(store.environmentOverride)
                Text("Session tokens are stored in macOS Keychain and used for HTTP and WebSocket authentication.")
                    .dockFont(.body).foregroundStyle(Color.dockSecondaryText)
            } else {
                signInActions(portal: false)
                Text(
                    "OAuth opens your browser when the gateway supports native sign-in; username and password use the gateway's sign-in page. Tokens stay in Keychain and sessions renew through the gateway."
                )
                .dockFont(.body).foregroundStyle(Color.dockSecondaryText)
            }
        }
    }

    private var sshFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(
                "Herm launches Hermes on the remote host and opens an SSH tunnel. Use a Host alias from ~/.ssh/config or user@host with key-based authentication. The first host key is pinned; changed keys are refused."
            )
            .dockFont(.body).foregroundStyle(Color.dockSecondaryText)
            field("Host", text: $model.draft.sshHost, prompt: "user@host or SSH alias")
            field("User", text: $model.draft.sshUser, prompt: "Use SSH config")
            SettingsPreferenceRow(title: "Port", detail: "") {
                TextField("22", value: $model.draft.sshPort, format: .number.grouping(.never))
                    .textFieldStyle(.dockGlass).dockFont(.body).frame(width: 90)
                    .accessibilityLabel("SSH port")
            }
            field("Private key", text: $model.draft.sshKeyPath, prompt: "Use SSH agent or SSH config")
            field("Remote Hermes path", text: $model.draft.remoteHermesPath, prompt: "Discover automatically")
            field("Remote profile", text: $model.draft.remoteProfile, prompt: "Default")
            Text(
                "Supports Linux, macOS, and Windows hosts with a current Hermes installation. Uses Hermes' bundled Node runtime or Node.js 20 or newer on this Mac."
            )
            .dockFont(.body).foregroundStyle(Color.dockSecondaryText)
        }
    }

    private var cloudFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sign in to Hermes Cloud, choose an organization if needed, then select an agent on your account.")
                .dockFont(.body).foregroundStyle(Color.dockSecondaryText)
            signInActions(portal: true)
            if model.portalSignedIn {
                if !model.organizations.isEmpty {
                    Text("Choose an organization").dockFont(.body, weight: .semibold).foregroundStyle(
                        Color.dockPrimaryText)
                    ForEach(model.organizations) { organization in
                        Button(organization.name) {
                            model.draft.cloudOrganization = organization.slug
                            Task { await model.refreshCloud() }
                        }.buttonStyle(.dockSecondary).dockFont(.body)
                    }
                }
                ForEach(model.agents) { agent in
                    DockAsyncButton(action: { await model.chooseAgent(agent) }) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(agent.name).dockFont(.body, weight: .semibold).foregroundStyle(
                                    Color.dockPrimaryText)
                                Text(agent.status).dockFont(.body).foregroundStyle(Color.dockSecondaryText)
                            }
                            Spacer()
                            if agent.dashboardURL == model.draft.remoteURL {
                                DockIcon(.check, size: 12, color: .dockAccent)
                            }
                        }.padding(.vertical, 6).dockListRow(isHighlighted: agent.dashboardURL == model.draft.remoteURL)
                    }.buttonStyle(.dockHover).disabled(agent.dashboardURL == nil)
                }
            }
            if !model.draft.remoteURL.isEmpty {
                Text("Selected agent: \(model.draft.name)").dockFont(.body, weight: .semibold).foregroundStyle(
                    Color.dockPrimaryText)
                Text(model.draft.remoteURL).dockFont(.body).foregroundStyle(Color.dockSecondaryText).textSelection(
                    .enabled)
            }
        }
    }

    private func signInActions(portal: Bool) -> some View {
        HStack(spacing: 8) {
            let signedIn = portal ? model.portalSignedIn : model.signedIn
            Text(signedIn ? "Signed in" : "Sign-in required").dockFont(.body).foregroundStyle(Color.dockSecondaryText)
            Spacer()
            if portal && signedIn { DockAsyncButton("Refresh agents") { await model.refreshCloud() } }
            DockAsyncButton(signedIn ? "Sign in again" : "Sign in") { await model.signIn() }
            if signedIn { DockAsyncButton("Sign out") { await model.signOut() } }
        }.buttonStyle(.dockSecondary).dockFont(.body, weight: .medium)
    }

    private var actions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { actionButtons }
            VStack(alignment: .leading, spacing: 8) { actionButtons }
        }
    }

    @ViewBuilder private var actionButtons: some View {
        Button {
            Task { await model.test() }
        } label: {
            DockActionLabel(title: "Test connection", pendingTitle: "Connecting…", isPending: model.isBusy)
        }.buttonStyle(.dockSecondary)
        if !store.environmentOverride {
            Button("Save for next restart") { Task { await model.save() } }.buttonStyle(.dockSecondary)
            Button("Save and restart Herm") { confirmsRestart = true }.buttonStyle(.dockPrimary)
        }
    }

    private func field(_ title: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).dockFont(.body, weight: .semibold).foregroundStyle(Color.dockPrimaryText)
            TextField(prompt, text: text).textFieldStyle(.dockGlass).dockFont(.body)
                .accessibilityLabel(title)
        }
    }

    private func modeTitle(_ mode: GatewayConnectionSettings.Mode) -> String {
        switch mode {
        case .local: "Local gateway"
        case .remote: "Remote gateway"
        case .ssh: "Connect via SSH"
        case .cloud: "Hermes Cloud"
        }
    }
}
