import CoreImage.CIFilterBuiltins
import SwiftUI

/// Gateway messaging platforms (Telegram, Discord, Slack, …) for one profile:
/// credentials, enablement, QR quick setup (Telegram, WhatsApp), test and restart.
struct MessagingWorkspaceView: View {
    @ObservedObject var workspace: IntegrationsWorkspaceState
    @ObservedObject var model: MessagingPlatformsModel
    private var profileID: String? { workspace.profileID }
    private var selection: String? {
        get { workspace.currentBrowsing.selection }
        nonmutating set { workspace.currentBrowsing.selection = newValue }
    }
    private var search: String {
        get { workspace.currentBrowsing.search }
        nonmutating set { workspace.currentBrowsing.search = newValue }
    }
    @State private var drafts: [String: String] = [:]
    @State private var enabledDraft: Bool?
    @State private var showsAdvanced = false
    @State private var whatsappMode = "bot"

    init(workspace: IntegrationsWorkspaceState) {
        self.workspace = workspace
        self.model = workspace.messaging
    }

    private var filtered: [MessagingPlatform] {
        MessagingPlatform.matching(model.platforms, query: search)
    }
    private var current: MessagingPlatform? {
        filtered.first { $0.id == selection } ?? filtered.first
    }

    private var hasPendingEdits: Bool {
        guard let current else { return false }
        return current.hasChanges(enabled: enabledDraft ?? current.enabled, drafts: drafts)
    }

    var body: some View {
        AdaptiveSplit(
            breakpoint: 800, primaryMinWidth: 340, secondaryMinWidth: 400,
            showsSecondary: workspace.currentBrowsing.showsDetail,
            onBack: { if !hasPendingEdits { workspace.currentBrowsing.showsDetail = false } }
        ) {
            VStack(alignment: .leading, spacing: 16) {
                IntegrationLibraryHeader(
                    title: "Messaging",
                    summary: model.hasLoaded
                        ? "\(filtered.count) platforms"
                        : model.loading ? "Reading platforms…" : "Inventory unavailable")
                HStack(spacing: 8) {
                    DockTextField("Search messaging", text: Binding(get: { search }, set: { search = $0 }))
                        .textFieldStyle(.dockGlass).frame(minWidth: 180, maxWidth: 320)
                        .disabled(workspace.navigationLocked)
                    if !search.isEmpty {
                        Button("Clear filter") { search = "" }.buttonStyle(.dockSecondary).fixedSize()
                            .disabled(hasPendingEdits)
                    }
                    Spacer(minLength: 0)
                }
                Color.dockBorderLight.frame(height: DockLayout.hairline)
                if filtered.isEmpty {
                    emptyState
                    Spacer(minLength: 0)
                } else {
                    platformGrid
                }
            }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
        } secondary: {
            if let current {
                detail(current)
            } else {
                emptyState.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .onChange(of: profileID) { resetDrafts() }
        .onChange(of: current?.id) { resetDrafts() }
        .onChange(of: hasPendingEdits) { _, value in
            workspace.isDirty = value
            if value { workspace.currentBrowsing.showsDetail = true }
        }
        .onChange(of: workspace.discardRevision) { resetDrafts() }
        .onChange(of: filtered.map(\.id)) { _, ids in
            if let selection, !ids.contains(selection) {
                self.selection = nil
                workspace.currentBrowsing.showsDetail = false
            }
        }
        .onDisappear { model.cancelQR() }
    }

    private func resetDrafts() {
        drafts = [:]
        enabledDraft = nil
        model.notice = nil
        model.testResult = nil
        model.cancelQR()
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(
                model.loading
                    ? "Loading platforms…"
                    : model.error != nil
                        ? "Messaging unavailable"
                        : model.hasLoaded && model.platforms.isEmpty
                            ? "No messaging platforms" : "No matching platforms"
            )
            .dockFont(.body, weight: .semibold)
            Text(
                model.error
                    ?? (model.platforms.isEmpty
                        ? "Refresh to read the platforms available in this profile."
                        : "Try another platform name or clear the search.")
            )
            .dockFont(.body).foregroundStyle(Color.dockSecondaryText)
            if !search.isEmpty {
                Button("Clear search") { search = "" }.buttonStyle(.dockCompact)
            }
        }.padding(20)
    }

    private var platformGrid: some View {
        ScrollView {
            IntegrationCardGrid {
                ForEach(filtered) { platform in
                    IntegrationCard(
                        title: platform.name, detail: platform.description,
                        status: (
                            platform.enabled ? platform.statusTone : .inactive,
                            platform.statusLabels.map(\.1).joined(separator: " · ")
                        ),
                        selected: workspace.currentBrowsing.showsDetail && platform.id == current?.id,
                        action: {
                            selection = platform.id
                            workspace.currentBrowsing.showsDetail = true
                        }
                    ) {
                        MessagingPlatformIcon(platform: platform)
                    }
                    .disabled(model.busy || model.loading || hasPendingEdits)
                }
            }
            .padding(.bottom, 14)
        }
    }

    // MARK: Detail

    private func detail(_ platform: MessagingPlatform) -> some View {
        let required = platform.envVars.filter(\.required)
        let recommended = platform.envVars.filter { !$0.required && !$0.advanced }
        let advanced = platform.envVars.filter { !$0.required && $0.advanced }
        return VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header(platform)
                    if MessagingPlatformsModel.qrPlatforms.contains(platform.id) {
                        quickSetup(platform.id).disabled(hasPendingEdits || model.isStale || model.loading)
                    }
                    credentialsGuide(platform, first: required.first)
                    section("Required", required).disabled(model.busy || model.loading || model.isStale)
                    section("Recommended", recommended).disabled(model.busy || model.loading || model.isStale)
                    if !advanced.isEmpty {
                        DisclosureGroup(isExpanded: $showsAdvanced) {
                            fields(advanced).frame(maxWidth: .infinity, alignment: .leading)
                                .dockCard(padding: 12, isQuiet: true).padding(.top, 8)
                                .disabled(model.busy || model.loading || model.isStale)
                        } label: {
                            sectionLabel("Advanced")
                        }
                        .disclosureGroupStyle(DockDisclosureGroupStyle())
                    }
                }
                .padding(24)
                .frame(maxWidth: 600, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            footer(platform)
        }
    }

    /// Same identity block as the other Integrations inspectors: glyph tile, name, live state, scope, description.
    private func header(_ platform: MessagingPlatform) -> some View {
        IntegrationInspectorHeader(
            title: platform.name, category: "Messaging", scope: "Profile · \(workspace.profileName)",
            detail: platform.description
        ) {
            MessagingPlatformIcon(platform: platform, size: 48)
        } status: {
            DockChipFlow(spacing: 6) {
                ForEach(platform.statusLabels.indices, id: \.self) {
                    DockStatusPill(tone: platform.statusLabels[$0].0, text: platform.statusLabels[$0].1)
                }
            }
        }
    }

    private func quickSetup(_ platformID: String) -> some View {
        let telegram = platformID == "telegram"
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                sectionLabel("Quick setup")
                DockStatusPill(tone: .complete, text: "Recommended")
            }
            VStack(alignment: .leading, spacing: 10) {
                Text(
                    telegram
                        ? "Scan a QR code and confirm in Telegram. Hermes creates the bot and detects your Telegram user ID automatically."
                        : "Scan the QR code from WhatsApp → Linked devices. Hermes links this number and saves the setup."
                )
                .dockFont(.body).foregroundStyle(Color.dockSecondaryText)
                if let pairing = model.pairing, pairing.platform == platformID {
                    VStack(alignment: .leading, spacing: 16) {
                        if let image = MessagingQRCode.image(pairing.qrPayload) {
                            Image(nsImage: image).interpolation(.none).resizable().frame(width: 160, height: 160)
                                .padding(8).background(RoundedRectangle(cornerRadius: 8).fill(.white))
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 6) {
                                ProgressView()
                                Text(
                                    pairing.qrPayload.isEmpty
                                        ? "Preparing QR code…"
                                        : "Waiting for confirmation in \(telegram ? "Telegram" : "WhatsApp")…"
                                )
                                .dockFont(.body)
                            }
                            if let link = pairing.deepLink {
                                Link("Open in Telegram", destination: link).buttonStyle(.dockLink)
                            }
                            Button("Cancel") { model.cancelQR() }.buttonStyle(.dockSecondary)
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        if !telegram {
                            Picker("", selection: $whatsappMode) {
                                Text("Dedicated bot number").tag("bot")
                                Text("My own number (self-chat)").tag("self-chat")
                            }
                            .labelsHidden()
                        }
                        Button {
                            Task {
                                await model.startQR(
                                    platform: platformID, whatsappMode: whatsappMode, profileID: profileID)
                            }
                        } label: {
                            DockActionLabel(
                                title: telegram ? "Create with QR" : "Link with QR", pendingTitle: "Connecting…",
                                isPending: model.busy)
                        }
                        .buttonStyle(.dockPrimary).disabled(model.busy)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .dockCard(padding: 12, isQuiet: true)
        }
    }

    @ViewBuilder
    private func credentialsGuide(_ platform: MessagingPlatform, first: MessagingEnvVar?) -> some View {
        let text = first.map { $0.help.isEmpty ? $0.description : $0.help } ?? ""
        if !text.isEmpty || platform.docsURL != nil {
            VStack(alignment: .leading, spacing: 8) {
                sectionLabel("Get your credentials")
                if !text.isEmpty { Text(text).dockFont(.body).foregroundStyle(Color.dockSecondaryText) }
                if let docs = platform.docsURL {
                    Link(destination: docs) {
                        HStack(spacing: 4) {
                            Text("Open setup guide")
                            DockIcon(.arrowSquareOut, size: 12)
                        }
                    }.buttonStyle(.dockLink)
                }
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ vars: [MessagingEnvVar]) -> some View {
        if !vars.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                sectionLabel(title)
                fields(vars).frame(maxWidth: .infinity, alignment: .leading).dockCard(padding: 12, isQuiet: true)
            }
        }
    }

    private func fields(_ vars: [MessagingEnvVar]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(vars) { env in
                let draft = Binding(
                    get: { drafts[env.key] ?? (env.isPassword ? "" : env.value ?? "") },
                    set: { drafts[env.key] = $0 })
                VStack(alignment: .leading, spacing: 4) {
                    Text(env.prompt).dockFont(.navigation, weight: .semibold).foregroundStyle(Color.dockPrimaryText)
                    if !env.description.isEmpty, env.description != env.prompt {
                        Text(env.description).dockFont(.metadata).foregroundStyle(Color.dockMetadataText)
                    }
                    HStack(spacing: 8) {
                        if env.isPassword || (env.isSet && env.value == nil) {
                            SecureField(
                                env.isSet ? "Saved (\(env.redactedValue)) — leave blank to keep" : env.key, text: draft
                            )
                            .textFieldStyle(.dockGlass)
                        } else {
                            DockTextField(env.isList ? "Comma-separated" : env.key, text: draft).textFieldStyle(
                                .dockGlass)
                        }
                        if let url = env.url {
                            Link(destination: url) { DockIcon(.arrowSquareOut, size: 13, color: .dockSecondaryText) }
                                .help("Open \(url.host ?? "link")")
                        }
                    }
                }
            }
        }
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title).dockFont(.metadata, weight: .semibold).foregroundStyle(Color.dockSectionText)
    }

    /// The latest outcome, toned so a failed test reads differently from a saved notice.
    private func footerStatus(_ platform: MessagingPlatform) -> (DockStatusTone, String)? {
        if let error = model.error { return (.attention, error) }
        if let test = model.testResult {
            return test.ok ? (.complete, "Test passed: \(test.message)") : (.attention, "Test failed: \(test.message)")
        }
        if let notice = model.notice { return (.inactive, notice) }
        return platform.errorMessage.map { (.attention, $0) }
    }

    private func footer(_ platform: MessagingPlatform) -> some View {
        let enabled = Binding(get: { enabledDraft ?? platform.enabled }, set: { enabledDraft = $0 })
        let changed = platform.hasChanges(enabled: enabled.wrappedValue, drafts: drafts)
        let status = footerStatus(platform)
        return VStack(alignment: .leading, spacing: 10) {
            // Fixed-height slot so test results and notices never shift the actions.
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let status {
                    DockStatusDot(tone: status.0, muted: status.0 == .inactive)
                    Text(status.1).dockFont(.body).foregroundStyle(Color.dockSecondaryText).lineLimit(2)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            HStack(spacing: 8) {
                Toggle(isOn: enabled) { Text(enabled.wrappedValue ? "Enabled" : "Disabled").dockFont(.body) }
                    .toggleStyle(.dockSwitch).disabled(model.isStale).fixedSize()
                Spacer(minLength: 8)
                if changed {
                    Button("Discard") {
                        resetDrafts()
                        workspace.isDirty = false
                    }.buttonStyle(.dockSecondary)
                }
            }
            DockChipFlow(spacing: 8) {
                if ["pending_restart", "gateway_stopped", "startup_failed"].contains(platform.state) {
                    let start = platform.state == "gateway_stopped"
                    DockAsyncButton(start ? "Start gateway" : "Restart gateway") {
                        await model.restartGateway(start: start, profileID: profileID)
                    }.buttonStyle(.dockSecondary).disabled(changed || model.isStale)
                }
                DockAsyncButton("Test") { await model.test(platform, profileID: profileID) }
                    .buttonStyle(.dockSecondary).disabled(changed || model.isStale)
                Button {
                    Task {
                        if await model.save(
                            platform, enabled: enabled.wrappedValue, drafts: drafts, profileID: profileID)
                        {
                            drafts = [:]
                            enabledDraft = nil
                            workspace.isDirty = false
                        }
                    }
                } label: {
                    DockActionLabel(title: "Save changes", pendingTitle: "Saving…", isPending: model.busy)
                }.buttonStyle(.dockPrimary).disabled(!changed || model.isStale)
            }
        }
        .disabled(model.loading || model.busy)
        .dockButtonSize(.standard)
        .padding(.horizontal, 20).padding(.vertical, 10)
        .overlay(alignment: .top) { Color.dockBorderLight.frame(height: DockLayout.hairline) }
    }

}

private struct MessagingPlatformIcon: View {
    let platform: MessagingPlatform
    var size: CGFloat = 26

    private var symbol: Ph? {
        switch platform.id {
        case "telegram": .telegramLogo
        case "discord": .discordLogo
        case "slack": .slackLogo
        case "whatsapp", "whatsapp_cloud": .whatsappLogo
        case "email": .envelope
        case "bluebubbles": .appleLogo
        case "sms": .chatCenteredText
        case "google_chat": .googleLogo
        case "teams", "msteams": .microsoftTeamsLogo
        default: nil
        }
    }

    var body: some View {
        Group {
            if let symbol {
                DockIcon(symbol, size: (size * 0.5).rounded(), color: .dockAccent)
            } else {
                Text(platform.name.prefix(1).uppercased()).dockFont(.body, weight: .semibold)
                    .foregroundStyle(Color.dockSecondaryText)
            }
        }
        .frame(width: size, height: size)
        .background(RoundedRectangle(cornerRadius: size / 4).dockSurfaceFill(Color.dockSurface))
        .overlay(RoundedRectangle(cornerRadius: size / 4).stroke(Color.dockBorderLight, lineWidth: 0.5))
    }
}

enum MessagingQRCode {
    static func image(_ payload: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
            let cgImage = CIContext().createCGImage(output, from: output.extent)
        else { return nil }
        return NSImage(cgImage: cgImage, size: output.extent.size)
    }
}
