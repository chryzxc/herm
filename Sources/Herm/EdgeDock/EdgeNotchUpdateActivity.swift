import Combine
import Foundation

extension EdgeNotchState {
    var railActivity: EdgeNotchActivity {
        var result = sessionRailActivity
        result.agentUpdatePhase = agentUpdatePhase
        return result
    }

    /// Updater state belongs to the ambient rail, never the session projection.
    /// Retaining the subscription also retains its owner for sender isolation.
    func observeAgentUpdates(
        from service: HermesUpdateService,
        onChange: @escaping @MainActor () -> Void
    ) -> AnyCancellable {
        agentUpdatePhase = service.phase
        onChange()
        return NotificationCenter.default.publisher(for: .hermAgentUpdatePhase)
            .filter { ($0.object as? HermesUpdateService) === service }
            .compactMap { $0.userInfo?["phase"] as? HermesUpdatePhase }
            .receive(on: RunLoop.main)
            .sink { [weak self] phase in
                guard let self else { return }
                self.agentUpdatePhase = phase
                onChange()
            }
    }
}
