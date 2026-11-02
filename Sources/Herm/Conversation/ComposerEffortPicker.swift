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

struct ComposerEffortControls: View {
    @ObservedObject var model: DockModel
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

    private static func title(_ variant: HermesReasoningVariant) -> String {
        variant == .none ? "Off" : (variant == .xhigh ? "Extra High" : variant.rawValue.capitalized)
    }

    private func radioRow(_ title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Circle()
                    .stroke(isSelected ? Color.dockPrimaryText : Color.dockSecondaryText, lineWidth: 1)
                    .frame(width: 15, height: 15)
                    .overlay {
                        if isSelected { DockIcon(.check, size: 10, color: Color.dockPrimaryText) }
                    }
                Text(title)
                    .dockFont(.body, weight: isSelected ? .semibold : .regular)
                    .lineLimit(1)
                Spacer(minLength: 8)
            }
        }
        .accessibilityLabel("\(title)\(isSelected ? ", selected" : "")")
    }

    private func effortRows(_ choices: [HermesReasoningVariant]) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(choices) { variant in
                radioRow(Self.title(variant), isSelected: selection == variant) { selection = variant }
            }
        }
        .disabled(presentation.disabled)
    }

    private var fastBinding: Binding<Bool> {
        Binding(get: { model.sessionFastEnabled ?? false }, set: { model.updateSessionFast($0) })
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
                if stacked {
                    Text("Effort")
                        .dockFont(.body, weight: .semibold)
                        .foregroundStyle(Color.dockPrimaryText)
                        .dockPadding(.horizontal, 8)
                    effortRows(choices)
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
                if model.sessionID != nil, model.sessionFastEnabled != nil {
                    if stacked {
                        Color.dockBorder.frame(height: DockLayout.hairline)
                        Text("Speed")
                            .dockFont(.body, weight: .semibold)
                            .foregroundStyle(Color.dockPrimaryText)
                            .dockPadding(.horizontal, 8)
                        VStack(alignment: .leading, spacing: 1) {
                            radioRow("Standard", isSelected: !fastBinding.wrappedValue) {
                                fastBinding.wrappedValue = false
                            }
                            radioRow("Fast", isSelected: fastBinding.wrappedValue) { fastBinding.wrappedValue = true }
                        }
                        .disabled(model.isUpdatingSessionFast)
                    } else {
                        Toggle("Fast", isOn: fastBinding)
                            .toggleStyle(.dockSwitch)
                            .disabled(model.isUpdatingSessionFast)
                    }
                }
            }
        }
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
