import CoreFoundation
import Foundation

struct HermesEffortCatalog {
    private var choicesByID: [String: [HermesReasoningVariant]] = [:]
    private var fastByID: [String: Bool] = [:]

    init(result: [String: Any]) {
        guard let providers = result["providers"] as? [[String: Any]] else { return }
        for provider in providers {
            guard let name = (provider["slug"] as? String) ?? (provider["name"] as? String),
                let models = provider["models"] as? [String]
            else { continue }
            let aliases =
                [name, provider["name"] as? String].compactMap { $0 }
                + (provider["aliases"] as? [String] ?? [])
            let capabilities = provider["capabilities"] as? [String: Any]
            if provider["capabilities"] != nil && capabilities == nil { continue }
            for model in models {
                let raw = capabilities?[model]
                guard raw == nil || raw is [String: Any] else { continue }
                let entry = raw as? [String: Any] ?? [:]
                func flag(_ key: String) -> Bool? {
                    guard let value = entry[key] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else {
                        return nil
                    }
                    return value.boolValue
                }
                guard entry["reasoning"] == nil || flag("reasoning") != nil,
                    entry["can_disable_reasoning"] == nil || flag("can_disable_reasoning") != nil
                else { continue }
                var choices = HermesReasoningVariant.allCases
                if flag("reasoning") == false {
                    choices = []
                } else if flag("can_disable_reasoning") == false {
                    choices.removeFirst()
                }
                for alias in aliases {
                    let id = HermesModelOption(provider: alias, model: model).id
                    choicesByID[id] = choices
                    if let fast = flag("fast") { fastByID[id] = fast }
                }
            }
        }
    }

    /// Whether Hermes offers Fast (priority) processing for this model; nil when the catalog is silent.
    func supportsFast(for id: String?) -> Bool? {
        id.flatMap { fastByID[$0] }
    }

    func choices(for id: String?) -> [HermesReasoningVariant]? {
        guard let id else { return nil }
        return choicesByID[id]
    }
}
