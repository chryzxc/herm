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
            breakpoint: 800, primaryMinWidth: 280, primaryIdealWidth: 320, primaryMaxWidth: 380, secondaryMinWidth: 400,
            alwaysSplitWhenWide: true, showsSecondary: workspace.currentBrowsing.showsDetail,
            onBack: { if !hasPendingEdits { workspace.currentBrowsing.showsDetail = false } }
        ) {
            VStack(spacing: 10) {
                DockTextField("Search messaging", text: Binding(get: { search }, set: { search = $0 }))
                    .textFieldStyle(.dockGlass).disabled(workspace.navigationLocked)
                HStack {
                    Text(
                        model.hasLoaded
                            ? "\(filtered.count) platforms"
                            : model.loading ? "Reading platforms…" : "Inventory unavailable"
                    ).dockFont(.metadata)
                        .foregroundStyle(Color.dockMetadataText)
                    Spacer()
                    if !search.isEmpty {
                        Button("Clear filter") { search = "" }.buttonStyle(.dockSecondary).disabled(hasPendingEdits)
                    }
                }.frame(minHeight: 28)
                if filtered.isEmpty {
                    emptyState
                    Spacer(minLength: 0)
                } else {
                    platformList
                }
            }.padding(14).frame(maxWidth: .infinity)
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

    // MARK: List

    private var platformList: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(filtered) { platform in
                    let selected = platform.id == current?.id
                    Button {
                        selection = platform.id
                        workspace.currentBrowsing.showsDetail = true
                    } label: {
                        HStack(spacing: 10) {
                            MessagingPlatformIcon(platform: platform)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(platform.name).dockFont(.body, weight: selected ? .semibold : .regular)
                                    .foregroundStyle(Color.dockPrimaryText).lineLimit(1)
                                if !platform.description.isEmpty {
                                    Text(platform.description).dockFont(.body).foregroundStyle(Color.dockSecondaryText)
                                        .lineLimit(2)
                                }
                                Text(platform.statusLabels.map(\.1).joined(separator: " · "))
                                    .dockFont(.metadata).foregroundStyle(Color.dockSecondaryText).lineLimit(1)
                            }
                            Spacer(minLength: 6)
                            DockStatusDot(tone: platform.enabled ? platform.statusTone : .inactive, size: 6)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 12)
                        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.dockSurface : .clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.dockHover)
                    .disabled(model.busy || model.loading || hasPendingEdits)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(10)
        }
    }

    // MARK: Detail

    private func detail(_ platform: MessagingPlatform) -> some View {
        let required = platform.envVars.filter(\.required)
        let recommended = platform.envVars.filter { !$0.required && !$0.advanced }
        let advanced = platform.envVars.filter { !$0.required && $0.advanced }
        return VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    DockChipFlow(spacing: 8) {
                        MessagingPlatformIcon(platform: platform)
                        Text(platform.name).dockFont(.body, weight: .semibold).foregroundStyle(Color.dockPrimaryText)
                        ForEach(platform.statusLabels.indices, id: \.self) {
                            DockStatusPill(tone: platform.statusLabels[$0].0, text: platform.statusLabels[$0].1)
                        }
                    }
                    if !platform.description.isEmpty {
                        Text(platform.description).dockFont(.navigation).foregroundStyle(Color.dockSecondaryText)
                    }
                    Text("Profile: \(workspace.profileName)").dockFont(.body).foregroundStyle(Color.dockSecondaryText)
                    if MessagingPlatformsModel.qrPlatforms.contains(platform.id) {
                        quickSetup(platform.id).disabled(hasPendingEdits || model.isStale || model.loading)
                    }
                    credentialsGuide(platform, first: required.first)
                    section("Required", required).disabled(model.busy || model.loading || model.isStale)
                    section("Recommended", recommended).disabled(model.busy || model.loading || model.isStale)
                    if !advanced.isEmpty {
                        DisclosureGroup(isExpanded: $showsAdvanced) {
                            fields(advanced).padding(.top, 10).disabled(model.busy || model.loading || model.isStale)
                        } label: {
                            sectionLabel("Advanced")
                        }
                        .disclosureGroupStyle(DockDisclosureGroupStyle())
                    }
                }
                .padding(20)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            footer(platform)
        }
    }

    private func quickSetup(_ platformID: String) -> some View {
        let telegram = platformID == "telegram"
        return VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Quick setup")
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("Quick setup").dockFont(.conversation, weight: .semibold)
                    DockStatusPill(tone: .complete, text: "Recommended")
                }
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
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 10).dockSurfaceFill(Color.dockSurface))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.dockBorderLight, lineWidth: 0.5))
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
            VStack(alignment: .leading, spacing: 10) {
                sectionLabel(title)
                fields(vars)
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
        Text(title.uppercased()).dockFont(.metadata, weight: .semibold).tracking(1.2)
            .foregroundStyle(Color.dockSecondaryText)
    }

    private func footer(_ platform: MessagingPlatform) -> some View {
        let enabled = Binding(get: { enabledDraft ?? platform.enabled }, set: { enabledDraft = $0 })
        let changed = platform.hasChanges(enabled: enabled.wrappedValue, drafts: drafts)
        return VStack(alignment: .leading, spacing: 10) {
            Text(
                model.error ?? model.testResult.map { ($0.ok ? "Test passed: " : "Test failed: ") + $0.message }
                    ?? model.notice ?? platform.errorMessage ?? ""
            )
            .dockFont(.body).foregroundStyle(Color.dockSecondaryText).lineLimit(2)
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            HStack {
                Toggle(isOn: enabled) { Text(enabled.wrappedValue ? "Enabled" : "Disabled").dockFont(.body) }
                    .toggleStyle(.dockSwitch).disabled(model.isStale)
                Spacer()
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
                DockIcon(symbol, size: 14, color: .dockAccent)
            } else {
                Text(platform.name.prefix(1).uppercased()).dockFont(.body, weight: .semibold)
                    .foregroundStyle(Color.dockSecondaryText)
            }
        }
        .frame(width: 26, height: 26)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.dockSurface))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.dockBorderLight, lineWidth: 0.5))
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
