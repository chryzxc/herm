import Foundation

/// Only the tour's progress is local. Bot and plugin state is always read from Hermes.
@MainActor
final class DockOnboardingModel: ObservableObject {
    static let completedKey = "herm.onboarding.completed.v1"
    static let stepKey = "herm.onboarding.step.v1"
    static let titles = ["Welcome to Herm", "Your bot", "Make Herm yours", "On-device assistance"]

    @Published var step: Int {
        didSet { defaults.set(step, forKey: Self.stepKey) }
    }
    @Published private(set) var busy = false
    @Published private(set) var progress = "Checking Hermes…"
    @Published private(set) var connected = false
    @Published private(set) var plugin: WorkflowPlugin?
    @Published private(set) var message = ""
    @Published private(set) var restartRequired = false
    let bots = BotModeModel()
    private var rosterVerified = false
    private let client: HermesRPCClientProtocol
    private let defaults: UserDefaults
    private var service: HermesWorkflowRPC { HermesWorkflowRPC(client: client, profileID: nil) }

    init(client: HermesRPCClientProtocol, defaults: UserDefaults = .standard) {
        self.client = client
        self.defaults = defaults
        step = min(max(defaults.integer(forKey: Self.stepKey), 0), Self.titles.count - 1)
        bots.bind(to: client, capabilityAvailable: false)
    }

    var canEnablePlugin: Bool { connected && plugin?.status == "disabled" && !busy && !restartRequired }
    var canUseBots: Bool {
        connected && rosterVerified && plugin?.enabled != false && !busy && !restartRequired
            && bots.inventory.availability == .ready
            && bots.inventory.isPluginEnabled
    }

    var canContinue: Bool { !busy && (step != 1 || canUseBots) }

    func refresh() async {
        guard !busy else { return }
        busy = true
        progress = "Checking Hermes…"
        defer { busy = false }
        await readRuntime()
    }

    private func readRuntime() async {
        connected = false
        rosterVerified = false
        do {
            try await client.connect()
            let plugins = try await HermesCapabilityService().probeOnboardingPlugins(client: client)
            plugin = plugins.first { $0.id == "hermes-bots" }
            connected = true
            let roster = await BotService(client: client).rosterList()
            rosterVerified = roster.availability == .ready
            await bots.refreshNow(force: true)
            await bots.loadAvatars()
            if restartRequired {
                message = "Change saved. Restart the Hermes gateway, then reopen setup to verify bot access."
            } else if let plugin, !plugin.enabled {
                message =
                    plugin.status == "disabled"
                    ? "Enable the Hermes Bots plugin to use bots in Herm."
                    : "Hermes reports the Bots plugin as \(plugin.status). Resolve it in Hermes, then retry."
            } else if !rosterVerified {
                message = roster.diagnostic
            } else if bots.inventory.availability != .ready {
                message = bots.inventory.diagnostic
            } else {
                message = "Connected to Hermes. Your existing configuration is available."
            }
        } catch {
            plugin = nil
            message = "Could not verify Hermes: \(HermesDiagnosticsService.safeSummary(error.localizedDescription))"
        }
    }

    /// Called only after the UI confirms the named Hermes configuration change.
    func enablePlugin() async {
        guard canEnablePlugin else { return }
        busy = true
        progress = "Enabling Bots…"
        defer { busy = false }
        do {
            // Recheck the canonical entry immediately before writing.
            let plugins = try await HermesCapabilityService().probeOnboardingPlugins(client: client)
            guard let current = plugins.first(where: { $0.id == "hermes-bots" }), current.status == "disabled" else {
                await readRuntime()
                return
            }
            restartRequired = try await service.togglePlugin(current.id, enabled: true)
            await readRuntime()
        } catch {
            connected = false
            plugin = nil
            message = "Could not enable Bots: \(HermesDiagnosticsService.safeSummary(error.localizedDescription))"
        }
    }

    func generateFaces() async {
        guard canUseBots else { return }
        busy = true
        progress = "Generating faces…"
        defer { busy = false }
        message = HermesDiagnosticsService.safeSummary(await bots.populateAvatars())
    }

    func finish() {
        defaults.set(true, forKey: Self.completedKey)
        defaults.removeObject(forKey: Self.stepKey)
    }
}
