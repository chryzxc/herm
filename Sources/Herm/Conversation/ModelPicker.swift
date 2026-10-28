import SwiftUI

struct ModelPickerProviderGroup: Identifiable, Equatable {
    let provider: String
    let models: [HermesModelOption]

    var id: String { provider }
}

struct ModelPickerCatalog: Equatable {
    let options: [HermesModelOption]

    init(options: [HermesModelOption]) {
        var seen = Set<String>()
        self.options = options.filter { seen.insert($0.id).inserted }
    }

    func groups(matching query: String = "") -> [ModelPickerProviderGroup] {
        groups(matching: query, disabledIDs: [], activeID: nil)
    }

    func groups(matching query: String = "", disabledIDs: Set<String>, activeID: String?) -> [ModelPickerProviderGroup]
    {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered =
            normalizedQuery.isEmpty
            ? options
            : options.filter {
                $0.provider.localizedCaseInsensitiveContains(normalizedQuery)
                    || $0.model.localizedCaseInsensitiveContains(normalizedQuery)
            }
        let grouped = Dictionary(
            grouping: filtered.filter {
                Self.isEnabled($0.id, disabledIDs: disabledIDs, activeID: activeID)
            }, by: \.provider)
        return grouped.keys.sorted().compactMap { provider in
            guard
                let models = grouped[provider]?.sorted(by: {
                    $0.model.localizedStandardCompare($1.model) == .orderedAscending
                })
            else { return nil }
            return ModelPickerProviderGroup(provider: provider, models: models)
        }
    }

    static func reconciledSelection(selectedID: String?, options: [HermesModelOption]) -> String? {
        guard let selectedID, options.contains(where: { $0.id == selectedID }) else { return nil }
        return selectedID
    }

    static func isEnabled(_ id: String, disabledIDs: Set<String>, activeID: String?) -> Bool {
        id == activeID || !disabledIDs.contains(id)
    }

    static func reconciledDisabledIDs(_ disabledIDs: Set<String>, activeID: String?) -> Set<String> {
        guard let activeID else { return disabledIDs }
        var reconciled = disabledIDs
        reconciled.remove(activeID)
        return reconciled
    }
}

enum ModelPickerRefreshState: Equatable {
    case pending
    case success
    case empty
    case unavailable
    case stale

    var isPending: Bool { self == .pending }
    var isAvailable: Bool { self == .success }
    var isEmpty: Bool { self == .empty }
    var isUnavailable: Bool { self == .unavailable }
}

struct ModelPickerPreferences {
    private static let disabledKey = "hermes.dock.model-picker.disabled.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func isEnabled(_ id: String) -> Bool {
        !(defaults.stringArray(forKey: Self.disabledKey) ?? []).contains(id)
    }

    func setEnabled(_ enabled: Bool, for id: String) {
        setEnabled(enabled, for: [id])
    }

    func setEnabled(_ enabled: Bool, for ids: [String]) {
        var disabled = Set(defaults.stringArray(forKey: Self.disabledKey) ?? [])
        if enabled {
            disabled.subtract(ids)
        } else {
            disabled.formUnion(ids)
        }
        defaults.set(disabled.sorted(), forKey: Self.disabledKey)
    }

    var disabledIDs: Set<String> {
        Set(defaults.stringArray(forKey: Self.disabledKey) ?? [])
    }

    func unselectAll(options: [HermesModelOption], activeID: String?) -> Set<String> {
        let disabled = ModelPickerCatalog.reconciledDisabledIDs(
            disabledIDs.union(options.map(\.id)), activeID: activeID
        )
        defaults.set(disabled.sorted(), forKey: Self.disabledKey)
        return disabled
    }
}

struct ModelPickerView: View {
    let options: [HermesModelOption]
    let selectedID: String?
    let isRefreshing: Bool
    let refreshError: String?
    let onRefresh: () -> Void
    let onSelect: (HermesModelOption) -> Void

    @State private var query = ""
    @State private var showingEditor = false
    @State private var disabledModelIDs = ModelPickerPreferences().disabledIDs

    private var catalog: ModelPickerCatalog { ModelPickerCatalog(options: options) }
    nonisolated static func refreshState(isRefreshing: Bool, error: String?, optionCount: Int)
        -> ModelPickerRefreshState
    {
        if isRefreshing { return .pending }
        if error != nil { return optionCount == 0 ? .unavailable : .stale }
        return optionCount == 0 ? .empty : .success
    }

    private var refreshState: ModelPickerRefreshState {
        Self.refreshState(isRefreshing: isRefreshing, error: refreshError, optionCount: options.count)
    }

    var body: some View {
        DockMenu {
            pickerContent
        } label: {
            // Plain-button menu draws this SwiftUI label as-is, so long
            // provider/model names truncate instead of widening the toolbar.
            HStack(spacing: 4) {
                // A MoA "model" is a preset name; say which mode is driving the chat.
                if selectedOption?.provider == "moa" {
                    DockIcon(.usersThree, size: 12, color: Color.dockAccent)
                }
                Text(selectedOption.map { $0.provider == "moa" ? "MoA · \($0.model)" : $0.model } ?? "Select model")
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let notice = selectedPeakNotice, notice.isPeak {
                    DockIcon(.warning, size: 11, color: Color.dockWarning)
                }
                DockIcon(.caretDown, size: 10, color: Color.dockMetadataText)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.dockHover)
        .help([selectedOption?.provider, selectedPeakNotice?.text].compactMap { $0 }.joined(separator: " · "))
        .accessibilityLabel("Select model, currently \(selectedOption?.displayName ?? "none")")
        .dockSheet(isPresented: $showingEditor) {
            ModelPickerEditorView(options: options, activeID: selectedID, disabledIDs: $disabledModelIDs)
        }
        .onAppear { reconcileActiveModelPreference() }
        .onChange(of: selectedID) { _, _ in reconcileActiveModelPreference() }
    }

    @ViewBuilder
    private var pickerContent: some View {
        DockTextField("Search models", text: $query)
            .accessibilityLabel("Search models")
        Button {
            onRefresh()
        } label: {
            Label(isRefreshing ? "Refreshing models…" : "Refresh models", icon: .arrowClockwise)
        }
        .disabled(isRefreshing)
        Divider()

        switch refreshState {
        case .pending:
            Label("Loading model catalog…", icon: .hourglass)
        case .unavailable:
            Label("Model catalog unavailable", icon: .warning)
        case .empty:
            Label("No models available", icon: .tray)
        case .stale:
            Label("Model catalog unavailable; showing last results", icon: .warning)
            modelRows
        case .success:
            modelRows
        }
        Divider()
        Button("Edit available models…") {
            showingEditor = true
        }
    }

    @ViewBuilder
    private var modelRows: some View {
        let groups = catalog.groups(matching: query, disabledIDs: disabledModelIDs, activeID: selectedID)
        if groups.isEmpty {
            Label("No matching models", icon: .magnifyingGlass)
        } else {
            ForEach(groups) { group in
                DockMenuSection(group.provider) {
                    if let notice = ProviderPeakSchedule.quotaID(forProvider: group.provider)
                        .flatMap({ ProviderPeakSchedule.notice(forQuotaID: $0) })
                    {
                        let color = notice.isPeak ? Color.dockWarning : Color.dockSuccess
                        HStack(spacing: 6) {
                            DockIcon(notice.isPeak ? .warning : .checkCircle, size: 12, color: color)
                            Text(notice.text).foregroundStyle(color)
                        }
                    }
                    ForEach(group.models) { option in
                        Button {
                            onSelect(option)
                        } label: {
                            HStack {
                                Text(option.model)
                                if option.id == selectedID {
                                    Spacer()
                                    DockIcon(.check)
                                }
                            }
                        }
                        .accessibilityLabel(
                            "\(group.provider), \(option.model)\(option.id == selectedID ? ", selected" : "")")
                    }
                }
            }
        }
    }

    private var selectedPeakNotice: ProviderPeakSchedule.Notice? {
        selectedOption.flatMap { ProviderPeakSchedule.quotaID(forProvider: $0.provider) }
            .flatMap { ProviderPeakSchedule.notice(forQuotaID: $0) }
    }

    private var selectedOption: HermesModelOption? {
        if let match = options.first(where: { $0.id == selectedID }) { return match }
        // Hermes' default may sit outside the explicit catalog; still name it.
        guard let selectedID, let bar = selectedID.firstIndex(of: "|") else { return nil }
        return HermesModelOption(
            provider: String(selectedID[..<bar]),
            model: String(selectedID[selectedID.index(after: bar)...]))
    }

    private func reconcileActiveModelPreference() {
        let reconciled = ModelPickerCatalog.reconciledDisabledIDs(disabledModelIDs, activeID: selectedID)
        guard reconciled != disabledModelIDs else { return }
        disabledModelIDs = reconciled
        if let selectedID {
            ModelPickerPreferences().setEnabled(true, for: selectedID)
        }
    }
}

private struct ModelPickerEditorView: View {
    let options: [HermesModelOption]
    let activeID: String?
    @Binding var disabledIDs: Set<String>
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    private var groups: [ModelPickerProviderGroup] { ModelPickerCatalog(options: options).groups(matching: query) }

    var body: some View {
        DockModal(
            icon: .cpu, title: "Available Models",
            subtitle: "Choose which Hermes models appear in the picker.",
            width: 440, contentPadding: 0
        ) {
            VStack(spacing: 0) {
                searchField
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 12)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if groups.isEmpty {
                            Text(options.isEmpty ? "No models available" : "No matching models")
                                .dockFont(.body)
                                .foregroundStyle(Color.dockSecondaryText)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 40)
                        }
                        ForEach(groups) { providerSection($0) }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
                }
                .frame(height: 380)
            }
        } footer: {
            Text("\(enabledCount) of \(options.count) shown")
                .dockFont(.metadata)
                .foregroundStyle(Color.dockMetadataText)
                .monospacedDigit()
            Spacer()
            Button("Hide All") {
                disabledIDs = ModelPickerPreferences().unselectAll(options: options, activeID: activeID)
            }
            .buttonStyle(.dockSecondary)
            .disabled(!options.contains { $0.id != activeID && !disabledIDs.contains($0.id) })
            .help("Hide all models except the active model.")
            Button("Done") { dismiss() }
                .buttonStyle(.dockPrimary)
                .keyboardShortcut(.defaultAction)
        }
        .onAppear {
            disabledIDs = ModelPickerPreferences().disabledIDs
        }
    }

    private var enabledCount: Int {
        options.filter { isEnabled($0.id) }.count
    }

    private func isEnabled(_ id: String) -> Bool {
        ModelPickerCatalog.isEnabled(id, disabledIDs: disabledIDs, activeID: activeID)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            DockIcon(.magnifyingGlass, size: 13, color: .dockMetadataText)
            DockTextField("Search models", text: $query)
                .textFieldStyle(.plain)
                .dockFont(.body)
                .foregroundStyle(Color.dockPrimaryText)
                .accessibilityLabel("Search models")
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    DockIcon(.xCircle, size: 13, color: .dockMetadataText)
                }
                .buttonStyle(.dockHover)
                .help("Clear search")
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 32)
        .background(DockThemeShape(cornerRadius: DockLayout.controlRadius).dockSurfaceFill(Color.dockControlSurface))
    }

    private func providerSection(_ group: ModelPickerProviderGroup) -> some View {
        let toggleable = group.models.map(\.id).filter { $0 != activeID }
        let allShown = toggleable.allSatisfy(isEnabled)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(group.provider)
                    .dockFont(.compactStatus, weight: .semibold, design: .monospaced)
                    .tracking(0.6)
                    .foregroundStyle(Color.dockMetadataText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(group.models.filter { isEnabled($0.id) }.count)/\(group.models.count)")
                    .dockFont(.compactStatus)
                    .foregroundStyle(Color.dockMetadataText.opacity(0.7))
                    .monospacedDigit()
                Spacer(minLength: 8)
                if !toggleable.isEmpty {
                    Button(allShown ? "Hide all" : "Show all") {
                        setEnabled(!allShown, for: toggleable)
                    }
                    .buttonStyle(.dockLink)
                    .dockFont(.metadata)
                    .accessibilityLabel("\(allShown ? "Hide" : "Show") all \(group.provider) models")
                }
            }
            VStack(spacing: 0) {
                ForEach(Array(group.models.enumerated()), id: \.element.id) { index, option in
                    if index > 0 {
                        Color.dockBorderLight.frame(height: DockLayout.hairline).padding(.leading, 12)
                    }
                    modelRow(option, provider: group.provider)
                }
            }
            .background(
                DockThemeShape(cornerRadius: DockLayout.controlRadius).dockSurfaceFill(
                    Color.dockSurface2, stroke: Color.dockBorderLight))
        }
    }

    private func modelRow(_ option: HermesModelOption, provider: String) -> some View {
        let isActive = option.id == activeID
        return Toggle(
            isOn: Binding(
                get: { isEnabled(option.id) },
                set: { setEnabled($0, for: [option.id]) }
            )
        ) {
            HStack(spacing: 6) {
                Text(option.model)
                    .dockFont(.body)
                    .foregroundStyle(isEnabled(option.id) ? Color.dockPrimaryText : Color.dockSecondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if isActive {
                    Text("In use")
                        .dockFont(.compactStatus, weight: .medium)
                        .foregroundStyle(Color.dockAccent)
                }
                Spacer(minLength: 8)
            }
        }
        .toggleStyle(.dockSwitch)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .disabled(isActive)
        .help(isActive ? "The active model always stays in the picker." : "")
        .accessibilityLabel("Show \(provider) \(option.model) in the picker")
    }

    private func setEnabled(_ enabled: Bool, for ids: [String]) {
        let ids = ids.filter { $0 != activeID }
        guard !ids.isEmpty else { return }
        if enabled {
            disabledIDs.subtract(ids)
        } else {
            disabledIDs.formUnion(ids)
        }
        ModelPickerPreferences().setEnabled(enabled, for: ids)
    }
}
