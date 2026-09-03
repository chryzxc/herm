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
    @State private var keepsInheritedModel = true
    @State private var isSaving = false
    @State private var editError: String?
    @State private var pendingConfirmMessage: String?
    @State private var isGeneratingAvatar = false
    @State private var avatarPreview: Data?
    @State private var pendingAvatarData: Data?
    @State private var clearsAvatar = false
    @State private var showsSoul = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                BotAvatarView(bot: bot, imageData: avatarPreview ?? model.avatarImages[bot.id], size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(bot.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.dockPrimaryText)
                    Text("Hermes profile").font(.system(size: 11)).foregroundStyle(Color.dockMetadataText)
                }
                Spacer()
            }
            if detail == nil {
                ProgressView("Loading profile…").controlSize(.small).padding(.vertical, 20)
            } else {
                editorForm
            }
        }
        .padding(16)
        .frame(width: 460)
        .frame(minHeight: 420)
        .background(Color.dockSurface2)
        .task { await load() }
        .alert("Confirm Model", isPresented: Binding(get: { pendingConfirmMessage != nil }, set: { if !$0 { pendingConfirmMessage = nil } })) {
            Button("Cancel", role: .cancel) { pendingConfirmMessage = nil }
            Button("Use This Model") { Task { await save(confirm: true) } }
        } message: {
            Text(pendingConfirmMessage ?? "")
        }
    }

    private var editorForm: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                avatarRow
                titledField("Title") {
                    TextField("Roster title", text: Binding(get: { detail?.title ?? "" }, set: { detail?.title = $0 }))
                        .textFieldStyle(.roundedBorder)
                }
                titledField("Description") {
                    TextField("What this Bot does", text: Binding(get: { detail?.description ?? "" }, set: { detail?.description = $0 }))
                        .textFieldStyle(.roundedBorder)
                }
                modelRow
                soulRow
                toggleSection("Skills", items: skillBinding)
                toolsetSection
                toggleSection("MCP Servers", items: mcpBinding)
                if let editError {
                    Text(editError).font(.system(size: 11)).foregroundStyle(Color.dockWarning)
                }
                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button {
                        Task { await save(confirm: false) }
                    } label: {
                        if isSaving { ProgressView().controlSize(.small) } else { Text("Save") }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving)
                }
            }
        }
    }

    private var avatarRow: some View {
        HStack(spacing: 8) {
            Text("Avatar").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.dockSecondaryText).frame(width: 90, alignment: .leading)
            Button("Upload…") { uploadAvatar() }
            if model.isImageGenerationAvailable {
                Button {
                    Task { await generateAvatar() }
                } label: {
                    if isGeneratingAvatar { ProgressView().controlSize(.small) } else { Text("Generate") }
                }
                .disabled(isGeneratingAvatar)
            }
            if bot.hasAvatar || avatarPreview != nil || clearsAvatar {
                Button("Clear") {
                    pendingAvatarData = nil
                    avatarPreview = nil
                    clearsAvatar = true
                }
            }
            if clearsAvatar { Text("avatar will be removed").font(.system(size: 10)).foregroundStyle(Color.dockMetadataText) }
            Spacer()
        }
    }

    private var modelRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Model").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.dockSecondaryText).frame(width: 90, alignment: .leading)
                Toggle("Inherit from launch profile", isOn: $keepsInheritedModel)
                    .controlSize(.small)
                    .disabled(detail?.provider == nil)
            }
            if !keepsInheritedModel {
                HStack(spacing: 8) {
                    Picker("Provider", selection: $selectedProvider) {
                        Text("Provider…").tag("")
                        ForEach(modelChoices, id: \.provider) { choice in
                            Text(choice.provider).tag(choice.provider)
                        }
                    }
                    Picker("Model", selection: $selectedModel) {
                        Text("Model…").tag("")
                        ForEach(availableModels, id: \.self) { Text($0).tag($0) }
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var soulRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("SOUL.md").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.dockSecondaryText)
                Spacer()
                Button(showsSoul ? "Hide" : "Edit") { withAnimation { showsSoul.toggle() } }
                    .controlSize(.small)
            }
            if showsSoul {
                ScrollView {
                    TextEditor(text: Binding(get: { detail?.soul ?? "" }, set: { detail?.soul = $0 }))
                        .font(.system(size: 11, design: .monospaced))
                        .frame(height: 140)
                        .scrollContentBackground(.hidden)
                        .background(Color.dockCanvas)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
        }
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

    private func titledField<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.dockSecondaryText).frame(width: 90, alignment: .leading)
            content()
        }
    }

    private func toggleSection(_ title: String, items: Binding<[BotToggleItem]>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.dockSecondaryText)
            if items.wrappedValue.isEmpty {
                Text("None reported by Hermes").font(.system(size: 11)).foregroundStyle(Color.dockMetadataText)
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
            Text("Toolsets").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.dockSecondaryText)
            if toolsetBinding.wrappedValue.isEmpty {
                Text("None reported by Hermes").font(.system(size: 11)).foregroundStyle(Color.dockMetadataText)
            } else {
                ForEach(Array(toolsetBinding.wrappedValue.enumerated()), id: \.element.id) { index, item in
                    let isOn = Binding(
                        get: { toolsetBinding.wrappedValue[index].enabled },
                        set: { toolsetBinding.wrappedValue[index].enabled = $0 }
                    )
                    HStack(alignment: .firstTextBaseline) {
                        Toggle(isOn: isOn) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("\(item.label) (\(item.toolCount))").font(.system(size: 12))
                                if !item.detail.isEmpty {
                                    Text(item.detail).font(.system(size: 10)).foregroundStyle(Color.dockMetadataText)
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
        detail = await model.profileDetail(for: bot)
        if let provider = detail?.provider, !provider.isEmpty {
            keepsInheritedModel = true
            selectedProvider = provider
            selectedModel = detail?.model ?? ""
        }
        modelChoices = await model.modelOptions()
        await model.checkImageGeneration()
    }

    private func uploadAvatar() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .webP]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
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
        if keepsInheritedModel {
            current.provider = nil
            current.model = nil
        } else {
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

/// Duplicate = `profiles.create` with `clone_from`, matching Bot Mode's
/// full-clone duplication of a profile.
struct BotDuplicateSheet: View {
    @ObservedObject var model: BotModeModel
    let bot: BotSummary
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Duplicate \(bot.name)")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.dockPrimaryText)
            TextField("New profile name (lowercase)", text: $newName)
                .textFieldStyle(.roundedBorder)
            if let error = model.botCreationError {
                Text(error).font(.system(size: 11)).foregroundStyle(Color.dockWarning)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Duplicate") {
                    Task {
                        if await model.duplicateBot(bot, newName: trimmedName) { dismiss() }
                    }
                }
                .disabled(!BotCreationSheet.isValidProfileName(trimmedName))
            }
        }
        .padding(16)
        .frame(width: 340)
        .background(Color.dockSurface2)
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
        VStack(alignment: .leading, spacing: 16) {
            modalHeader(title: "New Routine", eyebrow: "AUTOMATION / ROUTINE")

            modalSection("ASSIGNMENT") {
                labeledField("Bot", hint: "The profile that owns this routine") {
                    Picker("Bot", selection: $selectedProfile) {
                        ForEach(bots) { bot in Text(bot.name).tag(bot.id) }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .frame(minHeight: DockLayout.controlHeight)
                    .background(
                        RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous)
                            .fill(Color.dockControlSurface)
                            .stroke(Color.dockBorder, lineWidth: 0.5)
                    )
                }
            }

            modalSection("SCHEDULE") {
                labeledField("Title", hint: "A short name for the recurring work") {
                    TextField("e.g. Summarize inbox", text: $title)
                        .textFieldStyle(.dockGlass)
                }
                labeledField("Schedule", hint: "Use a plain-language interval") {
                    TextField("e.g. every day 9am", text: $schedule)
                        .textFieldStyle(.dockGlass)
                }
                labeledField("Prompt", hint: "Instructions sent to the Bot") {
                    TextField("What should this routine do?", text: $prompt)
                        .textFieldStyle(.dockGlass)
                }
            }

            if let error = model.botCreationError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dockWarning)
                    .lineLimit(3)
            }
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
        .padding(20)
        .frame(width: 420)
        .background(Color.dockSurface2)
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
