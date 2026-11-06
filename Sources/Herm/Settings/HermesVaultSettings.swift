import SwiftUI

struct HermesVaultSettings: View {
    let rpc: HermesControlRPC?
    let profile: String?
    let bots: [BotSummary]
    @State private var selectedProfile: String?

    private struct Owner: Hashable {
        let connection: ObjectIdentifier?
        let profile: String
    }

    var body: some View {
        let scope = selectedProfile ?? profile ?? "default"
        VStack(alignment: .leading, spacing: 20) {
            SettingsPreferenceRow(
                title: "Applies to", detail: "Changes apply to this profile, including its active browser sessions."
            ) {
                DockMenuPicker(title: scope, selection: Binding(get: { scope }, set: { selectedProfile = $0 })) {
                    DockMenuOption(scope, value: scope)
                    ForEach(bots.filter { $0.id != scope }) { bot in
                        DockMenuOption(bot.name, value: bot.id)
                    }
                }
            }
            HermesVaultPage(service: rpc?.vault(profileID: scope), profile: scope)
                .id(Owner(connection: rpc.map(ObjectIdentifier.init), profile: scope))
        }
        .onChange(of: profile) { _, _ in selectedProfile = nil }
        .onChange(of: rpc.map(ObjectIdentifier.init)) { _, _ in selectedProfile = nil }
    }
}

private struct HermesVaultPage: View {
    @StateObject private var model: HermesVaultModel
    let profile: String
    @State private var showingAdd = false
    @State private var removing: HermesVaultItem?
    @State private var changingSource: HermesVaultSource?
    @State private var unlocking: HermesVaultSource?
    @State private var locking: HermesVaultSource?

    init(service: HermesVaultService?, profile: String) {
        _model = StateObject(wrappedValue: HermesVaultModel(service: service))
        self.profile = profile
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 12) {
                Text(model.notice).dockFont(.body).foregroundStyle(Color.dockSecondaryText)
                    .lineLimit(3).help(model.notice)
                Spacer(minLength: 0)
                Button(model.busy ? "Refreshing…" : "Refresh") { Task { await model.load() } }
                    .buttonStyle(.dockSecondary).disabled(model.busy)
            }
            .frame(height: 54, alignment: .top)
            SettingsSection(title: "Saved credentials", subtitle: "Profile: \(profile)", tint: .dockAccent) {
                HStack {
                    Text("Logins shared with Hermes Agent Desktop").dockFont(.body)
                    Spacer(minLength: 0)
                    Button("Add login") { showingAdd = true }
                        .buttonStyle(.dockPrimary).disabled(!model.available || model.busy)
                }
                if model.items.isEmpty {
                    Text(model.available ? "No saved credentials in this profile." : "Saved credentials unavailable.")
                        .dockFont(.body).foregroundStyle(Color.dockSecondaryText)
                } else {
                    ForEach(model.items, id: \.self) { item in
                        SettingsPreferenceRow(
                            title: item.label,
                            detail: [
                                item.identifier, item.origin, item.kind == "login" ? "" : item.kind.capitalized,
                                item.backend == "local"
                                    ? "" : model.sources.first { $0.id == item.backend }?.name ?? item.backend,
                            ]
                            .filter { !$0.isEmpty }
                            .joined(separator: " · ")
                        ) {
                            if item.backend == "local" {
                                Button("Remove", role: .destructive) { removing = item }
                                    .buttonStyle(.dockSecondary).disabled(!model.available || model.busy)
                            }
                        }
                    }
                }
            }
            SettingsSection(title: "Password managers", subtitle: "", tint: .dockAccent) {
                Text(
                    "Enable a detected manager, then unlock it to let Hermes use its logins. Manage external entries in that password manager."
                )
                .dockFont(.body).foregroundStyle(Color.dockSecondaryText)
                ForEach(model.sources.filter { $0.id != "local" }) { source in
                    SettingsPreferenceRow(title: source.name, detail: sourceDetail(source)) {
                        ViewThatFits(in: .horizontal) {
                            HStack { sourceActions(source) }
                            VStack(alignment: .trailing) { sourceActions(source) }
                        }
                        .disabled(!model.available || model.busy || !source.installed)
                    }
                }
                if model.sources.isEmpty {
                    Text("Password-manager status unavailable.").dockFont(.body).foregroundStyle(
                        Color.dockSecondaryText)
                }
            }
        }
        .dockButtonSize(.compact)
        .task { await model.load() }
        .dockSheet(isPresented: $showingAdd) {
            HermesVaultLoginEditor(model: model, profile: profile)
        }
        .dockSheet(isPresented: Binding(get: { unlocking != nil }, set: { if !$0 { unlocking = nil } })) {
            if let source = unlocking { HermesVaultUnlockEditor(model: model, source: source, profile: profile) }
        }
        .confirmationDialog(
            "Remove saved credential?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })
        ) {
            if let item = removing {
                Button("Remove \(item.label)", role: .destructive) {
                    removing = nil
                    Task { await model.perform { try await $0.remove(item) } }
                }
            }
        } message: {
            Text(
                "Removes this credential from profile “\(profile)” for future fills, including active sessions. Existing website sign-ins remain signed in."
            )
        }
        .confirmationDialog(
            "Change password-manager access?",
            isPresented: Binding(get: { changingSource != nil }, set: { if !$0 { changingSource = nil } })
        ) {
            if let source = changingSource {
                Button(source.enabled ? "Disable \(source.name)" : "Enable \(source.name)") {
                    changingSource = nil
                    Task { await model.perform { try await $0.setEnabled(source, enabled: !source.enabled) } }
                }
            }
        } message: {
            Text(
                "Changes access for profile “\(profile)”, including active sessions. Disabling also locks the manager.")
        }
        .confirmationDialog(
            "Lock password manager?",
            isPresented: Binding(get: { locking != nil }, set: { if !$0 { locking = nil } })
        ) {
            if let source = locking {
                Button("Lock \(source.name)") {
                    locking = nil
                    Task { await model.perform { try await $0.lock(source) } }
                }
            }
        } message: {
            Text(
                "Stops future fills from this manager in profile “\(profile)”, including active sessions, until you unlock it again."
            )
        }
    }

    private func sourceDetail(_ source: HermesVaultSource) -> String {
        if !source.installed { return "Install this manager’s CLI on the Hermes backend to connect." }
        if !source.enabled { return "Disabled for this profile" }
        return source.unlocked ? "Unlocked for Hermes" : "Locked — unlock to use saved logins"
    }

    @ViewBuilder private func sourceActions(_ source: HermesVaultSource) -> some View {
        if source.enabled && source.needsUnlock {
            if source.unlocked {
                Button("Lock") { locking = source }
                    .buttonStyle(.dockSecondary)
            } else {
                Button("Unlock") { unlocking = source }.buttonStyle(.dockSecondary)
            }
        }
        Button(source.enabled ? "Disable" : "Enable") { changingSource = source }.buttonStyle(.dockSecondary)
    }
}

private struct HermesVaultLoginEditor: View {
    @ObservedObject var model: HermesVaultModel
    let profile: String
    @Environment(\.dismiss) private var dismiss
    @State private var label = ""
    @State private var origin = ""
    @State private var identifier = ""
    @State private var type = "email"
    @State private var password = ""
    @State private var otp = ""

    private var valid: Bool {
        !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && HermesVaultService.validOrigin(origin.trimmingCharacters(in: .whitespacesAndNewlines))
            && !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !password.isEmpty
    }

    var body: some View {
        DockModal(title: "Add login", subtitle: "Profile: \(profile)", width: 460) {
            VStack(alignment: .leading, spacing: 12) {
                Text(
                    "Available for future browser fills, including active sessions. The account name and website are visible to the model; the password is not."
                )
                .dockFont(.body).foregroundStyle(Color.dockSecondaryText)
                DockTextField("Label", text: $label).textFieldStyle(.dockGlass)
                DockTextField("Website (https://example.com)", text: $origin).textFieldStyle(.dockGlass)
                DockMenuPicker("Account type", title: type.capitalized, selection: $type) {
                    DockMenuOption("Email", value: "email")
                    DockMenuOption("Username", value: "username")
                    DockMenuOption("Phone", value: "phone")
                }
                DockTextField("Account name", text: $identifier).textFieldStyle(.dockGlass)
                SecureField("Password", text: $password).textFieldStyle(.dockGlass)
                SecureField("One-time password secret (optional)", text: $otp).textFieldStyle(.dockGlass)
                if !model.available { Text(model.notice).dockFont(.body).foregroundStyle(Color.dockWarning) }
            }
        } footer: {
            HStack {
                Button("Cancel") {
                    clearSecrets()
                    dismiss()
                }.buttonStyle(.dockSecondary).disabled(model.busy)
                Spacer()
                Button(model.busy ? "Saving…" : "Save login") { save() }
                    .buttonStyle(.dockPrimary).disabled(!valid || !model.available || model.busy)
            }
        }
        .onDisappear { clearSecrets() }
    }

    private func clearSecrets() {
        password = ""
        otp = ""
    }

    private func save() {
        let password = password
        let otp = otp
        clearSecrets()
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let origin = origin.trimmingCharacters(in: .whitespacesAndNewlines)
        let identifier = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let type = type
        Task {
            let saved = await model.perform {
                try await $0.addLogin(
                    label: label, origin: origin, identifier: identifier, type: type, password: password, otp: otp)
            }
            if saved { dismiss() }
        }
    }
}

private struct HermesVaultUnlockEditor: View {
    @ObservedObject var model: HermesVaultModel
    let source: HermesVaultSource
    let profile: String
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""

    var body: some View {
        DockModal(title: "Unlock \(source.name)", subtitle: "Profile: \(profile)", width: 420) {
            VStack(alignment: .leading, spacing: 12) {
                Text(
                    "Lets Hermes use this manager’s logins in this profile, including active sessions. The master password is sent to the manager and is not saved by Herm."
                )
                .dockFont(.body).foregroundStyle(Color.dockSecondaryText)
                SecureField("Master password", text: $password).textFieldStyle(.dockGlass)
                if !model.available { Text(model.notice).dockFont(.body).foregroundStyle(Color.dockWarning) }
            }
        } footer: {
            HStack {
                Button("Cancel") {
                    password = ""
                    dismiss()
                }.buttonStyle(.dockSecondary).disabled(model.busy)
                Spacer()
                Button(model.busy ? "Unlocking…" : "Unlock") {
                    let secret = password
                    password = ""
                    Task {
                        let unlocked = await model.perform { try await $0.unlock(source, password: secret) }
                        if unlocked { dismiss() }
                    }
                }
                .buttonStyle(.dockPrimary).disabled(password.isEmpty || !model.available || model.busy)
            }
        }
        .onDisappear { password = "" }
    }
}
