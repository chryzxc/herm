import SwiftUI

struct ComposerEffortPresentation {
    let selection: HermesReasoningVariant?
    let choices: [HermesReasoningVariant]?
    let wire: String?
    let pending: Bool
    let loading: Bool
    let stale: Bool

    var needsRefresh: Bool { stale || (choices == nil && !loading) }
    var disabled: Bool { pending || loading || (!needsRefresh && (choices ?? []).isEmpty) }
    var status: String {
        if pending { return "Updating…" }
        if loading { return "Loading…" }
        if stale { return "Status unavailable" }
        guard let choices else { return "Unavailable" }
        guard let selection else { return choices.isEmpty ? "Unavailable" : "Unrecognized" }
        let name = selection == .xhigh ? "Extra High" : selection.rawValue.capitalized
        if !choices.contains(selection) { return "\(name) — unavailable" }
        if let wire, !wire.isEmpty, wire.lowercased() != selection.rawValue {
            return "\(name) → \(wire.capitalized)"
        }
        return name
    }
    var explanation: String {
        if stale { return "Effort could not be refreshed. Open to retry." }
        guard let choices else { return "Effort availability could not be verified. Open to refresh." }
        if choices.isEmpty { return "Effort is not supported for this model." }
        if let selection, let wire, !wire.isEmpty, wire.lowercased() != selection.rawValue {
            return "Hermes reports the route entry mapping as \(wire.capitalized); the final provider level may differ."
        }
        return "Select effort"
    }
    var accessibilityLabel: String { "Effort, \(status)" }
}

struct ComposerEffortPicker<Label: View>: View {
    @ObservedObject var model: DockModel
    let modelID: String?
    @Binding var selection: HermesReasoningVariant?
    let label: (String) -> Label

    private var presentation: ComposerEffortPresentation {
        ComposerEffortPresentation(
            selection: selection, choices: model.effortCatalog?.choices(for: modelID),
            wire: model.sessionID == nil ? nil : model.sessionReasoningWire,
            pending: model.isUpdatingSessionModel || model.isUpdatingSessionReasoning,
            loading: model.isLoadingRuntimeModelOptions, stale: model.sessionReasoningStale)
    }

    var body: some View {
        DockMenu {
            if presentation.needsRefresh {
                Button("Refresh effort availability") {
                    model.refreshRuntimeModelOptions(sessionID: model.sessionID)
                    if model.sessionID != nil { model.refreshSessionReasoningVariant() }
                }
            } else {
                DockMenuChoices(selection: $selection) {
                    ForEach(presentation.choices ?? []) { variant in
                        DockMenuOption(
                            variant == .xhigh ? "Extra High" : variant.rawValue.capitalized, value: Optional(variant))
                    }
                }
            }
        } label: {
            label(presentation.status)
        }
        .disabled(presentation.disabled)
        .accessibilityLabel(presentation.accessibilityLabel)
        .accessibilityHint(presentation.explanation)
        .help(presentation.explanation)
    }
}
