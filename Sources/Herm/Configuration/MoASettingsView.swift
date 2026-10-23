import SwiftUI

/// Edits Hermes' Mixture of Agents presets (`/api/model/moa`), matching Hermes
/// Desktop's Settings > Model > Mixture of Agents. Every edit saves immediately;
/// Hermes is the only writer and its normalized reply replaces local state.
struct MoASettingsView: View {
    @ObservedObject var model: DockModel
    let service: HermesWorkflowRPC?

    @State private var config: HermesMoAConfig?
    @State private var selectedPreset = ""
    @State private var isSaving = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(
                "Reference models advise once per turn; the aggregator runs the tool loop and is billed for the run. Choose a Mixture of Agents preset from a model picker to use it."
            )
            .dockFont(.body)
            .foregroundStyle(Color.dockMetadataText)
            .fixedSize(horizontal: false, vertical: true)

            if let config {
                presetEditor(config)
            } else if error == nil {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text("Loading Mixture of Agents presets…").dockFont(.body).foregroundStyle(Color.dockSecondaryText)
                }
            }
            if let error {
                HStack(spacing: 8) {
                    Text(error).dockFont(.body).foregroundStyle(Color.dockWarning)
                    if config == nil {
                        DockAsyncButton("Retry") { await load() }.buttonStyle(.dockCompact)
                    }
                }
            }
        }
        .task { await load() }
    }

    @ViewBuilder
    private func presetEditor(_ config: HermesMoAConfig) -> some View {
        let preset = config.presetNames.contains(selectedPreset) ? selectedPreset : config.defaultPreset
        let references = config.references(preset)

        HStack(spacing: 8) {
            if config.presetNames.count > 1 {
                DockMenu {
                    DockMenuChoices(selection: $selectedPreset) {
                        ForEach(config.presetNames, id: \.self) { name in
                            DockMenuOption(name == config.defaultPreset ? "\(name) (default)" : name, value: name)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(preset).dockFont(.body, weight: .medium).foregroundStyle(Color.dockPrimaryText)
                        DockIcon(.caretDown, size: 10, color: Color.dockMetadataText)
                    }
                }
                .buttonStyle(.dockHover)
                .fixedSize()
            } else {
                Text(preset).dockFont(.body, weight: .medium).foregroundStyle(Color.dockPrimaryText)
            }
            Spacer(minLength: 8)
            if isSaving { ProgressView().controlSize(.small) }
            Toggle(
                "Enabled",
                isOn: Binding(
                    get: { isListed(preset, config) },
                    set: { enabled in save { $0.update(preset, enabled: enabled) } }
                )
            )
            .toggleStyle(.switch)
            .controlSize(.small)
            .dockFont(.body)
            .help("Show this preset under Mixture of Agents in model pickers")
        }

        ForEach(Array(references.enumerated()), id: \.offset) { index, slot in
            slotRow(title: "Reference \(index + 1)", slot: slot) { picked in
                var updated = references
                updated[index].provider = picked.provider
                updated[index].model = picked.model
                save { $0.update(preset, references: updated) }
            } trailing: {
                Toggle(
                    "",
                    isOn: Binding(
                        get: { slot.enabled },
                        set: { enabled in
                            var updated = references
                            updated[index].enabled = enabled
                            save { $0.update(preset, references: updated) }
                        }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .accessibilityLabel("\(slot.enabled ? "Disable" : "Enable") reference \(index + 1)")
                Button {
                    var updated = references
                    updated.remove(at: index)
                    save { $0.update(preset, references: updated) }
                } label: {
                    DockIcon(.trash, size: 12, color: Color.dockSecondaryText)
                }
                .buttonStyle(.dockHover)
                .disabled(references.count <= 1)
                .accessibilityLabel("Remove reference \(index + 1)")
            }
        }

        Button("Add reference model") {
            guard let seed = config.aggregator(preset) ?? references.last else { return }
            save {
                $0.update(preset, references: references + [HermesMoASlot(provider: seed.provider, model: seed.model)])
            }
        }
        .buttonStyle(.dockCompact)

        if let aggregator = config.aggregator(preset) {
            slotRow(title: "Aggregator", slot: aggregator) { picked in
                var updated = aggregator
                updated.provider = picked.provider
                updated.model = picked.model
                save { $0.update(preset, aggregator: updated) }
            } trailing: {
                EmptyView()
            }
        }
    }

    private func slotRow<Trailing: View>(
        title: String,
        slot: HermesMoASlot,
        onPick: @escaping (HermesModelOption) -> Void,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .dockFont(.body)
                .foregroundStyle(Color.dockSecondaryText)
                .frame(width: 84, alignment: .leading)
            DockMenu {
                // A MoA preset cannot advise another preset; Hermes rejects recursion.
                ForEach(model.runtimeModelOptions.filter { $0.provider != "moa" }) { option in
                    Button(option.displayName) { onPick(option) }
                }
            } label: {
                HStack(spacing: 6) {
                    Text("\(slot.provider)  ·  \(slot.model)")
                        .dockFont(.body, weight: .medium)
                        .foregroundStyle(slot.enabled ? Color.dockPrimaryText : Color.dockMetadataText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    DockIcon(.caretUpDown, size: 10, color: Color.dockMetadataText)
                }
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(
                    RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous).dockSurfaceFill(
                        Color.dockControlSurface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous).stroke(
                        Color.dockBorder, lineWidth: 0.5)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.dockHover)
            .disabled(isSaving || model.runtimeModelOptions.isEmpty)
            trailing()
        }
    }

    /// Hermes lists MoA in pickers only once the user's own config enables a
    /// preset, so the switch reflects the picker catalog, not the defaults.
    private func isListed(_ preset: String, _ config: HermesMoAConfig) -> Bool {
        config.isEnabled(preset) && model.runtimeModelOptions.contains { $0.provider == "moa" && $0.model == preset }
    }

    private func load() async {
        guard let service else {
            error = "Connect to Hermes to edit Mixture of Agents presets."
            return
        }
        error = nil
        do {
            let loaded = try await service.moaConfig()
            config = loaded
            if selectedPreset.isEmpty { selectedPreset = loaded.defaultPreset }
        } catch {
            self.error =
                "Hermes could not load Mixture of Agents presets: \(HermesDiagnosticsService.safeSummary(error.localizedDescription))"
        }
    }

    private func save(_ edit: (inout HermesMoAConfig) -> Void) {
        guard let service, var draft = config, !isSaving else { return }
        edit(&draft)
        isSaving = true
        error = nil
        Task {
            defer { isSaving = false }
            do {
                config = try await service.saveMoAConfig(draft)
                model.refreshRuntimeModelOptions()
            } catch {
                self.error =
                    "Hermes did not save the preset: \(HermesDiagnosticsService.safeSummary(error.localizedDescription))"
            }
        }
    }
}
