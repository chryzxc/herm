import AppKit
import Foundation
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

extension WorkspaceActivitySidebar {
    // Bound the category tuple before the parent copies it; the unbounded view
    // crashes Settings construction in debug builds (SettingsConstructionTests).
    var coreContent: AnyView {
        let content = VStack(alignment: .leading, spacing: 17) {
            if selectedSettingsCategory == .general {
                SettingsSection(title: "Set up Herm", subtitle: "", tint: .dockAccent) {
                    SettingsPreferenceRow(
                        title: "Welcome guide", detail: "Bots, notch position, skins, and Apple Intelligence."
                    ) {
                        Button("Set up Herm") { HermDelegate.current?.showOnboarding() }
                            .buttonStyle(.dockSecondary)
                    }
                }
                generalPreferencesSection
                powerPreferencesSection
            }
            if selectedSettingsCategory == .gateway {
                GatewayConnectionSettingsView(onRestart: onRestartDock)
                SettingsSection(title: "Messaging gateway", subtitle: "Service on this Mac", tint: .dockAccent) {
                    HermesGatewaySettingsView(service: control.gatewayService)
                }
            }
            if selectedSettingsCategory == .notifications {
                notificationPreferencesSection
            }
            if selectedSettingsCategory == .appearance {
                SettingsSection(title: "Theme", subtitle: "Colors and skins", tint: .dockAccent) {
                    appearanceSection
                }
                SettingsSection(title: "Density", subtitle: "", tint: .dockAccent) {
                    DensitySettings()
                        .dockPadding(.vertical, -8)
                }
                SettingsSection(title: "Notch", subtitle: "Activity indicator", tint: .dockAccent) {
                    NotchDisplaySettings()
                }
                SettingsSection(title: "Herm companion", subtitle: "", tint: .dockAccent) {
                    HermesPetSettingsView(pet: control.pet)
                }
            }
            if selectedSettingsCategory == .chat {
                SettingsSection(title: "Layout", subtitle: "", tint: .dockAccent) {
                    ChatViewSettings()
                        .dockPadding(.vertical, -8)
                }
                SettingsSection(title: "Typing", subtitle: "", tint: .dockAccent) {
                    ComposerTypingSettings()
                        .dockPadding(.vertical, -8)
                }
                SettingsSection(title: "Replies", subtitle: "Visual content", tint: .dockAccent) {
                    GenerativeUISettings()
                        .dockPadding(.vertical, -8)
                }
                SettingsSection(title: "Simulators", subtitle: "Device launch", tint: .dockAccent) {
                    SimulatorSettings()
                        .dockPadding(.vertical, -8)
                }
                chatAssistancePreferencesSection
                chatQuotaPreferencesSection
            }
            if selectedSettingsCategory == .safety {
                privacyPreferencesSection
                SettingsSection(title: "Window capture", subtitle: "", tint: .dockAccent) {
                    DesktopCaptureSettings()
                        .dockPadding(.vertical, -8)
                }
                approvalPreferencesSection
            }
            if selectedSettingsCategory == .voice {
                SettingsSection(title: "Turn detection", subtitle: "When to reply", tint: .dockAccent) {
                    TurnModelSettingsView(store: .shared)
                }
                SettingsSection(title: "Voice stage", subtitle: "", tint: .dockAccent) {
                    VoiceStageSettings()
                        .dockPadding(.vertical, -8)
                }
            }
            if selectedSettingsCategory == .updates {
                settingsDisclosure(
                    title: "Herm update", subtitle: "Herm \(appUpdater.currentVersion ?? "dev build")",
                    icon: .arrowsClockwise, isExpanded: $isAppUpdateExpanded
                ) {
                    appUpdateSection
                }
                settingsDisclosure(
                    title: "Agent update", subtitle: "Version and updates", icon: .arrowsClockwise,
                    isExpanded: $isAgentUpdateExpanded
                ) {
                    agentUpdateSection
                }
            }

            if selectedSettingsCategory == .runtime {
                runtimeSettingsSection
                SettingsSection(
                    title: "Mixture of Agents", subtitle: "Advisor models and aggregator", tint: .dockAccent
                ) {
                    MoASettingsView(model: model, service: control.rpc?.workflow(profileID: model.profileScopeID))
                }
            }

            if selectedSettingsCategory == .providers {
                ProvidersSettingsView(model: model, control: control)
            }

            if selectedSettingsCategory == .browser {
                SettingsSection(title: "Agent browsing", subtitle: "Where pages open", tint: .dockAccent) {
                    HermBrowserSettings()
                        .dockPadding(.vertical, -8)
                }
            }

            HermesConfigCategoryView(editor: control.configEditor, category: selectedSettingsCategory)

            if selectedSettingsCategory == .diagnostics, let insights = control.insightsSummary {
                settingsDisclosure(
                    title: "Usage insights", subtitle: "Last \(insights.days) days", icon: .chartBar,
                    isExpanded: $isInsightsExpanded
                ) {
                    VStack(alignment: .leading, spacing: 8) {
                        diagnosticRow(label: "Sessions", value: "\(insights.sessions)", color: Color.dockMetadataText)
                        diagnosticRow(label: "Messages", value: "\(insights.messages)", color: .dockMetadataText)
                    }
                }
            }

            if selectedSettingsCategory == .runtime {
                SettingsSection(title: "Dispatch", subtitle: "Pause or resume new work", tint: .dockAccent) {
                    emergencyStopSection
                }
            }

            if selectedSettingsCategory == .integrations, !unavailableSetupCapabilities.isEmpty {
                settingsDisclosure(
                    title: "Setup needed",
                    subtitle: "\(unavailableSetupCapabilities.count) integrations need attention", icon: .warning,
                    isExpanded: $isSetupExpanded, tint: .dockWarning
                ) {
                    ForEach(unavailableSetupCapabilities) { capability in
                        providerSetupCard(capability)
                    }
                }
            }

            if selectedSettingsCategory == .integrations {
                settingsDisclosure(
                    title: "Capabilities", subtitle: "Permission and integration readiness", icon: .shieldCheck,
                    isExpanded: $isCapabilitiesExpanded
                ) {
                    projectionRefreshNotice("core")
                    capabilityInventorySummary
                    if capabilityInventorySnapshot.states.isEmpty {
                        emptyState(
                            icon: .arrowsClockwise,
                            title: "Settings capabilities not yet available",
                            detail: "Refresh Settings or reconnect Hermes to request capability facts."
                        )
                    } else {
                        ForEach(CapabilityCategory.allCases, id: \.self) { category in
                            let states = capabilityStates(for: category)
                            if !states.isEmpty {
                                settingsCategoryDisclosure(
                                    title: category.rawValue.uppercased(), count: states.count,
                                    readyCount: states.filter { $0.probeState == .verified }.count,
                                    isExpanded: capabilityCategoryExpansionBinding(for: category)
                                ) {
                                    VStack(alignment: .leading, spacing: 12) {
                                        ForEach(states) { capability in
                                            capabilityStatusRow(capability)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            let canSteerSession = model.status == .working && model.sessionID != nil
            if selectedSettingsCategory == .session,
                control.sessionUsage != nil || control.sessionContext != nil || canSteerSession
                    || !control.restoreCheckpoints.isEmpty || control.isLoadingCheckpoints
            {
                settingsDisclosure(
                    title: "Session cockpit", subtitle: "Context, usage, and active-turn controls", icon: .pulse,
                    isExpanded: $isSessionCockpitExpanded
                ) {
                    if let usage = control.sessionUsage {
                        diagnosticRow(
                            label: "Tokens",
                            value:
                                "\(usage.totalTokens) total  ·  \(usage.inputTokens) in  ·  \(usage.outputTokens) out",
                            color: Color.dockMetadataText)
                        if let model = usage.model {
                            diagnosticRow(label: "Model", value: model, color: Color.dockMetadataText)
                        }
                    }
                    if let context = control.sessionContext {
                        if let percent = context.contextPercent {
                            diagnosticRow(
                                label: "Context", value: String(format: "%.1f%%", percent),
                                color: percent >= 90
                                    ? Color.dockDestructive
                                    : percent >= 80 ? Color.dockWarning : Color.dockSecondaryText)
                        }
                        if !context.categories.isEmpty {
                            ForEach(context.categories.prefix(6)) { category in
                                diagnosticRow(
                                    label: category.label.uppercased(), value: "\(category.tokens) tokens",
                                    color: Color.dockMetadataText)
                            }
                        }
                    }
                    let pressure = SessionContextPressure.make(percent: control.sessionContext?.contextPercent)
                    if pressure != .unavailable {
                        let color: Color =
                            pressure == .critical
                            ? .dockDestructive : pressure == .warning ? .dockWarning : .dockSecondaryText
                        diagnosticRow(label: "Context pressure", value: pressure.rawValue.uppercased(), color: color)
                        if pressure == .warning || pressure == .critical {
                            Text(
                                "Create a handoff or branch before context pressure grows. Compression remains an explicit confirmed action."
                            )
                            .dockFont(.metadata).foregroundStyle(Color.dockMetadataText)
                            HStack(spacing: 8) {
                                DockTextField("Handoff focus (optional)", text: $handoffFocus).textFieldStyle(
                                    .dockGlass)
                                Button("Handoff") { isShowingHandoffConfirmation = true }
                                    .buttonStyle(.dockCompact).foregroundStyle(Color.dockAccent)
                                    .disabled(!control.capabilityAvailable("gateway"))
                            }
                        }
                    }
                    if control.isLoadingCheckpoints {
                        Text("Loading session checkpoints…")
                            .dockFont(.metadata).foregroundStyle(Color.dockMetadataText)
                    } else if !control.restoreCheckpoints.isEmpty {
                        Text("CHECKPOINTS")
                            .dockFont(.compactStatus, weight: .semibold).foregroundStyle(Color.dockSecondaryText)
                        ForEach(control.restoreCheckpoints) { checkpoint in
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(checkpoint.message.isEmpty ? checkpoint.hash : checkpoint.message)
                                        .dockFont(.metadata, weight: .semibold).foregroundStyle(Color.dockPrimaryText)
                                        .lineLimit(1)
                                    Text(checkpoint.timestamp.isEmpty ? checkpoint.hash : checkpoint.timestamp)
                                        .dockFont(.compactStatus, weight: .regular).foregroundStyle(
                                            Color.dockMetadataText
                                        ).lineLimit(1)
                                }
                                Spacer()
                                Button("Diff") { control.loadCheckpointDiff(checkpoint) }
                                    .buttonStyle(.dockCompact).dockFont(.compactStatus, weight: .semibold)
                                    .foregroundStyle(Color.dockAccent)
                                Button("Restore", role: .destructive) { checkpointForRestore = checkpoint }
                                    .buttonStyle(.dockCompact).dockFont(.compactStatus, weight: .semibold)
                                    .foregroundStyle(Color.dockDestructive)
                                    .disabled(model.status == .working || control.restoreCheckpointState.isPending)
                            }
                        }
                        if let checkpointDiff = control.checkpointDiff, !checkpointDiff.isEmpty {
                            Text(checkpointDiff)
                                .dockFont(.compactStatus, weight: .regular, design: .monospaced).foregroundStyle(
                                    Color.dockMetadataText
                                )
                                .lineLimit(12)
                                .textSelection(.enabled)
                        }
                    }
                    if canSteerSession, let sessionID = model.sessionID {
                        Text(
                            "Hermes will apply this guidance after the next tool-result boundary without restarting the turn."
                        )
                        .dockFont(.metadata).foregroundStyle(Color.dockMetadataText)
                        HStack(spacing: 8) {
                            DockTextField("Steer the active turn…", text: $sessionSteerText)
                                .textFieldStyle(.dockGlass)
                            DockAsyncButton("Steer") {
                                let text = sessionSteerText
                                guard let result = await control.steerActiveSession(text) else { return }
                                if result.wasAccepted {
                                    sessionSteerText = ""
                                    sessionSteerFeedback = "GUIDANCE QUEUED"
                                } else {
                                    sessionSteerFeedback = "GUIDANCE REJECTED — text retained"
                                }
                            }
                            .buttonStyle(.dockCompact)
                            .foregroundStyle(Color.dockAccent)
                            .disabled(
                                sessionSteerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    || control.isActionPending(control.sessionSteerActionID(sessionID)))
                        }
                        if let sessionSteerFeedback {
                            Text(sessionSteerFeedback)
                                .dockFont(.compactStatus, weight: .semibold)
                                .foregroundStyle(
                                    sessionSteerFeedback.contains("REJECTED")
                                        ? Color.dockWarning : Color.dockSecondaryText)
                        }
                    }
                }
            }
            if selectedSettingsCategory == .session, let budget = control.promptBudget {
                SettingsSection(
                    title: "Prompt budget", subtitle: "Tokens sent with the next request", tint: .dockAccent
                ) {
                    let percent = budget.percent ?? 0
                    let color: Color = percent >= 95 ? .dockDestructive : (percent >= 85 ? .dockWarning : .dockAccent)
                    diagnosticRow(
                        label: "Tokens", value: "\(budget.totalTokens)" + (budget.tokenLimit.map { " / \($0)" } ?? ""),
                        color: color)
                    if budget.percent != nil {
                        diagnosticRow(label: "Used", value: String(format: "%.1f%%", percent), color: color)
                    }
                    if let model = budget.model {
                        diagnosticRow(label: "Model", value: model, color: Color.dockMetadataText)
                    }
                }
            }
            if selectedSettingsCategory == .session {
                settingsDisclosure(
                    title: "Session actions", subtitle: "Rename, redirect, branch, or pause the active session",
                    icon: .lightning, isExpanded: $isSessionActionsExpanded
                ) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            DockTextField("New session title", text: $sessionRenameText)
                                .textFieldStyle(.dockGlass)
                            DockAsyncButton("Rename") {
                                if await control.renameActiveSession(sessionRenameText) { sessionRenameText = "" }
                            }
                            .buttonStyle(.dockCompact)
                            .foregroundStyle(Color.dockAccent)
                            .disabled(sessionRenameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        HStack(spacing: 8) {
                            DockTextField("Redirect the active turn…", text: $sessionRedirectText)
                                .textFieldStyle(.dockGlass)
                            DockAsyncButton("Redirect") {
                                let text = sessionRedirectText
                                if let result = await control.redirectActiveSession(text), result.wasAccepted {
                                    sessionRedirectText = ""
                                }
                            }
                            .buttonStyle(.dockCompact)
                            .foregroundStyle(Color.dockAccent)
                            .disabled(sessionRedirectText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        HStack(spacing: 8) {
                            DockTextField("Optional branch name", text: $sessionBranchName)
                                .textFieldStyle(.dockGlass)
                            Button("Branch") { isShowingBranchConfirmation = true }
                                .buttonStyle(.dockCompact)
                                .foregroundStyle(Color.dockAccent)
                                .disabled(!control.capabilityAvailable("rpc-sessions"))
                            DockTextField("Compression focus (optional)", text: $sessionCompressTopic)
                                .textFieldStyle(.dockGlass)
                            Button("Compress") { isShowingCompressConfirmation = true }
                                .buttonStyle(.dockCompact)
                                .foregroundStyle(Color.dockAccent)
                                .disabled(!control.capabilityAvailable("rpc-sessions"))
                        }
                        HStack(spacing: 8) {
                            Button("Undo last turn") { isShowingUndoConfirmation = true }
                                .buttonStyle(.dockCompact)
                                .foregroundStyle(Color.dockWarning)
                            Button(control.delegationPaused ? "Resume delegation" : "Pause delegation") {
                                isShowingDelegationConfirmation = true
                            }
                            .buttonStyle(.dockCompact)
                            .foregroundStyle(Color.dockWarning)
                        }
                    }
                    .dockFont(.body, weight: .semibold)
                    .foregroundStyle(Color.dockAccent)
                }
            }
            if selectedSettingsCategory == .session, !control.activeAgents.isEmpty || !control.processes.isEmpty {
                SettingsSection(title: "Running work", subtitle: "Subagents and processes", tint: .dockAccent) {
                    ForEach(control.activeAgents) { agent in
                        HStack {
                            DockIcon(.users).foregroundStyle(Color.dockAccent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(agent.name).foregroundStyle(Color.dockPrimaryText)
                                Text(agent.state.uppercased()).foregroundStyle(Color.dockMetadataText)
                            }
                            Spacer()
                            if let native = model.activeSubagents.first(where: { $0.id == agent.id }),
                                !model.isSyntheticSubagent(native.id)
                            {
                                Button("Interrupt") { pendingAgentID = native.id }
                                    .buttonStyle(.dockCompact)
                                    .foregroundStyle(Color.dockWarning)
                            }
                        }
                        .dockFont(.metadata)
                    }
                    ForEach(control.processes) { process in
                        HStack {
                            DockIcon(.gearSix).foregroundStyle(Color.dockSecondaryText)
                            Text(process.name).foregroundStyle(Color.dockPrimaryText)
                            Spacer()
                            Button("Stop") { pendingProcess = control.processStopConfirmation(process) }
                                .buttonStyle(.dockCompact)
                                .foregroundStyle(Color.dockWarning)
                        }
                        .dockFont(.metadata)
                    }
                }
            }
            if selectedSettingsCategory == .diagnostics, !control.diagnostics.isEmpty {
                settingsDisclosure(
                    title: "Read-only diagnostics", subtitle: "Observed runtime detail", icon: .stethoscope,
                    isExpanded: $isDiagnosticsExpanded
                ) {
                    ForEach(control.diagnostics) { diagnostic in
                        HStack(alignment: .top, spacing: 8) {
                            Circle()
                                .fill(diagnostic.isAvailable ? Color.dockSecondaryText : Color.dockWarningFill)
                                .frame(width: 6, height: 6)
                                .dockPadding(.top, 4)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(diagnostic.title)
                                    .dockFont(.body, weight: .medium)
                                    .foregroundStyle(Color.dockPrimaryText)
                                Text(diagnostic.detail)
                                    .dockFont(.body)
                                    .foregroundStyle(Color.dockMetadataText)
                                    .lineLimit(3)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
            if selectedSettingsCategory == .diagnostics,
                !control.journeyNodes.isEmpty || control.sessionStoreStatus != nil || control.memoryHealthStatus != nil
            {
                settingsDisclosure(
                    title: "Learning & storage", subtitle: "Session store, memory, and journey state", icon: .hardDrive,
                    isExpanded: $isLearningExpanded
                ) {
                    ForEach([control.sessionStoreStatus, control.memoryHealthStatus].compactMap { $0 }) { status in
                        diagnosticRow(
                            label: status.title.uppercased(), value: status.detail,
                            color: status.isAvailable ? Color.dockSecondaryText : Color.dockWarning)
                    }
                    if !control.journeyNodes.isEmpty {
                        Text("JOURNEY  ·  \(control.journeyNodes.count) NODES")
                            .dockFont(.metadata, weight: .semibold)
                            .foregroundStyle(Color.dockMetadataText)
                        ForEach(control.journeyNodes.prefix(8)) { node in
                            HStack(spacing: 7) {
                                Circle().fill(
                                    node.state == "active" ? Color.dockSecondaryText : Color.dockSecondaryText
                                ).frame(width: 5, height: 5)
                                Text(node.label).dockFont(.body).foregroundStyle(Color.dockPrimaryText).lineLimit(1)
                                Spacer()
                                Text(
                                    [node.kind, node.useCount.map { "\($0)x" }].compactMap { $0 }.joined(
                                        separator: " · ")
                                )
                                .dockFont(.metadata).foregroundStyle(Color.dockMetadataText)
                            }
                        }
                    }
                }
            }
            if selectedSettingsCategory == .session,
                control.sessionUsage == nil,
                control.sessionContext == nil,
                control.restoreCheckpoints.isEmpty,
                control.activeAgents.isEmpty,
                control.processes.isEmpty,
                model.sessionID == nil
            {
                emptyState(
                    icon: .pulse, title: "Session data unavailable",
                    detail: "Open a Hermes session or refresh Settings to load session controls.")
            }
            if selectedSettingsCategory == .diagnostics,
                control.insightsSummary == nil,
                control.diagnostics.isEmpty,
                control.journeyNodes.isEmpty,
                control.sessionStoreStatus == nil,
                control.memoryHealthStatus == nil
            {
                emptyState(
                    icon: .stethoscope, title: "Diagnostics unavailable",
                    detail: "Refresh Settings or reconnect Hermes to request read-only diagnostics.")
            }
        }
        .task {
            control.configEditor.onSaved = { model.refreshRuntimeConfiguration(force: true) }
        }
        .onChange(of: model.runtimeConfiguration) { _, configuration in
            guard let configuration,
                let matching = model.runtimeModelOptions.first(where: {
                    $0.model == configuration.model && $0.provider == configuration.provider
                })
            else { return }
            selectedModelID = matching.id
        }
        .onChange(of: model.runtimeModelOptions) { _, options in
            guard let configuration = model.runtimeConfiguration else { return }
            let matching = options.first { option in
                option.model == configuration.model && option.provider == configuration.provider
            }
            guard let matching else { return }
            selectedModelID = matching.id
        }
        return AnyView(content)
    }

    var runtimeSettingsSection: some View {
        settingsDisclosure(
            title: "Runtime configuration", subtitle: "Default model, tools, skills, and plugins", icon: .gearSix,
            isExpanded: $isRuntimeConfigurationExpanded
        ) {
            HStack {
                settingsSubheading("Default model")
                Spacer()
                Button(action: { model.refreshRuntimeConfiguration(force: true) }) {
                    if model.isLoadingRuntimeConfiguration {
                        ProgressView().controlSize(.small).tint(Color.dockAccent)
                    } else {
                        DockIcon(.arrowsClockwise)
                            .dockFont(.body, weight: .medium)
                            .foregroundStyle(Color.dockAccent)
                    }
                }
                .buttonStyle(.dockHover)
                .disabled(model.isLoadingRuntimeConfiguration)
            }

            if model.isLoadingRuntimeConfiguration && model.runtimeConfiguration == nil {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text("READING HERMES RUNTIME…").dockFont(.body).tracking(0.6).foregroundStyle(
                        Color.dockSecondaryText)
                }
            } else if let configuration = model.runtimeConfiguration {
                diagnosticRow(
                    label: "Model", value: configuration.model ?? "Not configured",
                    color: configuration.model == nil ? Color.dockWarning : Color.dockSecondaryText)
                diagnosticRow(
                    label: "Provider", value: configuration.provider ?? "Not configured",
                    color: configuration.provider == nil ? Color.dockWarning : Color.dockSecondaryText)
                if model.runtimeModelOptions.isEmpty {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.small)
                        Text("LOADING HERMES MODEL CATALOG…").dockFont(.body).tracking(0.5).foregroundStyle(
                            Color.dockSecondaryText)
                    }
                } else {
                    DockMenu {
                        ForEach(model.runtimeModelOptions) { option in
                            Button {
                                selectedModelID = option.id
                            } label: {
                                HStack {
                                    Text(option.displayName)
                                    if option.id == selectedModelID {
                                        Ph.check.image()
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Text(selectedModelDisplayName)
                                .dockFont(.body, weight: .medium)
                                .foregroundStyle(Color.dockPrimaryText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 4)
                            DockIcon(.caretUpDown)
                                .dockFont(.body, weight: .semibold)
                                .foregroundStyle(Color.dockSecondaryText)
                        }
                        .dockPadding(.horizontal, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: 36)
                        .background(
                            RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous)
                                .dockSurfaceFill(Color.dockControlSurface)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous).stroke(
                                Color.dockBorder, lineWidth: 0.5)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous))
                    }
                    .buttonStyle(.dockHover)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .disabled(model.isLoadingRuntimeConfiguration)
                    .onChange(of: selectedModelID) { _, id in
                        guard let option = model.runtimeModelOptions.first(where: { $0.id == id }),
                            option.model != configuration.model || option.provider != configuration.provider
                        else { return }
                        model.updateRuntimeModel(option)
                    }
                }
                DockMenu {
                    DockMenuChoices(
                        selection: Binding(
                            get: { model.defaultReasoningVariant },
                            set: { variant in
                                guard let variant, variant != model.defaultReasoningVariant else { return }
                                model.updateGlobalReasoning(variant)
                            }
                        )
                    ) {
                        ForEach(HermesReasoningVariant.allCases) { variant in
                            DockMenuOption(variant.displayName, value: Optional(variant))
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        DockIcon(.brain, size: 13, color: Color.dockSecondaryText)
                        Text("Thinking  ·  \(model.defaultReasoningVariant?.displayName ?? "Loading…")")
                            .dockFont(.body, weight: .medium)
                            .foregroundStyle(Color.dockPrimaryText)
                        Spacer(minLength: 4)
                        DockIcon(.caretUpDown)
                            .dockFont(.body, weight: .semibold)
                            .foregroundStyle(Color.dockSecondaryText)
                    }
                    .dockPadding(.horizontal, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 36)
                    .background(
                        RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous).dockSurfaceFill(
                            Color.dockControlSurface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous).stroke(
                            Color.dockBorder, lineWidth: 0.5)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous))
                }
                .buttonStyle(.dockHover)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("Default thinking level")
                Text(
                    "Selection updates the saved default for new sessions. Use the session model picker in the chat header to override one conversation. During a running turn, Hermes applies changes to the next turn."
                )
                .dockFont(.body)
                .foregroundStyle(Color.dockMetadataText)
                if let error = model.runtimeConfigurationError {
                    Text(error)
                        .dockFont(.body)
                        .foregroundStyle(Color.dockWarning)
                }
                if let path = configuration.configPath {
                    Text(path)
                        .dockFont(.body)
                        .foregroundStyle(Color.dockMetadataText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Divider().overlay(Color.dockBorderLight)
                settingsSubheading("EXECUTION")
                if let turns = configuration.maxTurns {
                    diagnosticRow(label: "Max turns", value: turns, color: Color.dockSecondaryText)
                }
                if let timeout = configuration.terminalTimeout {
                    diagnosticRow(label: "Terminal timeout", value: "\(timeout)S", color: Color.dockSecondaryText)
                }

                Divider().overlay(Color.dockBorderLight)
                settingsSubheading("INSTALLED SKILLS  ·  \(configuration.skills.count)")
                configurationList(
                    configuration.skills,
                    empty: "No enabled skills reported by Hermes.",
                    isExpanded: isShowingAllSkills,
                    onToggle: { isShowingAllSkills.toggle() }
                )

                Divider().overlay(Color.dockBorderLight)
                settingsSubheading(
                    "MCP SERVERS  ·  \(control.mcpInventoryAvailable ? control.mcpServers.count : configuration.mcpServers.count)"
                )
                if control.mcpInventoryAvailable {
                    if control.mcpServers.isEmpty {
                        Text("No MCP servers configured in Hermes.")
                            .dockFont(.body)
                            .foregroundStyle(Color.dockMetadataText)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(control.mcpServers) { server in
                                HStack(alignment: .top, spacing: 8) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(server.name)
                                            .dockFont(.body, weight: .semibold)
                                            .foregroundStyle(Color.dockPrimaryText)
                                        Text(
                                            server.tools == "all"
                                                ? server.transport : "\(server.transport)  ·  \(server.tools)"
                                        )
                                        .dockFont(.body)
                                        .foregroundStyle(Color.dockMetadataText)
                                        .lineLimit(2)
                                    }
                                    Spacer(minLength: 0)
                                    VStack(alignment: .trailing, spacing: 4) {
                                        Text(server.isEnabled ? "Enabled" : "Disabled")
                                            .dockFont(.body)
                                            .foregroundStyle(Color.dockSecondaryText)
                                        if control.capabilityAvailable("mcp.test") {
                                            Button {
                                                control.testMCP(server)
                                            } label: {
                                                DockActionLabel(
                                                    title: "Test",
                                                    pendingTitle: "Testing…",
                                                    isPending: control.isActionPending(control.mcpTestActionID(server))
                                                )
                                            }
                                            .buttonStyle(.dockCompact)
                                            .dockFont(.body, weight: .semibold)
                                            .foregroundStyle(Color.dockAccent)
                                            .disabled(control.isActionPending(control.mcpTestActionID(server)))
                                        }
                                    }
                                }
                                if let result = control.mcpTestResults[server.id] {
                                    Text(result)
                                        .dockFont(.body)
                                        .foregroundStyle(Color.dockMetadataText)
                                        .lineLimit(2)
                                }
                            }
                        }
                    }
                } else {
                    configurationList(configuration.mcpServers, empty: "No MCP servers configured in Hermes.")
                }
                if model.sessionID != nil {
                    Button {
                        isShowingMCPReloadConfirmation = true
                    } label: {
                        DockActionLabel(
                            title: "Reload MCP tools",
                            pendingTitle: "Reloading…",
                            isPending: control.isActionPending(control.reloadMCPActionID)
                        )
                    }
                    .buttonStyle(.dockCompact)
                    .dockFont(.body, weight: .semibold)
                    .foregroundStyle(Color.dockAccent)
                    .disabled(control.isActionPending(control.reloadMCPActionID))
                }

                Divider().overlay(Color.dockBorderLight)
                settingsSubheading("COMMAND ALLOWLIST  ·  \(control.commandAllowlistEntries?.count ?? 0)")
                if let entries = control.commandAllowlistEntries {
                    if entries.isEmpty {
                        Text("No always-allowed commands.")
                            .dockFont(.body)
                            .foregroundStyle(Color.dockMetadataText)
                    } else {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(entries, id: \.self) { pattern in
                                Text(pattern)
                                    .dockFont(.metadata, weight: .regular, design: .monospaced)
                                    .foregroundStyle(Color.dockPrimaryText)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    Text("Edit in Safety → Command Allowlist.")
                        .dockFont(.metadata)
                        .foregroundStyle(Color.dockMetadataText)
                        .textSelection(.enabled)
                } else {
                    Text("Command allowlist is temporarily unavailable.")
                        .dockFont(.body)
                        .foregroundStyle(Color.dockMetadataText)
                }

                if !configuration.plugins.isEmpty {
                    Divider().overlay(Color.dockBorderLight)
                    settingsSubheading("ENABLED PLUGINS  ·  \(configuration.plugins.count)")
                    configurationList(configuration.plugins, empty: "")
                }
            } else {
                emptyState(
                    icon: .warning, title: "Runtime unavailable",
                    detail: "Hermes configuration could not be read. Start Hermes, then refresh.")
            }
        }
        .task {
            model.refreshRuntimeConfiguration()
            model.refreshRuntimeModelOptions()
            model.refreshDefaultReasoningVariant()
        }
    }

    var generalPreferencesSection: some View {
        VStack(alignment: .leading, spacing: 17) {
            SettingsSection(title: "Restart", subtitle: "Herm app", tint: .dockAccent) {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Circle().fill(Color.dockSuccessFill).frame(width: 7, height: 7).accessibilityHidden(true)
                            Text("Herm")
                                .dockFont(.body, weight: .semibold)
                                .foregroundStyle(Color.dockPrimaryText)
                            Spacer(minLength: 0)
                            Button {
                                isShowingDockRestartConfirmation = true
                            } label: {
                                Text("Restart Herm").frame(width: 140)
                            }
                            .buttonStyle(.dockSecondary)
                            .dockFont(.body, weight: .medium)
                            .disabled(agentUpdateService.isBusy)
                        }
                        Text("Relaunches the app and reloads the selected Codex account.")
                            .dockFont(.body)
                            .foregroundStyle(Color.dockSecondaryText)
                    }
                }
            }
            .confirmationDialog("Restart Herm?", isPresented: $isShowingDockRestartConfirmation) {
                Button("Restart Herm", role: .destructive) { onRestartDock() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(
                    "This closes the current Hermes backend and relaunches Herm. Unsaved draft text and the current session view will be cleared; the next chat will load the currently selected Codex account and global model."
                )
            }
            SettingsSection(title: "Startup", subtitle: "", tint: .dockAccent) {
                VStack(alignment: .leading, spacing: 0) {
                    SettingsPreferenceRow(
                        title: "Open at login", detail: "Start Herm automatically when you sign in to this Mac."
                    ) {
                        settingsSwitch(
                            isOn: Binding(
                                get: { opensAtLogin },
                                set: { on in
                                    do {
                                        if on {
                                            try SMAppService.mainApp.register()
                                        } else {
                                            try SMAppService.mainApp.unregister()
                                        }
                                    } catch {
                                        DockActionErrorCenter.shared.report(
                                            "Could not change Open at login", error: error)
                                    }
                                    opensAtLogin = SMAppService.mainApp.status == .enabled
                                }
                            ))
                    }
                }
                .dockPadding(.vertical, -8)
                .onAppear { opensAtLogin = SMAppService.mainApp.status == .enabled }
            }
            SettingsSection(title: "Keyboard shortcuts", subtitle: "", tint: .dockAccent) {
                VStack(alignment: .leading, spacing: 0) {
                    SettingsPreferenceRow(
                        title: "Open workspace",
                        detail:
                            "Open or hide the workspace from any app. It reopens compact or fullscreen, whichever you used last."
                    ) {
                        shortcutPicker($workspaceShortcut, excluding: notchShortcut)
                    }
                    Divider().overlay(Color.dockBorderLight)
                    SettingsPreferenceRow(
                        title: "Notch quick view", detail: "Peek at tasks and quota in the notch from any app."
                    ) {
                        shortcutPicker($notchShortcut, excluding: workspaceShortcut)
                    }
                    Divider().overlay(Color.dockBorderLight)
                    SettingsPreferenceRow(
                        title: "Quick capture",
                        detail:
                            "Open a new message in the notch from any app. If nothing happens, another app is using the chord."
                    ) {
                        DockOptionPicker(
                            selection: $captureChord,
                            options: QuickCaptureChord.allCases.filter { $0 == .off || $0 != windowCaptureChord }
                                .map { ($0, $0.title) }
                        ).accessibilityLabel("Quick capture")
                    }
                    Divider().overlay(Color.dockBorderLight)
                    SettingsPreferenceRow(
                        title: "Capture window",
                        detail: "Capture the foreground window into a draft for review. Unassigned by default."
                    ) {
                        DockOptionPicker(
                            selection: $windowCaptureChord,
                            options: QuickCaptureChord.allCases.filter { $0 == .off || $0 != captureChord }
                                .map { ($0, $0.title) }
                        ).accessibilityLabel("Capture window")
                    }
                }
                .dockPadding(.vertical, -8)
            }
        }
    }

    var notificationPreferencesSection: some View {
        SettingsSection(title: "Notifications", subtitle: "", tint: .dockAccent) {
            VStack(alignment: .leading, spacing: 0) {
                SettingsPreferenceRow(
                    title: "Completion alerts", detail: "Notify when a request finishes while Herm is hidden."
                ) {
                    settingsSwitch(
                        isOn: Binding(
                            get: { model.completionNotificationsEnabled },
                            set: { model.setCompletionNotificationsEnabled($0) }
                        ))
                }
                Divider().overlay(Color.dockBorderLight)
                SettingsPreferenceRow(
                    title: "Repository watch notifications", detail: "Notify when watched repository state changes."
                ) {
                    settingsSwitch(
                        isOn: Binding(
                            get: { commandCenterPreferences.repositoryNotificationsEnabled },
                            set: { enabled in
                                commandCenterPreferences.setRepositoryNotificationsEnabled(enabled)
                                workflow.setRepositoryNotificationsEnabled(enabled)
                            }
                        ))
                }
            }
            .dockPadding(.vertical, -8)
        }
    }

    var privacyPreferencesSection: some View {
        SettingsSection(title: "Privacy", subtitle: "", tint: .dockAccent) {
            VStack(alignment: .leading, spacing: 0) {
                SettingsPreferenceRow(
                    title: "Hide notch from screen sharing",
                    detail: "Keep the notch and floating panel out of screen shares and recordings."
                ) {
                    settingsSwitch(isOn: $hidesFromScreenSharing)
                }
                Divider().overlay(Color.dockBorderLight)
                SettingsPreferenceRow(
                    title: "Show sessions in Spotlight",
                    detail:
                        "Search session titles and short previews from Spotlight and open them in Herm. Titles and previews are stored in Spotlight's index on this Mac; turning this off removes them."
                ) {
                    settingsSwitch(isOn: $showsSessionsInSpotlight)
                }
            }
            .dockPadding(.vertical, -8)
        }
    }

    var approvalPreferencesSection: some View {
        SettingsSection(title: "Approval assistance", subtitle: "", tint: .dockAccent) {
            VStack(alignment: .leading, spacing: 0) {
                SettingsPreferenceRow(
                    title: "Require Touch ID for broad approvals",
                    detail: "Ask for Touch ID or your password before \"for session\" or \"always allow\" approvals."
                ) {
                    settingsSwitch(isOn: $requiresAuthForBroadApprovals)
                }
                Divider().overlay(Color.dockBorderLight)
                SettingsPreferenceRow(
                    title: "Explain approvals with Apple Intelligence",
                    detail: OnDeviceAssist.isAvailable
                        ? "Apple Intelligence is available on this Mac. When an approval arrives, its title and details go to Apple's on-device model, which adds a one-line explanation to the banner, labeled as Apple Intelligence. It runs locally and nothing is sent to Apple or Hermes."
                        : "Unavailable. Needs macOS 26 or later on a Mac with Apple Intelligence turned on in System Settings."
                ) {
                    settingsSwitch(isOn: $explainsApprovalsOnDevice)
                }
                OnDeviceAssistNotice(
                    text: "Apple Intelligence runs on this Mac. Generated text may be inaccurate."
                )
            }
            .dockPadding(.vertical, -8)
        }
    }

    var chatAssistancePreferencesSection: some View {
        SettingsSection(title: "Reply summaries & session titles", subtitle: "", tint: .dockAccent) {
            VStack(alignment: .leading, spacing: 12) {
                SettingsPreferenceRow(
                    title: "Summarize replies with Apple Intelligence",
                    detail: OnDeviceAssist.isAvailable
                        ? "Apple Intelligence is available on this Mac. Replies over 200 characters are summarized by Apple's on-device model into one line in the notch, labeled as Apple Intelligence. The reply itself is unchanged, and nothing is sent to Apple or Hermes."
                        : "Unavailable. Needs macOS 26 or later on a Mac with Apple Intelligence turned on in System Settings."
                ) {
                    settingsSwitch(isOn: $summarizesRepliesOnDevice)
                }
                Divider().overlay(Color.dockBorderLight)
                SettingsPreferenceRow(
                    title: "Name new sessions with Apple Intelligence",
                    detail: OnDeviceAssist.isAvailable
                        ? "Apple Intelligence is available on this Mac. After the first reply, a session Hermes left untitled gets a short title from Apple's on-device model, using only that first message and reply. The title is saved to Hermes so other apps show it too. Nothing is sent to Apple."
                        : "Unavailable. Needs macOS 26 or later on a Mac with Apple Intelligence turned on in System Settings."
                ) {
                    settingsSwitch(isOn: $namesSessionsOnDevice)
                }
                OnDeviceAssistNotice(
                    text: "Apple Intelligence runs on this Mac. Generated text may be inaccurate."
                )
            }
            .dockPadding(.vertical, -8)
        }
    }

    var powerPreferencesSection: some View {
        SettingsSection(title: "Power", subtitle: "", tint: .dockAccent) {
            VStack(alignment: .leading, spacing: 0) {
                SettingsPreferenceRow(
                    title: "Keep Mac awake while working",
                    detail: "Prevent idle sleep during a running turn. Only affects this Mac."
                ) {
                    settingsSwitch(isOn: $keepsAwakeWhileWorking)
                }
            }
            .dockPadding(.vertical, -8)
        }
    }

    var chatQuotaPreferencesSection: some View {
        SettingsSection(title: "Quota in chat", subtitle: "", tint: .dockAccent) {
            VStack(alignment: .leading, spacing: 0) {
                SettingsPreferenceRow(
                    title: "Show quota beside the composer",
                    detail: "Show the provider closest to its limit next to the context ring."
                ) {
                    settingsSwitch(isOn: $showsQuotaChip)
                }
                Divider().overlay(Color.dockBorderLight)
                SettingsPreferenceRow(
                    title: "Quota drop banner",
                    detail: "Show a banner over the chat each time a provider drops another 10%."
                ) {
                    settingsSwitch(isOn: $showsQuotaDropBanner)
                }
            }
            .dockPadding(.vertical, -8)
        }
    }

    /// Each modifier drives at most one shortcut, so the other's choice is hidden.
    func shortcutPicker(_ selection: Binding<DoubleTapShortcut>, excluding other: DoubleTapShortcut) -> some View {
        let label = { (option: DoubleTapShortcut) in option.keycap.map { "\(option.title)  \($0)" } ?? option.title }
        return DockMenuPicker(title: label(selection.wrappedValue), selection: selection) {
            ForEach(DoubleTapShortcut.allCases.filter { $0 == .off || $0 != other }) { option in
                DockMenuOption(label(option), value: option)
            }
        }
    }

    func settingsSwitch(isOn: Binding<Bool>) -> some View {
        Toggle("", isOn: isOn)
            .labelsHidden()
            .toggleStyle(.dockSwitch)
            .controlSize(.small)
            .tint(Color.dockAccent)
    }

    var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 224), spacing: 8)], spacing: 8) {
                let skins = control.appearanceProjection?.skins ?? []
                let hermOptions = DockThemeID.hermOnly.map { DockAppearanceOption(themeID: $0, hermesSkin: nil) }
                ForEach(hermOptions + DockAppearanceCatalog.installedOptions(installedSkins: skins)) { option in
                    themeOption(option)
                }
            }
            .disabled(notchSide == .top)
            .opacity(notchSide == .top ? 0.5 : 1)
            if !control.appearanceProjectionAvailable {
                SettingsInlineNotice(
                    text: "Hermes skin status unavailable. Refresh Settings to retry.", tint: Color.dockWarning)
            } else if let projection = control.appearanceProjection {
                let unknownSkins = DockAppearanceCatalog.unknownSkins(projection.skins)
                if !unknownSkins.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        settingsSubheading("Other Hermes skins")
                        ForEach(unknownSkins, id: \.id) { skin in
                            HStack(spacing: 8) {
                                Circle().fill(skin.isActive ? Color.dockAccent : Color.dockMetadataText).frame(
                                    width: 6, height: 6)
                                Text(skin.name).dockFont(.body).foregroundStyle(Color.dockSecondaryText).lineLimit(1)
                                Spacer()
                                Text("No Herm palette")
                                    .dockFont(.metadata)
                                    .foregroundStyle(Color.dockMetadataText)
                            }
                            .frame(minHeight: 36)
                        }
                    }
                }
            }
        }
    }

    func themeOption(_ option: DockAppearanceOption) -> some View {
        let theme = option.themeID
        let selected = dockThemeStore.selectedThemeID == theme
        let modeLabel = theme.appearance == .light ? "Light" : theme.appearance == .dark ? "Dark" : "System"
        return Button {
            withAnimation(.dockEase(duration: 0.16)) { dockThemeStore.selectedThemeID = theme }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                DockSkinSpecimen(theme: theme)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(theme.title)
                            .dockFont(.body, weight: .semibold)
                            .foregroundStyle(Color.dockPrimaryText)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        DockIcon(.check)
                            .dockFont(.body, weight: .bold)
                            .foregroundStyle(Color.dockAccent)
                            .opacity(selected ? 1 : 0)
                    }
                    Text(theme.signature)
                        .dockFont(.body)
                        .foregroundStyle(Color.dockSecondaryText)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Text(modeLabel)
                        if option.isHermesActive {
                            Text("·")
                            Text("Active in Hermes").foregroundStyle(Color.dockSecondaryText)
                        }
                    }
                    .dockFont(.metadata)
                    .foregroundStyle(Color.dockMetadataText)
                    .lineLimit(1)
                }
            }
            .dockPadding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous)
                    .fill(selected ? Color.dockSurface4 : Color.dockSurface2.opacity(0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous)
                    .stroke(
                        selected ? Color.dockAccent.opacity(0.6) : Color.dockBorderLight, lineWidth: selected ? 1 : 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.dockHover)
        .help(theme.detail)
        .accessibilityLabel(
            "\(theme.title), \(theme.signature), \(modeLabel)\(option.isHermesActive ? ", active in Hermes" : "")"
        )
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    var emergencyStopSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                DockIcon(control.emergencyStopActive == true ? .pauseCircle : .playCircle)
                    .foregroundStyle(control.emergencyStopActive == true ? Color.dockWarning : Color.dockSecondaryText)
                VStack(alignment: .leading, spacing: 2) {
                    Text(
                        control.emergencyStopActive == true
                            ? "New work paused"
                            : control.emergencyStopActive == false ? "Dispatch resumed" : "Dispatch status unknown"
                    )
                    .dockFont(.metadata, weight: .semibold)
                    .foregroundStyle(Color.dockPrimaryText)
                    Text(
                        control.emergencyStopMessage
                            ?? "Pause or resume records this Herm action; Hermes does not expose a stable ESTOP status contract."
                    )
                    .dockFont(.metadata)
                    .foregroundStyle(Color.dockMetadataText)
                    .lineLimit(2)
                }
                Spacer(minLength: 8)
                Button {
                    if control.emergencyStopActive == true {
                        isShowingEmergencyResumeConfirmation = true
                    } else {
                        isShowingEmergencyStopConfirmation = true
                    }
                } label: {
                    DockActionLabel(
                        title: control.emergencyStopActive == true ? "Resume" : "Pause",
                        pendingTitle: "Updating…",
                        isPending: control.isActionPending(control.emergencyStopActionID),
                        tint: control.emergencyStopActive == true ? .dockSecondaryText : .dockWarning
                    )
                }
                .buttonStyle(.dockCompact)
                .dockFont(.body, weight: .medium)
                .foregroundStyle(control.emergencyStopActive == true ? Color.dockSecondaryText : Color.dockWarning)
                .disabled(control.isActionPending(control.emergencyStopActionID))
            }
        }
    }

    var coreOverview: some View {
        HStack(spacing: 0) {
            coreSummaryMetric(
                title: "READY",
                value: capabilityInventorySnapshot.states.isEmpty
                    ? "—" : "\(capabilityInventorySnapshot.verifiedCount)/\(capabilityInventorySnapshot.totalCount)",
                color: capabilityInventorySnapshot.states.isEmpty ? .dockSecondaryText : .dockSuccess
            )
            coreSummaryMetric(
                title: "SESSION",
                value: model.sessionID == nil ? "None" : "Active",
                color: model.sessionID == nil ? .dockSecondaryText : .dockAccent
            )
            coreSummaryMetric(
                title: "NEEDS YOU",
                value: "\(control.attention.filter { $0.state == .open }.count)",
                color: control.attention.contains(where: { $0.state == .open }) ? .dockWarning : .dockSuccess
            )
        }
        .dockPadding(.vertical, 2)
        .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }
    }

    var settingsCommandBar: some View {
        HStack(spacing: 12) {
            Text("Control surface")
                .dockFont(.compactStatus, weight: .bold, design: .monospaced)
                .foregroundStyle(Color.dockMetadataText)
                .tracking(0.7)
            Spacer()
            Toggle(
                "Repository watch notifications",
                isOn: Binding(
                    get: { commandCenterPreferences.repositoryNotificationsEnabled },
                    set: { enabled in
                        commandCenterPreferences.setRepositoryNotificationsEnabled(enabled)
                        workflow.setRepositoryNotificationsEnabled(enabled)
                    }
                )
            )
            .labelsHidden()
            .toggleStyle(.dockSwitch)
            .tint(Color.dockAccent)
            Button {
                control.refresh()
                Task { await control.configEditor.load() }
            } label: {
                DockIcon(.arrowsClockwise)
                    .dockFont(.metadata, weight: .semibold)
            }
            .buttonStyle(.dockHover)
            .foregroundStyle(Color.dockAccent)
            .accessibilityLabel("Refresh Settings")
        }
        .dockPadding(.vertical, 2)
    }

    func coreSummaryMetric(title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .dockFont(.metadata, weight: .bold, design: .monospaced)
                .foregroundStyle(Color.dockMetadataText)
                .tracking(0.6)
            Text(value)
                .dockFont(.pageTitle, weight: .semibold)
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dockPadding(.vertical, 10)
    }

    func settingsDisclosure<Content: View>(
        title: String,
        subtitle: String,
        icon: Ph,
        isExpanded: Binding<Bool>,
        tint: Color = .dockAccent,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        SettingsSection(title: title, subtitle: subtitle, tint: tint) {
            content()
        }
    }

    func settingsCategoryDisclosure<Content: View>(
        title: String,
        count: Int,
        readyCount: Int,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.dockEase(duration: 0.18)) {
                    isExpanded.wrappedValue.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Text(title)
                        .dockFont(.metadata, weight: .semibold)
                    Text("\(count)")
                        .dockFont(.compactStatus, weight: .medium, design: .monospaced)
                        .foregroundStyle(Color.dockMetadataText)
                    Spacer()
                    Text("\(readyCount) ready")
                        .dockFont(.compactStatus, weight: .medium)
                        .foregroundStyle(readyCount == count ? Color.dockMetadataText : Color.dockWarning)
                    DockIcon(isExpanded.wrappedValue ? .caretUp : .caretDown)
                        .dockFont(.metadata, weight: .bold)
                        .foregroundStyle(Color.dockSecondaryText)
                        .frame(width: 18, height: 26)
                }
                .foregroundStyle(Color.dockPrimaryText)
                .contentShape(Rectangle())
            }
            .buttonStyle(.dockHover)
            if isExpanded.wrappedValue {
                content()
                    .dockPadding(.top, 10)
                    .dockPadding(.bottom, 8)
            }
        }
    }

    func capabilityCategoryExpansionBinding(for category: CapabilityCategory) -> Binding<Bool> {
        Binding(
            get: { expandedSettingsCapabilityCategories.contains(category) },
            set: { isExpanded in
                if isExpanded {
                    expandedSettingsCapabilityCategories.insert(category)
                } else {
                    expandedSettingsCapabilityCategories.remove(category)
                }
            }
        )
    }

    var quotaContent: some View {
        QuotaWorkspaceView(control: control)
    }

    func sectionLabel(_ title: String) -> some View {
        Text(title == title.uppercased() ? title.lowercased().capitalized : title)
            .dockFont(.conversation, weight: .medium)
            .foregroundStyle(Color.dockSectionText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .dockPadding(.top, 16)
            .dockPadding(.bottom, 10)
            .overlay(alignment: .bottom) {
                Color.dockBorderLight.frame(height: 0.5)
            }
    }

    /// In-card subheading. Groups inside a settings card separate with a
    /// divider above; the label itself stays quiet.
    func settingsSubheading(_ title: String) -> some View {
        Text(title == title.uppercased() ? title.lowercased().capitalized : title)
            .dockFont(.metadata, weight: .semibold)
            .foregroundStyle(Color.dockSecondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .dockPadding(.top, 4)
    }

    @ViewBuilder
    func projectionRefreshNotice(_ projection: String) -> some View {
        if let state = control.refreshState(for: projection) {
            if state.isRefreshing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(state.isStale ? "Refreshing — showing last successful data" : "Refreshing…")
                }
                .dockFont(.metadata)
                .foregroundStyle(Color.dockMetadataText)
            } else if let error = state.error {
                Text(state.isStale ? "Showing last successful data. \(error)" : error)
                    .dockFont(.metadata)
                    .foregroundStyle(Color.dockWarning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    func agentRow(_ agent: HermesSubagent, expanded: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Circle()
                .fill(nativeAgentColor(agent.status))
                .frame(width: 7, height: 7)
                .dockPadding(.top, 4)
            VStack(alignment: .leading, spacing: 4) {
                Text(agent.goal)
                    .dockFont(.body, weight: .medium)
                    .foregroundStyle(Color.dockPrimaryText)
                    .lineLimit(expanded ? 4 : 2)
                if let role = agent.role {
                    Text("ROLE  \(role.uppercased())\(agent.sourceSkill.map { "  ·  \($0)" } ?? "")")
                        .dockFont(.body, weight: .semibold)
                        .tracking(0.35)
                        .foregroundStyle(Color.dockAccent)
                }
                Text(
                    "\(agent.status.uppercased())  ·  \(agent.toolCount) TOOLS\(agent.model.map { "  ·  \($0.uppercased())" } ?? "")"
                )
                .dockFont(.body, weight: .semibold)
                .tracking(0.4)
                .foregroundStyle(nativeAgentColor(agent.status))
                if expanded, let latest = agent.latestActivity {
                    Text(latest)
                        .dockFont(.body)
                        .foregroundStyle(Color.dockMetadataText)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .dockPadding(.vertical, 4)
        .overlay(alignment: .bottom) { Color.dockBorderLight.opacity(0.7).frame(height: 0.5) }
    }

    func eventRow(_ event: AgentEvent) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•")
                .dockFont(.body, weight: .bold)
                .foregroundStyle(Color.dockAccent.opacity(0.75))
                .frame(width: 13)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.type.uppercased()).dockFont(.body, weight: .semibold).tracking(0.35).foregroundStyle(
                    Color.dockSecondaryText)
                Text(event.detail).dockFont(.body).foregroundStyle(Color.dockMetadataText).lineLimit(2)
            }
        }
    }

    func diagnosticRow(label: String, value: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label == label.uppercased() ? label.prefix(1) + label.dropFirst().lowercased() : label)
                .dockFont(.body).foregroundStyle(Color.dockSecondaryText)
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 5, height: 5)
                Text(value).dockFont(.body, weight: .medium).foregroundStyle(Color.dockPrimaryText).lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    var selectedModelDisplayName: String {
        model.runtimeModelOptions.first(where: { $0.id == selectedModelID })?.displayName
            ?? model.runtimeConfiguration.map { "\($0.provider ?? "provider")  /  \($0.model ?? "model")" }
            ?? "Select Hermes model"
    }

    func configurationList(
        _ values: [String],
        empty: String,
        isExpanded: Bool = false,
        onToggle: (() -> Void)? = nil
    ) -> some View {
        let visibleValues = isExpanded ? values : Array(values.prefix(8))

        return VStack(alignment: .leading, spacing: 6) {
            if values.isEmpty {
                Text(empty)
                    .dockFont(.body)
                    .foregroundStyle(Color.dockMetadataText)
            } else {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(minimum: 0), alignment: .leading),
                        GridItem(.flexible(minimum: 0), alignment: .leading),
                    ],
                    alignment: .leading,
                    spacing: 8
                ) {
                    ForEach(Array(visibleValues.enumerated()), id: \.offset) { _, value in
                        HStack(spacing: 7) {
                            Circle().fill(Color.dockAccent.opacity(0.65)).frame(width: 4, height: 4)
                            Text(value)
                                .dockFont(.body, weight: .medium)
                                .foregroundStyle(Color.dockPrimaryText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if values.count > 8 {
                    if let onToggle {
                        Button(action: onToggle) {
                            HStack(spacing: 4) {
                                DockIcon(isExpanded ? .caretUp : .caretDown)
                                    .dockFont(.compactStatus, weight: .semibold)
                                Text(isExpanded ? "SHOW FEWER" : "SHOW ALL \(values.count) SKILLS")
                            }
                            .dockFont(.body, weight: .medium)
                            .foregroundStyle(Color.dockAccent)
                        }
                        .buttonStyle(.dockLink)
                        .accessibilityLabel(isExpanded ? "Show fewer skills" : "Show all \(values.count) skills")
                    } else {
                        Text("+ \(values.count - 8) MORE")
                            .dockFont(.body, weight: .semibold)
                            .tracking(0.65)
                            .foregroundStyle(Color.dockMetadataText)
                    }
                }
            }
        }
    }

    func capabilityRow(icon: Ph, title: String, detail: String, state: String, color: Color) -> some View {
        HStack(spacing: 8) {
            DockIcon(icon).dockFont(.body).foregroundStyle(color).frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).dockFont(.body, weight: .medium).foregroundStyle(Color.dockPrimaryText)
                Text(detail).dockFont(.body).foregroundStyle(Color.dockMetadataText)
            }
            Spacer(minLength: 3)
            Text(state).dockFont(.body, weight: .semibold).tracking(0.45).foregroundStyle(color)
        }
    }

    var latestModelName: String? {
        model.messages.reversed().compactMap(\.modelName).first
    }

    func emptyState(icon: Ph, title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            DockIcon(icon).foregroundStyle(Color.dockMetadataText)
            Text(title).dockFont(.body, weight: .medium).foregroundStyle(Color.dockPrimaryText)
            Text(detail).dockFont(.body).foregroundStyle(Color.dockSecondaryText).fixedSize(
                horizontal: false, vertical: true)
        }
    }

    func nativeAgentColor(_ status: String) -> Color {
        switch status.lowercased() {
        case "running", "finalizing": .dockAccent
        case "complete", "completed": .dockSuccess
        case "blocked", "stalled", "error": .dockWarning
        default: .dockSecondaryText
        }
    }

    var statusColor: Color {
        switch model.status {
        case .idle: .dockSuccess
        case .working: .dockAccent
        case .needsApproval: .dockWarning
        case .needsClarification: .dockWarning
        case .offline: .dockDestructive
        }
    }
}
