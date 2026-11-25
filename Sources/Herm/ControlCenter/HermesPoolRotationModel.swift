import Combine
import Foundation

@MainActor
final class HermesPoolRotationModel: ObservableObject {
    typealias Service = HermesPoolRotationService

    enum State: Equatable {
        case loading
        case ready([Service.Pool])
        case unavailable(String)
    }

    @Published private var state: State = .loading
    @Published private(set) var savingPool: String?
    private var loadedScope: Service.Scope?
    private var revision = UUID()
    private let service: () -> Service?
    private let onSaved: () -> Void

    init(service: @escaping () -> Service?, onSaved: @escaping () -> Void = {}) {
        self.service = service
        self.onSaved = onSaved
    }

    var scope: Service.Scope? { service()?.scope }

    var visibleState: State {
        guard let scope else { return .unavailable("Hermes is not connected.") }
        return loadedScope == scope ? state : .loading
    }

    func load() async {
        guard let service = service(), savingPool == nil else { return }
        let revision = UUID()
        self.revision = revision
        let result: State
        do {
            result = .ready(try await service.pools())
        } catch {
            result = .unavailable(HermesDiagnosticsService.safeSummary(error.localizedDescription))
        }
        guard !Task.isCancelled, self.revision == revision, scope == service.scope else { return }
        loadedScope = service.scope
        state = result
    }

    func save(_ strategy: Service.Strategy, for pool: Service.Pool, scope: Service.Scope) async throws {
        guard let service = service(), service.scope == scope, savingPool == nil,
            case .ready(var pools) = visibleState, let index = pools.firstIndex(of: pool), strategy != pool.strategy
        else { return }

        revision = UUID()
        savingPool = pool.id
        defer {
            savingPool = nil
            if self.scope != scope { Task { await load() } }
        }
        try await service.save(strategy, for: pool)
        guard self.scope == scope else { return }
        pools[index].strategy = strategy
        state = .ready(pools)
        onSaved()
    }
}
