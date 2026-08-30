import Foundation

/// Parser for a future structured recovery status response. It intentionally
/// accepts no human CLI output and never retains provider-supplied detail.
struct RecoveryService {
    static func snapshot(from payload: [String: Any]) -> RecoverySnapshot {
        RecoverySnapshot(items: RecoveryFeature.allCases.map { feature in
            guard let value = payload[feature.rawValue] as? [String: Any],
                  let supported = value["supported"] as? Bool else {
                return RecoveryFeatureStatus(id: feature, state: .unavailable, detail: unavailableDetail(for: feature))
            }
            guard supported else {
                return RecoveryFeatureStatus(id: feature, state: .unsupported, detail: unsupportedDetail(for: feature))
            }
            guard let ready = value["ready"] as? Bool else {
                return RecoveryFeatureStatus(id: feature, state: .unavailable, detail: unavailableDetail(for: feature))
            }
            if feature.isConsequential {
                return RecoveryFeatureStatus(id: feature, state: .requiresConfirmation, detail: ready
                    ? "Ready to review; no action is enabled."
                    : "Status is available; source and destination review is required.")
            }
            return RecoveryFeatureStatus(id: feature, state: ready ? .ready : .unavailable, detail: ready
                ? readyDetail(for: feature)
                : unavailableDetail(for: feature))
        })
    }

    static func parseVerifiedJSON(_ output: String) throws -> RecoverySnapshot {
        guard let data = output.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object.keys.allSatisfy({ RecoveryFeature(rawValue: $0) != nil }) else {
            throw ParseError.invalid
        }
        return snapshot(from: object)
    }

    static func unavailable() -> RecoverySnapshot {
        snapshot(from: [:])
    }


    /// Mutations are deliberately fail-closed. Confirmation is surfaced to the
    /// caller, but no request adapter exists until disposable-workspace approval.
    static func requestMutation(
        _ feature: RecoveryFeature,
        snapshot: RecoverySnapshot,
        confirmed: Bool
    ) -> RecoveryMutationResult {
        _ = snapshot
        guard confirmed else { return .confirmationRequired }
        return .unavailable
    }

    private enum ParseError: Error { case invalid }

    private static func readyDetail(for feature: RecoveryFeature) -> String {
        switch feature {
        case .update: "Update status is available."
        default: "Status is available."
        }
    }

    private static func unavailableDetail(for feature: RecoveryFeature) -> String {
        "Hermes did not provide structured \(feature.title.lowercased()) status."
    }

    private static func unsupportedDetail(for feature: RecoveryFeature) -> String {
        "This Hermes version does not expose structured \(feature.title.lowercased()) status."
    }
}
