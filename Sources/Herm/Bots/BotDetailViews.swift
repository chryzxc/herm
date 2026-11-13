import SwiftUI
import UniformTypeIdentifiers

/// Bot Mode's Edit Profile surface over the live profile: title,
/// description, avatar, model pin, SOUL.md, and per-skill/toolset/MCP
/// enablement — all applied through the verified `profiles.*` contracts.
struct BotProfileEditorSheet: View {
    @ObservedObject var model: BotModeModel
    let bot: BotSummary
    let onDone: () -> Void
    /// A session inspector tab instead of a sheet: no modal chrome, and saving
    /// reloads the profile rather than dismissing.
    var isEmbedded = false
    @Environment(\.dismiss) private var dismiss

    @State private var detail: BotProfileDetail?
    @State private var modelChoices: [(provider: String, models: [String])] = []
    @State private var selectedProvider: String = ""
    @State private var selectedModel: String = ""
    @State private var isChangingModel = false
    @State private var runtime: BotRuntimeConfig?
    /// Edited fallback chain; `nil` until the user touches it.
    @State private var fallbackDraft: [BotRuntimeConfig.ModelRef]?
    /// Edited reasoning/context/compress values; seeded from `runtime` on load.
    @State private var limits: BotRuntimeConfig?
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
        Group {
            if isEmbedded { embedded } else { modal }
        }
        .task { await load() }
        .dockSheet(isPresented: $showsIntegrationSetup) {
            if let client = model.integrationClient {
                WorkflowIntegrationView(destination: IntegrationDestination(profileID: bot.id), client: client)
            }
        }
        .alert(
            "Confirm Model",
            isPresented: Binding(get: { pendingConfirmMessage != nil }, set: { if !$0 { pendingConfirmMessage = nil } })
        ) {
            Button("Cancel", role: .cancel) { pendingConfirmMessage = nil }
            Button("Use This Model") { Task { await save(confirm: true) } }
        } message: {
            Text(pendingConfirmMessage ?? "")
        }
    }

    private var embedded: some View {
        VStack(spacing: 0) {
            if detail == nil {
                BotEditorLoadingState().dockPadding(20)
                Spacer(minLength: 0)
            } else {
                editorForm
            }
            Divider()
            HStack {
                Text("Changes apply to Hermes profile \(bot.id)")
                    .dockFont(.metadata)
                    .foregroundStyle(Color.dockMetadataText)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button(isSaving ? "Saving…" : "Save Changes") { Task { await save(confirm: false) } }
                    .buttonStyle(.dockPrimary)
                    .disabled(detail == nil || isSaving)
            }
            .dockButtonSize(.compact)
            .dockPadding(12)
        }
    }

    private var modal: some View {
        DockModal(
            badge: AnyView(BotAvatarView(bot: bot, imageData: avatarPreview ?? model.avatarImages[bot.id], size: 32)),
            title: "Edit \(bot.name)",
            subtitle: "Changes apply to Hermes profile \(bot.id)",
            width: 520,
            contentPadding: 0
        ) {
            if detail == nil {
                BotEditorLoadingState().dockPadding(20)
            } else {
                editorForm
            }
        } footer: {
            modalActions(
                primaryTitle: "Save Changes", isDisabled: detail == nil || isSaving, isPending: isSaving,
                onCancel: { dismiss() }
            ) {
                Task { await save(confirm: false) }
            }
        }
        .frame(minHeight: 480)
    }

    private var editorForm: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                modalSection("IDENTITY") {
                    avatarRow
                    BotIdentityFields(
                        role: Binding(get: { detail?.title ?? "" }, set: { detail?.title = $0 }),
                        purpose: Binding(get: { detail?.description ?? "" }, set: { detail?.description = $0 }))
                }
                modalSection("MODELS") { modelCard }
                modalSection("PERSONA") { soulRow }
                modalSection("CAPABILITIES") {
                    Button("Manage integrations…") { showsIntegrationSetup = true }
                        .buttonStyle(.dockSecondary)
                        .dockPadding(.top, 8)
                    VStack(alignment: .leading, spacing: 10) {
                        DisclosureGroup(isExpanded: $showsSkills) {
                            toggleSection(items: skillBinding)
                        } label: {
                            capabilityLabel(
                                "Skills", enabled: detail?.skills.filter(\.enabled).count ?? 0,
                                total: detail?.skills.count ?? 0)
                        }
                        .disclosureGroupStyle(DockDisclosureGroupStyle())
                        DisclosureGroup(isExpanded: $showsToolsets) {
                            toolsetSection
                        } label: {
                            capabilityLabel(
                                "Toolsets", enabled: detail?.toolsets.filter(\.enabled).count ?? 0,
                                total: detail?.toolsets.count ?? 0)
                        }
                        .disclosureGroupStyle(DockDisclosureGroupStyle())
                        DisclosureGroup(isExpanded: $showsMCPServers) {
                            toggleSection(items: mcpBinding)
                        } label: {
                            capabilityLabel(
                                "MCP Servers", enabled: detail?.mcpServers.filter(\.enabled).count ?? 0,
                                total: detail?.mcpServers.count ?? 0)
                        }
                        .disclosureGroupStyle(DockDisclosureGroupStyle())
                    }
                    .dockPadding(12)
                    .background(cardBackground)
                }
                if let editError {
                    ModalNote(text: editError, icon: .warning, tone: .dockWarning)
                }
            }
            .dockPadding(20)
        }
        .frame(maxHeight: isEmbedded ? .infinity : 560)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous)
            .dockSurfaceFill(Color.dockControlSurface, stroke: Color.dockBorder, lineWidth: 0.5)
    }

    private func capabilityLabel(_ title: String, enabled: Int, total: Int) -> some View {
        HStack {
            Text(title).dockFont(.body, weight: .semibold).foregroundStyle(Color.dockPrimaryText)
            Spacer()
            Text("\(enabled) of \(total) on").dockFont(.metadata, weight: .regular, design: .monospaced)
                .foregroundStyle(Color.dockMetadataText)
        }
    }

    private var avatarRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            avatarButtons
            if !clearsAvatar, !BotAvatarView.showsHermFace(avatarPreview ?? model.avatarImages[bot.id], id: bot.id) {
                HStack(spacing: 8) {
                    Label(
                        "This image won't animate. Blinking, spinning and reactions only work on Herm faces.",
                        icon: .info
                    )
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
            if clearsAvatar {
                Text("avatar will be removed").dockFont(.compactStatus, weight: .regular).foregroundStyle(
                    Color.dockMetadataText)
            }
            Spacer()
        }
    }

    /// The shared model card, plus this profile's reasoning and context limits.
    private var modelCard: some View {
        BotModelCard(
            choices: modelChoices,
            primary: Binding(
                get: {
                    selectedModel.isEmpty ? nil : .init(provider: selectedProvider, model: selectedModel)
                },
                set: {
                    selectedProvider = $0?.provider ?? ""
                    selectedModel = $0?.model ?? ""
                    isChangingModel = true
                }),
            unsetTitle: "Launch profile default", offersUnset: false,
            fallbacks: Binding(get: { fallbacks }, set: { fallbackDraft = $0 }),
            fallbacksEditable: runtime != nil
        ) {
            Divider()
            HStack(spacing: 0) {
                factRow("Reasoning") {
                    limitPicker(
                        title: limits?.reasoningEffort?.capitalized ?? "Default",
                        selection: Binding(
                            get: { limits?.reasoningEffort ?? "" },
                            set: { limits?.reasoningEffort = $0.isEmpty ? nil : $0 }),
                        options: Self.reasoningLevels.map { ($0.isEmpty ? "Default" : $0.capitalized, $0) })
                }
                factRow("Context") {
                    limitPicker(
                        title: limits?.contextLength.map(Self.tokens) ?? "Auto",
                        selection: Binding(
                            get: { limits?.contextLength ?? 0 }, set: { limits?.contextLength = $0 > 0 ? $0 : nil }),
                        options: Self.tokenChoices(Self.contextPresets, current: limits?.contextLength, zero: "Auto"))
                }
                factRow("Compress at") {
                    limitPicker(
                        title: limits?.compressionThreshold.map(Self.tokens) ?? "Default",
                        selection: Binding(
                            get: { limits?.compressionThreshold ?? 0 },
                            set: { limits?.compressionThreshold = $0 > 0 ? $0 : nil }),
                        options: Self.tokenChoices(
                            Self.compressPresets, current: limits?.compressionThreshold, zero: "Default"))
                }
            }
            .dockPadding(.horizontal, 12)
        }
    }

    private static let reasoningLevels = ["", "minimal", "low", "medium", "high", "xhigh"]
    private static let contextPresets = [32_000, 64_000, 128_000, 200_000, 400_000, 1_000_000]
    private static let compressPresets = [40_000, 60_000, 80_000, 120_000, 160_000, 200_000]

    /// Presets plus the profile's current value so a custom setting stays selectable.
    private static func tokenChoices(_ presets: [Int], current: Int?, zero: String) -> [(String, Int)] {
        let values = Set(presets).union(current.map { [$0] } ?? []).sorted()
        return [(zero, 0)] + values.map { (tokens($0), $0) }
    }

    @ViewBuilder
    private func limitPicker<V: Hashable>(title: String, selection: Binding<V>, options: [(String, V)]) -> some View {
        if limits == nil {
            Text("—").foregroundStyle(Color.dockMetadataText)
        } else {
            DockMenuPicker(title: title, selection: selection) {
                ForEach(options, id: \.1) { DockMenuOption($0.0, value: $0.1) }
            }
        }
    }

    private var fallbacks: [BotRuntimeConfig.ModelRef] { fallbackDraft ?? runtime?.fallbacks ?? [] }

    private func factRow<Value: View>(_ label: String, @ViewBuilder value: () -> Value) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).dockFont(.compactStatus, weight: .medium).foregroundStyle(Color.dockMetadataText)
            value().dockFont(.body).foregroundStyle(Color.dockPrimaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dockPadding(.vertical, 9)
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
        .dockPadding(12)
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

    private func toggleSection(items: Binding<[BotToggleItem]>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if items.wrappedValue.isEmpty {
                Text("None reported by Hermes").dockFont(.metadata).foregroundStyle(Color.dockMetadataText)
            } else {
                ForEach(Array(items.wrappedValue.enumerated()), id: \.element.id) { index, item in
                    Toggle(
                        item.label,
                        isOn: Binding(
                            get: { items.wrappedValue[index].enabled },
                            set: { items.wrappedValue[index].enabled = $0 }
                        )
                    )
                    .controlSize(.small)
                    .dockPadding(.horizontal, 4)
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
                                    Text(item.detail).dockFont(.compactStatus, weight: .regular).foregroundStyle(
                                        Color.dockMetadataText)
                                }
                            }
                        }
                        .controlSize(.small)
                        Spacer()
                    }
                    .dockPadding(.horizontal, 4)
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
        limits = runtime
        modelChoices = await model.modelOptions(for: bot)
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
        let prompt =
            "Friendly avatar portrait for an AI assistant named \(bot.title ?? bot.name), simple, clean, centered"
        guard let dataURL = try? await model.generateAvatar(prompt: prompt),
            let data = BotService.decodeDataURL(dataURL)
        else { return }
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
                editError = "Choose a primary model."
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

        if let edited = limits, let saved = runtime,
            (edited.reasoningEffort, edited.contextLength, edited.compressionThreshold)
                != (saved.reasoningEffort, saved.contextLength, saved.compressionThreshold)
        {
            if let message = await model.setRuntimeLimits(edited, for: bot) {
                editError = message
                return
            }
            runtime?.reasoningEffort = edited.reasoningEffort
            runtime?.contextLength = edited.contextLength
            runtime?.compressionThreshold = edited.compressionThreshold
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
        if isEmbedded {
            pendingAvatarData = nil
            clearsAvatar = false
            isChangingModel = false
            fallbackDraft = nil
            editError = nil
            await load()
        } else {
            dismiss()
        }
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
            .dockPadding(.bottom, 4)
            ForEach(0..<3, id: \.self) { _ in
                RoundedRectangle(cornerRadius: DockLayout.controlRadius - 2, style: .continuous)
                    .fill(Color.dockControlSurface)
                    .frame(height: 38)
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.dockSurface4)
                            .frame(width: 110, height: 8)
                            .dockPadding(.horizontal, 12)
                    }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 230, alignment: .topLeading)
        .dockPadding(.top, 8)
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
    @State private var partialID: String?
    @State private var admissionUnconfirmed = false

    var body: some View {
        DockModal(
            title: "Duplicate \(bot.name)",
            subtitle: "Clones config, skills, SOUL, and memory into a new profile.", width: 400
        ) {
            labeledField("New profile name", hint: "Lowercase letters, numbers, dashes, or underscores") {
                DockTextField("e.g. \(bot.name)-copy", text: $newName)
                    .textFieldStyle(.dockGlass)
            }
            if let error = model.botCreationError {
                ModalNote(text: error, icon: .warning, tone: .dockWarning)
            }
        } footer: {
            modalActions(
                primaryTitle: "Duplicate", pendingTitle: "Duplicating…",
                isDisabled: admissionUnconfirmed || !BotCreationSheet.isValidProfileName(trimmedName) || isDuplicating,
                isPending: isDuplicating, onCancel: { dismiss() }
            ) {
                Task {
                    isDuplicating = true
                    if let partialID {
                        if await model.finishBotRole(profileID: partialID, title: bot.title ?? "") { dismiss() }
                    } else if await model.duplicateBot(bot, newName: trimmedName) {
                        dismiss()
                    } else {
                        partialID = model.partialCreatedBotID
                        admissionUnconfirmed = model.creationAdmissionUnconfirmed
                    }
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
        DockModal(
            title: "New Routine", subtitle: "Recurring work a Bot runs on a schedule.", width: 440
        ) {
            modalSection("ASSIGNMENT") {
                labeledField("Bot", hint: "The profile that owns this routine") {
                    DockMenuPicker(
                        title: bots.first { $0.id == selectedProfile }?.name ?? "Choose…", selection: $selectedProfile
                    ) {
                        ForEach(bots) { DockMenuOption(bot: $0) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .dockPadding(.horizontal, 10)
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
            modalActions(
                primaryTitle: "Add Routine", isDisabled: !isValid || isSaving, isPending: isSaving,
                onCancel: { dismiss() }
            ) {
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
