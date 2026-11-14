import SwiftUI

struct DockOnboardingView: View {
    @ObservedObject var setup: DockOnboardingModel
    @ObservedObject var bots: BotModeModel
    @ObservedObject private var theme = DockThemeStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var createsBot = false
    @State private var confirmsEnable = false
    @State private var confirmsFaces = false
    @State private var showsConnection = false
    let close: () -> Void
    let finish: () -> Void

    var body: some View {
        DockExpandedPage(
            title: DockOnboardingModel.titles[setup.step], subtitle: "Set up Herm · \(setup.step + 1) of 4",
            showsClose: false, close: close, trailing: { EmptyView() }
        ) {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    ForEach(0..<4) { index in
                        Capsule().fill(index <= setup.step ? Color.dockAccent : Color.dockBorderLight)
                            .frame(height: 3)
                    }
                }
                .accessibilityLabel("Step \(setup.step + 1) of 4")
                .dockPadding(.horizontal, 24).dockPadding(.top, 16)
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        switch setup.step {
                        case 0: welcome
                        case 1: botSetup
                        case 2: DockOnboardingAppearance()
                        default: DockOnboardingIntelligence()
                        }
                    }
                    .frame(maxWidth: 640, alignment: .leading)
                    .dockPadding(24)
                    .frame(maxWidth: .infinity, alignment: .top)
                    .id(setup.step)
                    .transition(.opacity)
                }
                footer
            }
        }
        .background(DockWindowBackground())
        .dockThemedRoot().dockPreferredTextSize()
        .dockFont(.body)
        .animation(
            reduceMotion || !DockThemeStyle.current.animates ? nil : .easeInOut(duration: 0.18), value: setup.step
        )
        .onExitCommand(perform: close)
        .task { await setup.refresh() }
        .dockSheet(isPresented: $createsBot, onDismiss: { Task { await setup.refresh() } }) {
            BotCreationSheet(model: bots, roster: bots.bots)
        }
        .dockSheet(isPresented: $showsConnection) {
            DockExpandedPage(
                title: "Gateway connection", subtitle: "Use your existing Hermes installation",
                close: {
                    showsConnection = false
                }
            ) {
                ScrollView {
                    GatewayConnectionSettingsView(onRestart: { HermesUpdateService().restartDock() }).dockPadding(24)
                }
            }.frame(width: 680, height: 560)
        }
        .confirmationDialog("Enable Hermes Bots?", isPresented: $confirmsEnable) {
            Button("Enable Bots plugin") { Task { await setup.enablePlugin() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This changes the Bots plugin in your default Hermes configuration. New sessions use the updated plugin set; existing sessions are not reconfigured. Hermes may require a gateway restart."
            )
        }
        .confirmationDialog("Generate missing Herm faces?", isPresented: $confirmsFaces) {
            Button("Generate missing faces") { Task { await setup.generateFaces() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Herm draws a face for every bot without an avatar and saves it to that Hermes profile. Existing images are preserved. Profile avatars are shared across apps and sessions; agent settings are unchanged."
            )
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .center, spacing: 20) {
                Image(nsImage: DockAppBrand.icon).resizable().frame(width: 72, height: 72)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Your Hermes, within reach").dockFont(.body, weight: .semibold)
                    Text("Your existing agent, with a native home on your Mac.")
                        .foregroundStyle(Color.dockSecondaryText)
                }
            }
            VStack(alignment: .leading, spacing: 16) {
                welcomeDetail(
                    icon: .gearSix, title: "Keep your Hermes setup",
                    detail: "Your models, providers, skills, memory, and conversations stay with Hermes.")
                welcomeDetail(
                    icon: .sparkle, title: "Personalize Herm",
                    detail: "Choose a bot, place the notch, pick a skin, and set up Apple Intelligence.")
            }
            Text("You can change these choices later. Actions that update Hermes ask for confirmation.")
                .foregroundStyle(Color.dockSecondaryText)
            connectionStatus
        }
    }

    private func welcomeDetail(icon: Ph, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            DockIcon(icon).foregroundStyle(Color.dockSecondaryText).frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).dockFont(.body, weight: .semibold)
                Text(detail).foregroundStyle(Color.dockSecondaryText)
            }
        }
    }

    private var connectionStatus: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                DockIcon(setup.connected ? .check : .globe)
                    .foregroundStyle(setup.connected ? Color.dockSuccess : Color.dockSecondaryText)
                    .frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Hermes connection").dockFont(.body, weight: .semibold)
                    Text(setup.busy ? setup.progress : setup.message)
                        .foregroundStyle(setup.connected || setup.busy ? Color.dockSecondaryText : Color.dockWarning)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, minHeight: 32, alignment: .topLeading)
                }
            }
            HStack(spacing: 8) {
                Button("Connection settings") { showsConnection = true }
                    .buttonStyle(.dockCompact)
                Button("Check again") { Task { await setup.refresh() } }
                    .buttonStyle(.dockCompact)
            }
            .disabled(setup.busy)
            if !setup.connected && !setup.busy {
                Text(
                    "New to Hermes? Install and configure Hermes Agent, then check again. Using a remote, SSH, or Cloud gateway? Choose it in Connection settings."
                )
                .foregroundStyle(Color.dockSecondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dockCard(padding: 16)
    }

    private var botSetup: some View {
        VStack(alignment: .leading, spacing: 20) {
            botPluginSection
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text("Choose a bot").dockFont(.body, weight: .semibold)
                    Spacer(minLength: 12)
                    Button("Create bot…") { createsBot = true }
                        .buttonStyle(.dockSecondary).disabled(!setup.canUseBots)
                }
                Text("Use an existing bot, or create a named Hermes profile for future chats.")
                    .foregroundStyle(Color.dockSecondaryText)
            }
            if bots.inventory.availability == .ready {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], spacing: 12) {
                    ForEach(bots.bots.filter { !$0.isHidden }) { bot in
                        botCard(bot)
                    }
                }
                .disabled(!setup.canUseBots)
                Divider()
                botFaces
            }
        }
    }

    private var botPluginSection: some View {
        DockCallout(
            tone: .warning, icon: .info, title: "Hermes Bots",
            message:
                "Herm needs Hermes bot support to manage your bots and chats. Enable the Bots plugin in your existing Hermes configuration. Runtimes with built-in bot support are ready without a separate plugin.",
            badge: "Required for Herm"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 8) {
                    if setup.canUseBots { DockIcon(.check).foregroundStyle(Color.dockSuccess) }
                    Text(setup.busy ? setup.progress : setup.canUseBots ? "Bot support is enabled." : setup.message)
                        .dockFont(.body).foregroundStyle(Color.dockSecondaryText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, minHeight: 32, alignment: .topLeading)
                }
                DockCalloutActions {
                    if setup.plugin?.status == "disabled" {
                        Button("Enable Bots plugin…") { confirmsEnable = true }
                            .buttonStyle(.dockSecondary).disabled(!setup.canEnablePlugin)
                    }
                    Button("Check bot support") { Task { await setup.refresh() } }
                        .buttonStyle(.dockCompact).disabled(setup.busy)
                    if !setup.connected {
                        Button("Connection settings") { showsConnection = true }
                            .buttonStyle(.dockCompact).disabled(setup.busy)
                    }
                }
            }
        }
    }

    private var botFaces: some View {
        HStack(alignment: .center, spacing: 16) {
            BotFaceMark(id: bots.selectedProfileID ?? "default", size: 52)
                .accessibilityLabel("Herm face preview")
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Text("Herm faces").dockFont(.body, weight: .semibold)
                    Spacer(minLength: 0)
                    Button("Generate missing faces…") { confirmsFaces = true }.buttonStyle(.dockCompact)
                }
                Text(
                    "Drawn locally, animated in Herm, and saved to your Hermes profiles. Existing avatars stay as they are."
                )
                .foregroundStyle(Color.dockSecondaryText)
            }
        }
        .disabled(!setup.canUseBots)
    }

    private func botCard(_ bot: BotSummary) -> some View {
        Button {
            bots.selectProfile(bot.id)
        } label: {
            HStack(spacing: 12) {
                BotAvatarView(bot: bot, imageData: bots.avatarImages[bot.id], size: 36)
                VStack(alignment: .leading, spacing: 4) {
                    Text(bot.name).dockFont(.body, weight: .semibold).lineLimit(1)
                    if bot.isDefault {
                        DockMetadataPill(text: "Default profile")
                            .fixedSize()
                    } else {
                        Text(bot.title ?? "Hermes profile")
                            .foregroundStyle(Color.dockSecondaryText)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                DockIcon(.check)
                    .foregroundStyle(Color.dockAccent)
                    .opacity(bots.selectedProfileID == bot.id ? 1 : 0)
            }
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .dockCard(isActive: bots.selectedProfileID == bot.id)
            .contentShape(Rectangle())
        }
        .buttonStyle(.dockHover)
        .accessibilityAddTraits(bots.selectedProfileID == bot.id ? .isSelected : [])
        .help([bot.name, bot.title].compactMap { $0 }.joined(separator: " · "))
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button("Set up later") {
                setup.finish()
                finish()
            }.buttonStyle(.dockLink)
            Spacer(minLength: 16)
            if setup.step > 0 {
                Button("Back") { setup.step -= 1 }.buttonStyle(.dockSecondary)
            }
            Button(setup.step == 3 ? "Open Herm" : "Continue") {
                if setup.step == 3 {
                    setup.finish()
                    finish()
                } else {
                    setup.step += 1
                }
            }
            .buttonStyle(.dockPrimary)
            .disabled(!setup.canContinue)
            .keyboardShortcut(.defaultAction)
        }
        .disabled(setup.busy)
        .dockPadding(.horizontal, 24)
        .dockPadding(.vertical, 16)
        .background(Color.dockSurface)
        .overlay(alignment: .top) {
            Color.dockBorderLight.frame(height: DockLayout.hairline)
        }
    }
}
