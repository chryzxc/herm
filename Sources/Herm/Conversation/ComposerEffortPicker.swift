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
        if selection == HermesReasoningVariant.none { return "Thinking off" }
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

/// The last real effort levels, so the stacked bar survives the catalog reloading after a model switch
/// instead of being torn down and rebuilt (which restarts its animation and shifts the popover).
private final class EffortChoicesMemory: ObservableObject {
    var last: [HermesReasoningVariant] = []
}

struct ComposerEffortControls: View {
    @ObservedObject var model: DockModel
    @StateObject private var memory = EffortChoicesMemory()
    let modelID: String?
    @Binding var selection: HermesReasoningVariant?
    /// Radio rows under a heading, matching the model list, for a side pane.
    var stacked = false

    private var presentation: ComposerEffortPresentation {
        ComposerEffortPresentation(
            selection: selection, choices: model.effortCatalog?.choices(for: modelID),
            wire: model.sessionID == nil ? nil : model.sessionReasoningWire,
            pending: model.isUpdatingSessionModel || model.isUpdatingSessionReasoning,
            loading: model.isEffortCatalogPending, stale: model.sessionReasoningStale)
    }

    private func remember(_ choices: [HermesReasoningVariant]) {
        if !choices.isEmpty { memory.last = choices }
    }

    static func title(_ variant: HermesReasoningVariant) -> String {
        variant == .none ? "Off" : (variant == .xhigh ? "Extra High" : variant.rawValue.capitalized)
    }

    /// The catalog says whether this model has a Fast tier; fall back to the session's report when it is silent.
    private var offersFast: Bool {
        model.effortCatalog?.supportsFast(for: modelID) ?? (model.sessionFastEnabled != nil)
    }

    /// Always present in the stacked layout so the row does not jump; disabled when Hermes offers no Fast tier.
    private var speedSwitch: some View {
        let available = model.sessionID != nil && offersFast
        return ComposerSpeedSwitch(isFast: fastBinding, isPending: model.isUpdatingSessionFast)
            .frame(width: 124)
            .disabled(!available || model.isUpdatingSessionFast)
            .help(
                model.isUpdatingSessionFast
                    ? "Changing speed…"
                    : model.sessionID == nil
                        ? "Start a chat to change speed."
                        : offersFast ? "Fast uses priority processing." : "Fast is not available for this model.")
    }

    private var fastBinding: Binding<Bool> {
        Binding(
            get: { model.pendingSessionFastEnabled ?? model.sessionFastEnabled ?? false },
            set: { model.updateSessionFast($0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if presentation.needsRefresh {
                Button("Refresh effort availability") {
                    model.refreshRuntimeModelOptions(sessionID: model.sessionID)
                    if model.sessionID != nil { model.refreshSessionReasoningVariant() }
                }
            } else {
                let choices = presentation.choices ?? []
                // While a switch or reload is in flight the levels are briefly unknown; keep drawing the last ones.
                let barChoices =
                    choices.isEmpty && (presentation.loading || presentation.pending) ? memory.last : choices
                let _ = remember(choices)
                if stacked {
                    // Level name and speed share a row; the bar runs full width below.
                    if barChoices.isEmpty {
                        speedSwitch
                    } else {
                        ComposerEffortSlider(choices: barChoices, selection: $selection) { speedSwitch }
                            .disabled(presentation.disabled)
                    }
                } else if choices.count <= 3, !choices.isEmpty {
                    HStack(spacing: 8) {
                        Text("Effort")
                            .dockFont(.body)
                            .foregroundStyle(Color.dockSecondaryText)
                        effortChoices(choices)
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Effort, \(presentation.status)")
                } else {
                    HStack {
                        Text("Effort")
                            .dockFont(.body)
                            .foregroundStyle(Color.dockSecondaryText)
                        Spacer(minLength: 4)
                        Text(presentation.status)
                            .dockFont(.metadata)
                            .foregroundStyle(Color.dockMetadataText)
                    }
                    effortChoices(choices)
                }
                if !stacked, model.sessionID != nil, offersFast {
                    Toggle("Fast", isOn: fastBinding)
                        .toggleStyle(.dockSwitch)
                        .disabled(model.isUpdatingSessionFast)
                }
            }
        }
        .frame(minHeight: stacked ? 54 : 0, alignment: .top)
        .help(presentation.explanation)
    }

    private func effortChoices(_ choices: [HermesReasoningVariant]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 3), spacing: 2) {
            ForEach(choices) { variant in
                DockTabButton(
                    title: Self.title(variant),
                    isSelected: selection == variant, showsSelectionMark: true
                ) { selection = variant }
                .frame(maxWidth: .infinity)
            }
        }
        .dockTabTrack()
        .disabled(presentation.disabled)
    }

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
            loading: model.isEffortCatalogPending, stale: model.sessionReasoningStale)
    }

    var body: some View {
        DockMenu {
            ComposerEffortControls(model: model, modelID: modelID, selection: $selection)
                .frame(width: 270)
        } label: {
            label(presentation.status)
        }
        .disabled(presentation.disabled)
        .accessibilityLabel(presentation.accessibilityLabel)
        .accessibilityHint(presentation.explanation)
        .help(presentation.explanation)
    }
}
