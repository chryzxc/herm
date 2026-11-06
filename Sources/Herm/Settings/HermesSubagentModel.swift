import Combine
import Foundation

@MainActor
final class HermesSubagentModel: ObservableObject {
    @Published private(set) var defaults: HermesSubagentDefaults?
    @Published private(set) var routing: HermesSubagentRouting?
    @Published private(set) var busy = false
    @Published private(set) var available = false
    @Published private(set) var routingAvailable = false
    @Published private(set) var notice = "Loading subagent settings…"
    @Published private(set) var providers: [CronModelProvider] = []
    @Published private(set) var routingPlugin: WorkflowPluginCatalogEntry?
    @Published private(set) var disabledRoutingPlugin: WorkflowPlugin?
    let service: HermesSubagentService?

    init(service: HermesSubagentService?) { self.service = service }

    func load() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        await refresh()
    }

    private func refresh() async {
        available = false
        routingAvailable = false
        routingPlugin = nil
        disabledRoutingPlugin = nil
        guard let service else {
            notice = "Connect Hermes to manage subagents."
            return
        }
        do {
            let defaults = try await service.defaults()
            try Task.checkCancellation()
            self.defaults = defaults
            available = true
            notice =
                "Changes apply to future delegations in this profile. Running subagents keep their current settings."
        } catch {
            notice = "Subagent defaults unavailable. Reconnect Hermes and refresh."
        }
        if let routing = try? await HermesCapabilityService().probeSubagentRouting(service: service) {
            self.routing = routing
            routingAvailable = true
        } else {
            notice = "Routing unavailable on this backend. Refresh or update Hermes to manage routing."
        }
        providers = (try? await service.rpc.subagentModelProviders(profileID: service.profile)) ?? []
        if routing?.backends.contains(where: { ["model_map", "profile_routes"].contains($0.id) && $0.available })
            != true
        {
            if let plugins = try? await service.rpc.workflow(profileID: service.profile).plugins() {
                let installed = plugins.first { $0.name == "advanced-delegation" }
                disabledRoutingPlugin = installed.flatMap { $0.enabled ? nil : $0 }
                if installed == nil { routingPlugin = try? await service.routingPlugin() }
            }
        }
    }

    func enableRoutingPlugin(_ plugin: WorkflowPlugin) async {
        var restart = false
        let applied = await perform { service in
            restart = try await service.rpc.workflow(profileID: service.profile).togglePlugin(plugin.id, enabled: true)
        }
        if applied && restart {
            notice =
                "Advanced Delegation is enabled. Restart the Hermes gateway when your running agents can be interrupted, then refresh routing."
        }
    }

    func perform(_ action: (HermesSubagentService) async throws -> Void) async -> Bool {
        guard !busy, available || routingAvailable, let service, !Task.isCancelled else { return false }
        busy = true
        defer { busy = false }
        do {
            try await action(service)
            await refresh()
            return true
        } catch {
            notice =
                "Hermes did not save the change. " + HermesDiagnosticsService.safeSummary(error.localizedDescription)
            return false
        }
    }
}
