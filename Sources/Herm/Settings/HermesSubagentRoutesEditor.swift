import SwiftUI

struct HermesSubagentRoutesEditor: View {
    @ObservedObject var model: HermesSubagentModel
    let routing: HermesSubagentRouting
    let bots: [BotSummary]
    let avatarImages: [String: Data]
    @Environment(\.dismiss) private var dismiss
    @State private var selectedName = ""
    @State private var name = ""
    @State private var detail = ""
    @State private var provider = ""
    @State private var modelName = ""
    @State private var defaultName: String
    @State private var profiles: [HermesSubagentRoute]
    @State private var deleting = false
    @State private var settingDefault = false
    @State private var savingProfiles = false

    init(model: HermesSubagentModel, routing: HermesSubagentRouting, bots: [BotSummary], avatarImages: [String: Data]) {
        self.model = model
        self.routing = routing
        self.bots = bots
        self.avatarImages = avatarImages
        _defaultName = State(
            initialValue: routing.configured == "model_map" ? routing.defaultModel : routing.defaultProfile)
        _profiles = State(initialValue: routing.profiles)
    }

    private var isModel: Bool { routing.configured == "model_map" }
    private var original: HermesSubagentRoute? { routing.models.first { $0.name == selectedName } }
    private var valid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !detail.trimmingCharacters(in: .whitespaces).isEmpty
            && !modelName.trimmingCharacters(in: .whitespaces).isEmpty
            && (!provider.isEmpty || original?.directEndpoint == true)
            && !routing.models.contains { $0.name == name && $0.name != selectedName }
    }

    var body: some View {
        DockModal(
            title: isModel ? "Model routes" : "Profile routes", subtitle: "Profile: \(model.service?.profile ?? "")",
            width: 500
        ) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Changes apply to future delegations. Running subagents are unchanged.")
                        .dockFont(.body).foregroundStyle(Color.dockSecondaryText)
                    if isModel { modelEditor } else { profileEditor }
                    Text(model.notice).dockFont(.body).foregroundStyle(Color.dockSecondaryText)
                }
            }.frame(maxHeight: 480)
        } footer: {
            HStack {
                Button("Done") { dismiss() }.buttonStyle(.dockSecondary)
                Spacer()
                if isModel {
                    Button(model.busy ? "Saving…" : "Save route") { saveModel() }
                        .buttonStyle(.dockPrimary).disabled(!valid)
                } else {
                    Button(model.busy ? "Saving…" : "Apply routes") { savingProfiles = true }
                        .buttonStyle(.dockPrimary)
                        .disabled(defaultName != "" && !profiles.contains { $0.name == defaultName })
                }
            }.disabled(model.busy || !model.routingAvailable)
        }
        .confirmationDialog("Remove model route?", isPresented: $deleting) {
            Button("Remove route", role: .destructive) {
                let originalName = selectedName
                Task {
                    if await model.perform({ try await $0.saveModelRoute(nil, originalName: originalName) }) {
                        dismiss()
                    }
                }
            }
        } message: {
            Text(
                "Removes “\(selectedName)” for future delegations. If it was the default route, the default is cleared."
            )
        }
        .confirmationDialog("Apply profile routes?", isPresented: $savingProfiles) {
            Button("Apply routes") {
                let routes = profiles
                let defaultName = defaultName
                Task {
                    if await model.perform({ try await $0.saveProfileRoutes(routes, defaultName: defaultName) }) {
                        dismiss()
                    }
                }
            }
        } message: {
            Text(
                "Replaces allowed delegation profiles for “\(model.service?.profile ?? "")”. Future subagents may use their tools and credentials; running subagents are unchanged."
            )
        }
        .confirmationDialog("Change default model route?", isPresented: $settingDefault) {
            Button("Make default") {
                let name = selectedName
                Task {
                    if await model.perform({ try await $0.saveModelRoute(nil, originalName: nil, makeDefault: name) }) {
                        dismiss()
                    }
                }
            }
        } message: {
            Text(
                "Future delegations in profile “\(model.service?.profile ?? "")” use “\(selectedName)” when no other model route is chosen. Running subagents are unchanged."
            )
        }
    }

    private var modelEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            DockMenuPicker("Route", title: selectedName.isEmpty ? "New route" : selectedName, selection: $selectedName)
            {
                DockMenuOption("New route", value: "")
                ForEach(routing.models) { DockMenuOption($0.name, value: $0.name) }
            }
            .onChange(of: selectedName) { _, _ in
                name = original?.name ?? ""
                detail = original?.description ?? ""
                provider = original?.provider ?? ""
                modelName = original?.model ?? ""
            }
            DockTextField("Route name", text: $name).textFieldStyle(.dockGlass)
            DockTextField("Description — when should the agent choose this?", text: $detail).textFieldStyle(.dockGlass)
            DockTextField("Provider", text: $provider).textFieldStyle(.dockGlass)
                .disabled(original?.directEndpoint == true)
            DockTextField("Model", text: $modelName).textFieldStyle(.dockGlass)
            if original?.directEndpoint == true {
                Text(
                    "This route uses a direct endpoint. Its endpoint, credentials, and additional options are preserved."
                )
                .dockFont(.body).foregroundStyle(Color.dockSecondaryText)
            }
            if !selectedName.isEmpty {
                HStack {
                    Button("Remove route", role: .destructive) { deleting = true }.buttonStyle(.dockSecondary)
                    Spacer()
                    if routing.defaultModel == selectedName {
                        Text("Default route").dockFont(.body).foregroundStyle(Color.dockSecondaryText)
                    } else {
                        Button("Make default") { settingDefault = true }.buttonStyle(.dockSecondary)
                    }
                }
            }
        }.disabled(model.busy || !model.routingAvailable)
    }

    private var profileEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(routing.knownProfiles, id: \.self) { profile in
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(
                        isOn: Binding(
                            get: { profiles.contains { $0.name == profile } },
                            set: { enabled in
                                profiles.removeAll { $0.name == profile }
                                if enabled {
                                    profiles.append(
                                        HermesSubagentRoute(
                                            name: profile, description: "", provider: "", model: "",
                                            directEndpoint: false))
                                }
                                if !enabled && defaultName == profile { defaultName = "" }
                            })
                    ) {
                        HStack(spacing: 10) {
                            if let bot = bots.first(where: { $0.id == profile }) {
                                BotAvatarView(bot: bot, imageData: avatarImages[profile], size: 28, animated: false)
                                    .accessibilityHidden(true)
                            } else {
                                BotFaceMark(id: profile, size: 28).accessibilityHidden(true)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(bots.first(where: { $0.id == profile })?.name ?? profile)
                                    .dockFont(.body).foregroundStyle(Color.dockPrimaryText)
                                if let bot = bots.first(where: { $0.id == profile }), bot.name != profile {
                                    Text(profile).dockFont(.metadata).foregroundStyle(Color.dockMetadataText)
                                }
                            }
                            Spacer(minLength: 8)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }.toggleStyle(.dockSwitch)
                    if let index = profiles.firstIndex(where: { $0.name == profile }) {
                        DockTextField("When to delegate to this profile (optional)", text: $profiles[index].description)
                            .textFieldStyle(.dockGlass)
                    }
                }
            }
            DockMenuPicker("Default", title: defaultName.isEmpty ? "No default" : defaultName, selection: $defaultName)
            {
                DockMenuOption("No default", value: "")
                ForEach(profiles) { DockMenuOption($0.name, value: $0.name) }
            }
        }.disabled(model.busy || !model.routingAvailable)
    }

    private func saveModel() {
        let route = HermesSubagentRoute(
            name: name.trimmingCharacters(in: .whitespaces),
            description: detail.trimmingCharacters(in: .whitespaces),
            provider: provider.trimmingCharacters(in: .whitespaces),
            model: modelName.trimmingCharacters(in: .whitespaces),
            directEndpoint: original?.directEndpoint ?? false)
        let originalName = selectedName.isEmpty ? nil : selectedName
        Task {
            if await model.perform({ try await $0.saveModelRoute(route, originalName: originalName) }) { dismiss() }
        }
    }
}
