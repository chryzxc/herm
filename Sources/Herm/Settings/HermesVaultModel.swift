import Combine
import Foundation

@MainActor
final class HermesVaultModel: ObservableObject {
    @Published private(set) var items: [HermesVaultItem] = []
    @Published private(set) var sources: [HermesVaultSource] = []
    @Published private(set) var busy = false
    @Published private(set) var available = false
    @Published private(set) var notice = "Loading saved credentials…"
    let service: HermesVaultService?

    init(service: HermesVaultService?) { self.service = service }

    func load() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        await refresh()
    }

    private func refresh() async {
        available = false
        do {
            guard let service else { throw HermesVaultError.unavailable }
            let snapshot = try await HermesCapabilityService().probeVault(service: service)
            try Task.checkCancellation()
            items = snapshot.items
            sources = snapshot.sources
            available = true
            notice = "Passwords are encrypted by Hermes and filled without showing them to the model."
        } catch {
            items = []
            sources = []
            notice = HermesDiagnosticsService.safeSummary(
                "Passwords & Logins unavailable. Reconnect Hermes and retry; the backend must support the vault API.")
        }
    }

    /// Callers supply transient secure-field input; never retain it in published state or diagnostics.
    func perform(_ action: (HermesVaultService) async throws -> Void) async -> Bool {
        guard available, !busy, let service, !Task.isCancelled else { return false }
        busy = true
        defer { busy = false }
        do {
            try await action(service)
            await refresh()
            return true
        } catch {
            // Backend/CLI errors may echo arbitrary secret text. Only fixed copy can leave this boundary.
            notice = HermesDiagnosticsService.safeSummary(
                "The vault action failed. Refresh and check the selected profile or password manager before retrying.")
            available = false
            return false
        }
    }
}
