import SwiftUI
import UniformTypeIdentifiers

/// Bot Mode's Edit Profile surface over the live profile: title,
/// description, avatar, model pin, SOUL.md, and per-skill/toolset/MCP
/// enablement — all applied through the verified `profiles.*` contracts.
struct BotProfileEditorSheet: View {
    @ObservedObject var model: BotModeModel
    let bot: BotSummary
    let onDone: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var detail: BotProfileDetail?
    @State private var modelChoices: [(provider: String, models: [String])] = []
    @State private var selectedProvider: String = ""
    @State private var selectedModel: String = ""
    @State private var isChangingModel = false
    @State private var runtime: BotRuntimeConfig?
    /// Edited fallback chain; `nil` until the user touches it.
    @State private var fallbackDraft: [BotRuntimeConfig.ModelRef]?
    @State private var fallbackProvider = ""
    @State private var fallbackModel = ""
    @State private var isSaving = false
    @State private var editError: String?
    @State private var pendingConfirmMessage: String?
    @State private var isGeneratingAvatar = false
    @State private var avatarPreview: Data?
    @State private var pendingAvatarData: Data?
    @State private var clearsAvatar = false
    @State private var showsSoul = false
    @State private var showsSkills = false
    @State private var showsToolsets = false
    @State private var showsMCPServers = false
    @State private var showsIntegrationSetup = false

    var body: some View {
        DockModal(
            badge: AnyView(BotAvatarView(bot: bot, imageData: avatarPreview ?? model.avatarImages[bot.id], size: 32)),
            title: "Edit \(bot.name)",
            subtitle: "Changes apply to Hermes profile \(bot.id)",
            width: 520,
            contentPadding: 0
        ) {
            if detail == nil {
                BotEditorLoadingState().padding(20)
            } else {
                editorForm
            }
        } footer: {
            modalActions(primaryTitle: "Save Changes", isDisabled: detail == nil || isSaving, isPending: isSaving, onCancel: { dismiss() }) {
                Task { await save(confirm: false) }
            }
        }
        .frame(minHeight: 480)
        .task { await load() }
        .sheet(isPresented: $showsIntegrationSetup) {
            if let client = model.integrationClient {
                WorkflowIntegrationView(destination: IntegrationDestination(profileID: bot.id), client: client)
            }
        }
        .alert("Confirm Model", isPresented: Binding(get: { pendingConfirmMessage != nil }, set: { if !$0 { pendingConfirmMessage = nil } })) {
            Button("Cancel", role: .cancel) { pendingConfirmMessage = nil }
            Button("Use This Model") { Task { await save(confirm: true) } }
        } message: {
            Text(pendingConfirmMessage ?? "")
        }
    }

    private var editorForm: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                modalSection("IDENTITY") {
                    avatarRow
                    labeledField("Title") {
                        DockTextField("Roster title", text: Binding(get: { detail?.title ?? "" }, set: { detail?.title = $0 }))
                            .textFieldStyle(.dockGlass)
                    }
                    labeledField("Description") {
                        DockTextField("What this Bot does", text: Binding(get: { detail?.description ?? "" }, set: { detail?.description = $0 }), axis: .vertical)
                            .lineLimit(2...5)
                            .textFieldStyle(.dockGlass)
                    }
                }
                modalSection("MODELS") { modelCard }
                modalSection("PERSONA") { soulRow }
                modalSection("CAPABILITIES") {
                    Button("Manage integrations…") { showsIntegrationSetup = true }.buttonStyle(.dockSecondary)
                    VStack(alignment: .leading, spacing: 10) {
                        DisclosureGroup(isExpanded: $showsSkills) {
                            toggleSection(items: skillBinding)
                        } label: {
                            capabilityLabel("Skills", enabled: detail?.skills.filter(\.enabled).count ?? 0, total: detail?.skills.count ?? 0)
                        }
                        .disclosureGroupStyle(DockDisclosureGroupStyle())
                        DisclosureGroup(isExpanded: $showsToolsets) {
                            toolsetSection
                        } label: {
                            capabilityLabel("Toolsets", enabled: detail?.toolsets.filter(\.enabled).count ?? 0, total: detail?.toolsets.count ?? 0)
                        }
                        .disclosureGroupStyle(DockDisclosureGroupStyle())
                        DisclosureGroup(isExpanded: $showsMCPServers) {
                            toggleSection(items: mcpBinding)
                        } label: {
                            capabilityLabel("MCP Servers", enabled: detail?.mcpServers.filter(\.enabled).count ?? 0, total: detail?.mcpServers.count ?? 0)
                        }
                        .disclosureGroupStyle(DockDisclosureGroupStyle())
                    }
                    .padding(12)
                    .background(cardBackground)
                }
                if let editError {
                    ModalNote(text: editError, icon: .warning, tone: .dockWarning)
                }
            }
            .padding(20)
        }
        .frame(maxHeight: 560)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous)
            .dockSurfaceFill(Color.dockControlSurface, stroke: Color.dockBorder, lineWidth: 0.5)
    }

    private func capabilityLabel(_ title: String, enabled: Int, total: Int) -> some View {
        HStack {
            Text(title).dockFont(.body, weight: .semibold).foregroundStyle(Color.dockPrimaryText)
            Spacer()
            Text("\(enabled) of \(total) on").dockFont(.metadata, weight: .regular, design: .monospaced).foregroundStyle(Color.dockMetadataText)
        }
    }

    private var avatarRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            avatarButtons
            if !clearsAvatar, !BotAvatarView.showsHermFace(avatarPreview ?? model.avatarImages[bot.id], id: bot.id) {
                HStack(spacing: 8) {
                    Label("This image won't animate. Blinking, spinning and reactions only work on Herm faces.", icon: .info)
                        .dockFont(.compactStatus, weight: .regular)
                        .foregroundStyle(Color.dockMetadataText)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Use Herm Face") { BotFaceMark.png(id: bot.id).map(applyPendingAvatar) }
                        .buttonStyle(.dockSecondary)
                        .controlSize(.small)
                }
            }
        }
    }

    private var avatarButtons: some View {
        HStack(spacing: 8) {
            Button("Upload…") { uploadAvatar() }
                .buttonStyle(.dockSecondary)
                .controlSize(.small)
            if model.isImageGenerationAvailable {
                Button {
                    Task { await generateAvatar() }
                } label: {
                    DockActionLabel(title: "Generate", pendingTitle: "Generating…", isPending: isGeneratingAvatar)
                }
                .buttonStyle(.dockSecondary)
                .controlSize(.small)
                .disabled(isGeneratingAvatar)
            }
            if bot.hasAvatar || avatarPreview != nil || clearsAvatar {
                Button("Clear", role: .destructive) {
                    pendingAvatarData = nil
                    avatarPreview = nil
                    clearsAvatar = true
                }
                .buttonStyle(.dockSecondary)
                .controlSize(.small)
            }
            if clearsAvatar { Text("avatar will be removed").dockFont(.compactStatus, weight: .regular).foregroundStyle(Color.dockMetadataText) }
            Spacer()
        }
    }

    /// Primary pin (editable) plus the profile's read-only runtime facts.
    private var modelCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                factRow("Primary") {
                    if let pinned = detail?.model, !pinned.isEmpty {
                        modelText(pinned, provider: detail?.provider)
                    } else {
                        Text("Inherited from launch profile").foregroundStyle(Color.dockSecondaryText)
                    }
                }
                Button(isChangingModel ? "Keep" : "Change") { withAnimation { isChangingModel.toggle() } }
                    .buttonStyle(.dockSecondary)
                    .controlSize(.small)
            }
            if isChangingModel {
                HStack(spacing: 8) {
                    DockMenuPicker(title: selectedProvider.isEmpty ? "Provider…" : selectedProvider, selection: $selectedProvider) {
                        DockMenuOption("Provider…", value: "")
                        ForEach(modelChoices, id: \.provider) { choice in
                            DockMenuOption(choice.provider, value: choice.provider)
                        }
                    }
                    DockMenuPicker(title: selectedModel.isEmpty ? "Model…" : selectedModel, selection: $selectedModel) {
                        DockMenuOption("Model…", value: "")
                        ForEach(availableModels, id: \.self) { DockMenuOption($0, value: $0) }
                    }
                }
                .labelsHidden()
                .padding(.bottom, 8)
            }
            Divider()
            fallbackSection
            Divider()
            HStack(spacing: 0) {
                factRow("Reasoning") { Text(runtime?.reasoningEffort?.capitalized ?? "Default") }
                factRow("Context") { Text(runtime?.contextLength.map(Self.tokens) ?? "Auto") }
                factRow("Compress at") { Text(runtime?.compressionThreshold.map(Self.tokens) ?? "Default") }
            }
        }
        .padding(.horizontal, 12)
        .background(cardBackground)
    }

    private var fallbacks: [BotRuntimeConfig.ModelRef] { fallbackDraft ?? runtime?.fallbacks ?? [] }

    private var fallbackSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                factRow("Fallback") {
                    if fallbacks.isEmpty {
                        Text(runtime == nil ? "—" : "None").foregroundStyle(Color.dockMetadataText)
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(fallbacks.enumerated()), id: \.offset) { index, ref in
                                HStack(spacing: 6) {
                                    Text("\(index + 1).").dockFont(.compactStatus, weight: .regular, design: .monospaced).foregroundStyle(Color.dockMetadataText)
                                    modelText(ref.model, provider: ref.provider)
                                    Spacer()
                                    if fallbackDraft != nil {
                                        Button("Remove", role: .destructive) { fallbackDraft?.remove(at: index) }
                                            .buttonStyle(.dockSecondary)
                                            .controlSize(.mini)
                                    }
                                }
                            }
                        }
                    }
                }
                if fallbackDraft == nil {
                    Button("Edit") { withAnimation { fallbackDraft = runtime?.fallbacks ?? [] } }
                        .buttonStyle(.dockSecondary)
                        .controlSize(.small)
                        .disabled(runtime == nil)
                }
            }
            if fallbackDraft != nil {
                HStack(spacing: 8) {
                    DockMenuPicker(title: fallbackProvider.isEmpty ? "Provider…" : fallbackProvider, selection: $fallbackProvider) {
                        DockMenuOption("Provider…", value: "")
                        ForEach(modelChoices, id: \.provider) { DockMenuOption($0.provider, value: $0.provider) }
                    }
                    DockMenuPicker(title: fallbackModel.isEmpty ? "Model…" : fallbackModel, selection: $fallbackModel) {
                        DockMenuOption("Model…", value: "")
                        ForEach(modelChoices.first { $0.provider == fallbackProvider }?.models ?? [], id: \.self) { DockMenuOption($0, value: $0) }
                    }
                    Button("Add") {
                        let ref = BotRuntimeConfig.ModelRef(provider: fallbackProvider, model: fallbackModel)
                        if !fallbacks.contains(where: { $0.provider == ref.provider && $0.model == ref.model }) { fallbackDraft?.append(ref) }
                        fallbackModel = ""
                    }
                    .buttonStyle(.dockSecondary)
                    .controlSize(.small)
                    .disabled(fallbackProvider.isEmpty || fallbackModel.isEmpty)
                }
                .labelsHidden()
                .padding(.bottom, 8)
            }
        }
    }

    private func factRow<Value: View>(_ label: String, @ViewBuilder value: () -> Value) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).dockFont(.compactStatus, weight: .medium).foregroundStyle(Color.dockMetadataText)
            value().dockFont(.body).foregroundStyle(Color.dockPrimaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 9)
    }

    private func modelText(_ model: String, provider: String?) -> some View {
        HStack(spacing: 6) {
            Text(model).dockFont(.body, weight: .semibold, design: .monospaced)
            if let provider, !provider.isEmpty {
                Text(provider).dockFont(.compactStatus, weight: .regular).foregroundStyle(Color.dockMetadataText).lineLimit(1).truncationMode(.middle)
            }
        }
    }

    static func tokens(_ count: Int) -> String {
        count >= 1000 ? "\(count / 1000)K tokens" : "\(count) tokens"
    }

    private var soulRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("SOUL.md").dockFont(.body, weight: .semibold).foregroundStyle(Color.dockPrimaryText)
                    Text(soulSummary).dockFont(.compactStatus, weight: .regular).foregroundStyle(Color.dockMetadataText)
                }
                Spacer()
                Button(showsSoul ? "Hide" : "Edit") { withAnimation { showsSoul.toggle() } }
                    .buttonStyle(.dockSecondary)
                    .controlSize(.small)
            }
            if showsSoul {
                TextEditor(text: Binding(get: { detail?.soul ?? "" }, set: { detail?.soul = $0 }))
                    .dockFont(.metadata, weight: .regular, design: .monospaced)
                    .frame(height: 180)
                    .scrollContentBackground(.hidden)
                    .background(Color.dockCanvas)
                    .clipShape(RoundedRectangle(cornerRadius: DockLayout.controlRadius - 2))
            }
        }
        .padding(12)
        .background(cardBackground)
    }

    private var soulSummary: String {
        let soul = detail?.soul ?? ""
        if soul.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Empty — Hermes default persona" }
        let lines = soul.split(separator: "\n", omittingEmptySubsequences: false).count
        return "\(lines) lines · \(soul.count) characters"
    }

    private var skillBinding: Binding<[BotToggleItem]> {
        Binding(get: { detail?.skills ?? [] }, set: { detail?.skills = $0 })
    }
    private var toolsetBinding: Binding<[BotToolsetItem]> {
        Binding(get: { detail?.toolsets ?? [] }, set: { detail?.toolsets = $0 })
    }
    private var mcpBinding: Binding<[BotToggleItem]> {
        Binding(get: { detail?.mcpServers ?? [] }, set: { detail?.mcpServers = $0 })
    }

    private var availableModels: [String] {
        modelChoices.first { $0.provider == selectedProvider }?.models ?? []
    }

    private func toggleSection(items: Binding<[BotToggleItem]>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if items.wrappedValue.isEmpty {
                Text("None reported by Hermes").dockFont(.metadata).foregroundStyle(Color.dockMetadataText)
            } else {
                ForEach(Array(items.wrappedValue.enumerated()), id: \.element.id) { index, item in
                    Toggle(item.label, isOn: Binding(
                        get: { items.wrappedValue[index].enabled },
                        set: { items.wrappedValue[index].enabled = $0 }
                    ))
                    .controlSize(.small)
                    .padding(.horizontal, 4)
                }
            }
        }
    }

    private var toolsetSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            if toolsetBinding.wrappedValue.isEmpty {
                Text("None reported by Hermes").dockFont(.metadata).foregroundStyle(Color.dockMetadataText)
            } else {
                ForEach(Array(toolsetBinding.wrappedValue.enumerated()), id: \.element.id) { index, item in
                    let isOn = Binding(
                        get: { toolsetBinding.wrappedValue[index].enabled },
                        set: { toolsetBinding.wrappedValue[index].enabled = $0 }
                    )
                    HStack(alignment: .firstTextBaseline) {
                        Toggle(isOn: isOn) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("\(item.label) (\(item.toolCount))").dockFont(.body)
                                if !item.detail.isEmpty {
                                    Text(item.detail).dockFont(.compactStatus, weight: .regular).foregroundStyle(Color.dockMetadataText)
                                }
                            }
                        }
                        .controlSize(.small)
                        Spacer()
                    }
                    .padding(.horizontal, 4)
                }
            }
        }
    }

    private func load() async {
        async let runtimeConfig = model.runtimeConfig(for: bot)
        detail = await model.profileDetail(for: bot)
        selectedProvider = detail?.provider ?? ""
        selectedModel = detail?.model ?? ""
        runtime = await runtimeConfig
        modelChoices = await model.modelOptions()
        await model.checkImageGeneration()
    }

    private func uploadAvatar() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .webP]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runAboveHerm() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        applyPendingAvatar(data)
    }

    private func generateAvatar() async {
        isGeneratingAvatar = true
        defer { isGeneratingAvatar = false }
        let prompt = "Friendly avatar portrait for an AI assistant named \(bot.title ?? bot.name), simple, clean, centered"
        guard let dataURL = try? await model.generateAvatar(prompt: prompt),
              let data = BotService.decodeDataURL(dataURL) else { return }
        applyPendingAvatar(data)
    }

    private func applyPendingAvatar(_ data: Data) {
        pendingAvatarData = data
        avatarPreview = data
        clearsAvatar = false
    }

    private func save(confirm: Bool) async {
        guard var current = detail else { return }
        if !isChangingModel {
            current.provider = nil
            current.model = nil
        } else {
            guard !selectedProvider.isEmpty, !selectedModel.isEmpty else {
                editError = "Choose both a provider and a model, or tap Keep."
                return
            }
            current.provider = selectedProvider.isEmpty ? nil : selectedProvider
            current.model = selectedModel.isEmpty ? nil : selectedModel
        }
        isSaving = true
        defer { isSaving = false }

        switch await model.applyProfileEdit(current, confirmExpensiveModel: confirm) {
        case .applied:
            break
        case .needsConfirmation(let message):
            pendingConfirmMessage = message
            editError = nil
            return
        case .failed(let message):
            editError = message
            return
        }

        if let draft = fallbackDraft, draft != runtime?.fallbacks {
            if let message = await model.setFallbacks(draft, for: bot) {
                editError = message
                return
            }
            runtime?.fallbacks = draft
        }

        do {
            if let data = pendingAvatarData {
                guard let dataURL = BotService.encodeDataURL(data) else {
                    editError = "That image could not be read as PNG, JPEG, or WebP."
                    return
                }
                try await model.setAvatar(profileID: bot.id, dataURL: dataURL)
            } else if clearsAvatar {
                try await model.clearAvatar(profileID: bot.id)
            }
        } catch {
            editError = "Profile saved, but the avatar could not be saved. Try again."
            return
        }

        onDone()
        dismiss()
    }
}

private struct BotEditorLoadingState: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading profile configuration…")
                    .dockFont(.body, weight: .medium)
                    .foregroundStyle(Color.dockSecondaryText)
            }
            .padding(.bottom, 4)
            ForEach(0..<3, id: \.self) { _ in
                RoundedRectangle(cornerRadius: DockLayout.controlRadius - 2, style: .continuous)
                    .fill(Color.dockControlSurface)
                    .frame(height: 38)
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.dockSurface4)
                            .frame(width: 110, height: 8)
                            .padding(.horizontal, 12)
                    }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 230, alignment: .topLeading)
        .padding(.top, 8)
    }
}

/// Duplicate = `profiles.create` with `clone_from`, matching Bot Mode's
/// full-clone duplication of a profile.
struct BotDuplicateSheet: View {
    @ObservedObject var model: BotModeModel
    let bot: BotSummary
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @State private var isDuplicating = false

    var body: some View {
        DockModal(icon: .copy, title: "Duplicate \(bot.name)", subtitle: "Clones config, skills, SOUL, and memory into a new profile.", width: 400) {
            labeledField("New profile name", hint: "Lowercase letters, numbers, dashes, or underscores") {
                DockTextField("e.g. \(bot.name)-copy", text: $newName)
                    .textFieldStyle(.dockGlass)
            }
            if let error = model.botCreationError {
                ModalNote(text: error, icon: .warning, tone: .dockWarning)
            }
        } footer: {
            modalActions(primaryTitle: "Duplicate", pendingTitle: "Duplicating…", isDisabled: !BotCreationSheet.isValidProfileName(trimmedName) || isDuplicating, isPending: isDuplicating, onCancel: { dismiss() }) {
                Task {
                    isDuplicating = true
                    if await model.duplicateBot(bot, newName: trimmedName) { dismiss() }
                    isDuplicating = false
                }
            }
        }
    }

    private var trimmedName: String { newName.trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// New routine form; Hermes stores it as a `[bot:<name>]` cron job.
struct BotRoutineFormSheet: View {
    @ObservedObject var model: BotModeModel
    let bots: [BotSummary]
    @Environment(\.dismiss) private var dismiss
    @State private var selectedProfile = ""
    @State private var title = ""
    @State private var schedule = ""
    @State private var prompt = ""
    @State private var isSaving = false

    var body: some View {
        DockModal(icon: .calendarBlank, title: "New Routine", subtitle: "Recurring work a Bot runs on a schedule.", width: 440) {
            modalSection("ASSIGNMENT") {
                labeledField("Bot", hint: "The profile that owns this routine") {
                    DockMenuPicker(title: bots.first { $0.id == selectedProfile }?.name ?? "Choose…", selection: $selectedProfile) {
                        ForEach(bots) { bot in DockMenuOption(bot.name, value: bot.id) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .frame(minHeight: DockLayout.controlHeight)
                    .background(
                        RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous)
                            .dockSurfaceFill(Color.dockControlSurface, stroke: Color.dockBorder, lineWidth: 0.5)
                    )
                }
            }

            modalSection("SCHEDULE") {
                labeledField("Title", hint: "A short name for the recurring work") {
                    DockTextField("e.g. Summarize inbox", text: $title)
                        .textFieldStyle(.dockGlass)
                }
                labeledField("Schedule", hint: "Use a plain-language interval") {
                    DockTextField("e.g. every day 9am", text: $schedule)
                        .textFieldStyle(.dockGlass)
                }
                labeledField("Prompt", hint: "Instructions sent to the Bot") {
                    DockTextField("What should this routine do?", text: $prompt)
                        .textFieldStyle(.dockGlass)
                }
            }

            if let error = model.botCreationError {
                ModalNote(text: error, icon: .warning, tone: .dockWarning)
            }
        } footer: {
            modalActions(primaryTitle: "Add Routine", isDisabled: !isValid || isSaving, isPending: isSaving, onCancel: { dismiss() }) {
                Task {
                    guard let bot = bots.first(where: { $0.id == selectedProfile }) else { return }
                    isSaving = true
                    if await model.createRoutine(for: bot, title: title, schedule: schedule, prompt: prompt) {
                        dismiss()
                    }
                    isSaving = false
                }
            }
        }
        .onAppear {
            if selectedProfile.isEmpty { selectedProfile = bots.first?.id ?? "" }
        }
    }

    private var isValid: Bool {
        BotService.isSafeSchedule(schedule) && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !selectedProfile.isEmpty
    }
}
