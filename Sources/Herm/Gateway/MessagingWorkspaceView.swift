import CoreImage.CIFilterBuiltins
import SwiftUI

/// Gateway messaging platforms (Telegram, Discord, Slack, …) for one profile:
/// credentials, enablement, QR quick setup (Telegram, WhatsApp), test and restart.
struct MessagingWorkspaceView: View {
    @ObservedObject var botMode: BotModeModel
    @StateObject private var model: MessagingPlatformsModel
    @State private var profileID: String?
    @State private var selection: String?
    @State private var search = ""
    @State private var drafts: [String: String] = [:]
    @State private var enabledDraft: Bool?
    @State private var showsAdvanced = false
    @State private var whatsappMode = "bot"

    init(botMode: BotModeModel, client: HermesRPCClientProtocol) {
        self.botMode = botMode
        _model = StateObject(wrappedValue: MessagingPlatformsModel(client: client))
    }

    private var profile: BotSummary? { botMode.bots.first { $0.id == profileID } }
    private var filtered: [MessagingPlatform] {
        let needle = search.lowercased()
        return needle.isEmpty ? model.platforms : model.platforms.filter { "\($0.id) \($0.name)".lowercased().contains(needle) }
    }
    private var current: MessagingPlatform? {
        model.platforms.first { $0.id == selection } ?? filtered.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            HStack(alignment: .top, spacing: 0) {
                platformList.frame(width: 260)
                Rectangle().fill(Color.dockBorderLight).frame(width: 0.5)
                if let current {
                    detail(current).id(current.id)
                } else {
                    Text(model.platforms.isEmpty && model.error == nil ? "Loading…" : "No platforms match.")
                        .dockFont(size: 12).foregroundStyle(Color.dockMetadataText)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onAppear { if profileID == nil { profileID = botMode.bots.first(where: \.isDefault)?.id } }
        .task(id: profileID) { await model.load(profileID: profileID) }
        .onChange(of: profileID) { resetDrafts() }
        .onChange(of: selection) { resetDrafts() }
        .onDisappear { model.cancelQR() }
    }

    private func resetDrafts() {
        drafts = [:]
        enabledDraft = nil
        model.error = nil
        model.notice = nil
        model.testResult = nil
        model.cancelQR()
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                DockIcon(.magnifyingGlass, size: 12, color: .dockMetadataText)
                DockTextField("Try \u{201C}discord\u{201D}", text: $search).textFieldStyle(.plain)
            }
            if !botMode.bots.isEmpty {
                Text("Applies to").dockFont(size: 12, weight: .medium).foregroundStyle(Color.dockSecondaryText)
                DockChipFlow(spacing: 6) {
                    ForEach(botMode.bots) { bot in
                        chip(bot.name, selected: bot.id == profileID) { profileID = bot.id }
                    }
                }
                Text("Changes on this page apply to the \u{201C}\(profile?.name ?? "launch")\u{201D} profile.")
                    .dockFont(size: 11).foregroundStyle(Color.dockAccent)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.dockBorderLight).frame(height: 0.5) }
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).dockFont(size: 12, weight: selected ? .semibold : .regular)
                .foregroundStyle(selected ? Color.dockPrimaryText : Color.dockSecondaryText)
                .padding(.horizontal, 10).frame(height: 26)
                .background(Capsule().fill(selected ? Color.dockSurface : .clear))
                .overlay(Capsule().stroke(selected ? Color.dockAccent.opacity(0.5) : Color.dockBorderLight, lineWidth: 0.5))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: List

    private var platformList: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(filtered) { platform in
                    let selected = platform.id == current?.id
                    Button { selection = platform.id } label: {
                        HStack(spacing: 10) {
                            MessagingPlatformIcon(platform: platform)
                            Text(platform.name).dockFont(size: 13, weight: selected ? .semibold : .regular)
                                .foregroundStyle(Color.dockPrimaryText).lineLimit(1)
                            Spacer(minLength: 6)
                            DockStatusDot(tone: platform.enabled ? platform.statusTone : .inactive, size: 6)
                        }
                        .padding(.horizontal, 8).frame(height: 36)
                        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.dockSurface : .clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
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
                    HStack(spacing: 10) {
                        MessagingPlatformIcon(platform: platform)
                        Text(platform.name).dockFont(size: 18, weight: .semibold).foregroundStyle(Color.dockPrimaryText)
                        ForEach(platform.statusLabels.indices, id: \.self) {
                            DockStatusPill(tone: platform.statusLabels[$0].0, text: platform.statusLabels[$0].1)
                        }
                    }
                    if !platform.description.isEmpty {
                        Text(platform.description).dockFont(size: 13).foregroundStyle(Color.dockSecondaryText)
                    }
                    if let message = model.error {
                        DockCallout(tone: .danger, icon: .warningCircle, title: "Couldn't update messaging", message: message) { EmptyView() }
                    } else if let message = platform.errorMessage, !message.isEmpty {
                        DockCallout(tone: .warning, icon: .warningCircle, title: "Gateway reported a problem", message: message) { EmptyView() }
                    }
                    if let result = model.testResult {
                        DockCallout(tone: result.ok ? .info : .warning, icon: result.ok ? .checkCircle : .warningCircle,
                                    title: result.ok ? "Test passed" : "Test failed", message: result.message) { EmptyView() }
                    }
                    if let notice = model.notice {
                        Text(notice).dockFont(size: 12).foregroundStyle(Color.dockSecondaryText)
                    }
                    if MessagingPlatformsModel.qrPlatforms.contains(platform.id) { quickSetup(platform.id) }
                    credentialsGuide(platform, first: required.first)
                    section("Required", required)
                    section("Recommended", recommended)
                    if !advanced.isEmpty {
                        DisclosureGroup(isExpanded: $showsAdvanced) {
                            fields(advanced).padding(.top, 10)
                        } label: {
                            sectionLabel("Advanced")
                        }
                        .disclosureGroupStyle(DockDisclosureGroupStyle())
                    }
                }
                .padding(20)
                .frame(maxWidth: 820, alignment: .leading)
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
                    Text("Quick setup").dockFont(size: 14, weight: .semibold)
                    DockStatusPill(tone: .complete, text: "Recommended")
                }
                Text(telegram
                    ? "Scan a QR code and confirm in Telegram. Hermes creates the bot and detects your Telegram user ID automatically."
                    : "Scan the QR code from WhatsApp → Linked devices. Hermes links this number and saves the setup.")
                    .dockFont(size: 12).foregroundStyle(Color.dockSecondaryText)
                if let pairing = model.pairing, pairing.platform == platformID {
                    HStack(alignment: .top, spacing: 16) {
                        if let image = MessagingQRCode.image(pairing.qrPayload) {
                            Image(nsImage: image).interpolation(.none).resizable().frame(width: 160, height: 160)
                                .padding(8).background(RoundedRectangle(cornerRadius: 8).fill(.white))
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text(pairing.qrPayload.isEmpty ? "Preparing QR code…" : "Waiting for confirmation in \(telegram ? "Telegram" : "WhatsApp")…")
                                    .dockFont(size: 12)
                            }
                            if let link = pairing.deepLink { Link("Open in Telegram", destination: link).buttonStyle(.dockLink) }
                            Button("Cancel") { model.cancelQR() }.buttonStyle(.dockSecondary).controlSize(.small)
                        }
                    }
                } else {
                    HStack(spacing: 10) {
                        if !telegram {
                            Picker("", selection: $whatsappMode) {
                                Text("Dedicated bot number").tag("bot")
                                Text("My own number (self-chat)").tag("self-chat")
                            }
                            .labelsHidden().fixedSize()
                        }
                        Button {
                            Task { await model.startQR(platform: platformID, whatsappMode: whatsappMode, profileID: profileID) }
                        } label: {
                            Label { Text(telegram ? "Create with QR" : "Link with QR") } icon: { DockIcon(.qrCode, size: 13) }
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
                if !text.isEmpty { Text(text).dockFont(size: 12).foregroundStyle(Color.dockSecondaryText) }
                if let docs = platform.docsURL {
                    Link(destination: docs) {
                        HStack(spacing: 4) { Text("Open setup guide"); DockIcon(.arrowSquareOut, size: 12) }
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
                    Text(env.prompt).dockFont(size: 13, weight: .semibold).foregroundStyle(Color.dockPrimaryText)
                    if !env.description.isEmpty, env.description != env.prompt {
                        Text(env.description).dockFont(size: 11).foregroundStyle(Color.dockMetadataText)
                    }
                    HStack(spacing: 8) {
                        if env.isPassword || (env.isSet && env.value == nil) {
                            SecureField(env.isSet ? "Saved (\(env.redactedValue)) — leave blank to keep" : env.key, text: draft)
                                .textFieldStyle(.dockGlass)
                        } else {
                            DockTextField(env.isList ? "Comma-separated" : env.key, text: draft).textFieldStyle(.dockGlass)
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
        Text(title.uppercased()).dockFont(size: 11, weight: .semibold).tracking(1.2)
            .foregroundStyle(Color.dockSecondaryText)
    }

    private func footer(_ platform: MessagingPlatform) -> some View {
        let enabled = Binding(get: { enabledDraft ?? platform.enabled }, set: { enabledDraft = $0 })
        let changed = (enabledDraft.map { $0 != platform.enabled } ?? false) || !drafts.isEmpty
        return HStack {
            Toggle(isOn: enabled) { Text(enabled.wrappedValue ? "Enabled" : "Disabled").dockFont(size: 12) }
                .toggleStyle(.dockSwitch)
            Spacer()
            if ["pending_restart", "gateway_stopped", "startup_failed"].contains(platform.state) {
                let start = platform.state == "gateway_stopped"
                Button(start ? "Start gateway" : "Restart gateway") {
                    Task { model.error = nil; await model.restartGateway(start: start, profileID: profileID) }
                }
                .buttonStyle(.dockSecondary).disabled(model.busy)
            }
            Button("Test") {
                Task { model.error = nil; await model.test(platform, profileID: profileID) }
            }
            .buttonStyle(.dockSecondary).disabled(model.busy || changed)
            .help(changed ? "Save changes before testing" : "Check this platform's connection")
            Button {
                Task {
                    model.error = nil
                    if await model.save(platform, enabled: enabled.wrappedValue, drafts: drafts, profileID: profileID) {
                        drafts = [:]
                        enabledDraft = nil
                    }
                }
            } label: {
                Label { Text("Save changes") } icon: { DockIcon(.floppyDisk, size: 13) }
            }
            .buttonStyle(.dockPrimary).disabled(model.busy || !changed)
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        .overlay(alignment: .top) { Rectangle().fill(Color.dockBorderLight).frame(height: 0.5) }
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
                Text(platform.name.prefix(1).uppercased()).dockFont(size: 12, weight: .semibold)
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
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: output.extent.size)
    }
}
