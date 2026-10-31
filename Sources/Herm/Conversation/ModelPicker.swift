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
    var effortModel: DockModel? = nil
    var effortSelection: Binding<HermesReasoningVariant?> = .constant(nil)

    @Environment(\.dockWorkspaceScale) private var workspaceScale
    @State private var query = ""
    @State private var showingEditor = false
    @State private var providerFilter: String?
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

    private var effortStatus: String? {
        guard let effortModel else { return nil }
        return ComposerEffortPresentation(
            selection: effortSelection.wrappedValue, choices: effortModel.effortCatalog?.choices(for: selectedID),
            wire: effortModel.sessionID == nil ? nil : effortModel.sessionReasoningWire,
            pending: effortModel.isUpdatingSessionModel || effortModel.isUpdatingSessionReasoning,
            loading: effortModel.isEffortCatalogPending, stale: effortModel.sessionReasoningStale
        ).status
    }

    var body: some View {
        DockMenu {
            pickerContent
                .dockPadding(.vertical, 6)
                .dockMenuKeepOpen()
        } label: {
            // Plain-button menu draws this SwiftUI label as-is, so long
            // provider/model names truncate instead of widening the toolbar.
            HStack(spacing: 4) {
                if let provider = selectedOption?.provider {
                    ProviderMarkBadge(mark: ProviderMark(hermesProvider: provider), size: 16)
                }
                Text(selectedOption.map { $0.provider == "moa" ? "MoA · \($0.model)" : $0.model } ?? "Select model")
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let effortStatus {
                    Text("· \(effortStatus)")
                        .foregroundStyle(Color.dockSecondaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(1)
                }
                if let notice = selectedPeakNotice, notice.isPeak {
                    DockIcon(.warning, size: 11, color: Color.dockWarning)
                }
                DockIcon(.caretDown, size: 10, color: Color.dockMetadataText)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.dockHover)
        .help([selectedOption?.provider, selectedPeakNotice?.text].compactMap { $0 }.joined(separator: " · "))
        .accessibilityLabel(
            "Select model\(effortStatus == nil ? "" : " and effort"), currently \(selectedOption?.displayName ?? "none")"
                + (effortStatus.map { ", effort \($0)" } ?? "")
        )
        .dockSheet(isPresented: $showingEditor) {
            ModelPickerEditorView(options: options, activeID: selectedID, disabledIDs: $disabledModelIDs)
        }
        .onAppear { reconcileActiveModelPreference() }
        .onChange(of: selectedID) { _, _ in reconcileActiveModelPreference() }
    }

    /// Two panes: a provider rail on the left, the chosen provider's models on the right.
    /// Searching ignores the rail and lists matches from every provider.
    var pickerContent: some View {
        let groups = catalog.groups(matching: "", disabledIDs: disabledModelIDs, activeID: selectedID)
        let railProvider =
            [providerFilter, selectedOption?.provider].lazy.compactMap { $0 }
            .first { name in groups.contains { $0.provider == name } } ?? groups.first?.provider
        return HStack(alignment: .top, spacing: 0) {
            if groups.count > 1 { providerRail(groups, active: railProvider) }
            VStack(alignment: .leading, spacing: 8) {
                if let railProvider, query.isEmpty {
                    Text(railProvider)
                        .dockFont(.body, weight: .semibold)
                        .foregroundStyle(Color.dockPrimaryText)
                        .dockPadding(.horizontal, 8)
                }
                HStack(spacing: 8) {
                    DockIcon(.magnifyingGlass, size: 13, color: .dockMetadataText)
                    TextField(
                        "", text: $query,
                        prompt: Text("Search models").foregroundColor(Color.dockSecondaryText)
                    )
                    .textFieldStyle(.plain)
                    .dockFont(.body)
                    .foregroundStyle(Color.dockPrimaryText)
                    .accessibilityLabel("Search models")
                    if !query.isEmpty {
                        Button {
                            query = ""
                        } label: {
                            DockIcon(.xCircle, size: 13, color: .dockSecondaryText)
                        }
                        .buttonStyle(.dockHover)
                        .help("Clear search")
                        .accessibilityLabel("Clear search")
                    }
                }
                .dockPadding(.horizontal, 10)
                .frame(minHeight: 32)
                .background(
                    DockThemeShape(cornerRadius: DockLayout.controlRadius)
                        .dockSurfaceFill(Color.dockControlSurface)
                )
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        modelPane(provider: query.isEmpty ? railProvider : nil)
                    }
                }
                .frame(maxHeight: 220)
                if let effortModel {
                    Color.dockBorderLight.frame(height: DockLayout.hairline)
                    ComposerEffortControls(model: effortModel, modelID: selectedID, selection: effortSelection)
                        .dockPadding(.horizontal, 8)
                }
                Color.dockBorderLight.frame(height: DockLayout.hairline)
                HStack(spacing: 4) {
                    Button {
                        onRefresh()
                    } label: {
                        Label(isRefreshing ? "Refreshing…" : "Refresh", icon: .arrowClockwise)
                    }
                    .disabled(isRefreshing)
                    Button("Edit models…") { showingEditor = true }
                }
            }
            .dockPadding(.leading, 6)
            .frame(width: 270, alignment: .leading)
        }
        .background(alignment: .leading) {
            if groups.count > 1 {
                GeometryReader { geometry in
                    let inset = DockWorkspaceScale.spacing(6, scale: workspaceScale)
                    Color.dockSurface2
                        .frame(width: 36 + 2 * inset, height: geometry.size.height + 4 * inset)
                        .offset(x: -inset, y: -2 * inset)
                }
                .allowsHitTesting(false)
            }
        }
    }

    private func providerRail(_ groups: [ModelPickerProviderGroup], active: String?) -> some View {
        VStack(spacing: 4) {
            ForEach(groups) { group in
                Button {
                    providerFilter = group.provider
                    query = ""
                } label: {
                    ProviderMarkBadge(mark: ProviderMark(hermesProvider: group.provider), size: 28)
                        .opacity(group.provider == active ? 1 : 0.65)
                        .frame(width: 36, height: 36)
                        .background(
                            DockThemeShape(cornerRadius: DockLayout.controlRadius)
                                .dockSurfaceFill(group.provider == active ? Color.dockControlSurface : .clear)
                        )
                        .overlay(
                            DockThemeShape(cornerRadius: DockLayout.controlRadius)
                                .stroke(group.provider == active ? Color.dockBorderStrong : .clear, lineWidth: 1)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.dockHover)
                .accessibilityAddTraits(group.provider == active ? .isSelected : [])
                .help(group.provider)
                .accessibilityLabel("\(group.provider) models")
            }
        }
        .dockPadding(.trailing, 6)
    }

    @ViewBuilder
    private func modelPane(provider: String?) -> some View {
        switch refreshState {
        case .pending:
            Label("Loading model catalog…", icon: .hourglass)
        case .unavailable:
            Label("Model catalog unavailable", icon: .warning)
        case .empty:
            Label("No models available", icon: .tray)
        case .stale:
            Label("Model catalog unavailable; showing last results", icon: .warning)
            modelRows(provider: provider)
        case .success:
            modelRows(provider: provider)
        }
    }

    @ViewBuilder
    private func modelRows(provider: String?) -> some View {
        let groups = catalog.groups(matching: query, disabledIDs: disabledModelIDs, activeID: selectedID)
            .filter { provider == nil || $0.provider == provider }
        if groups.isEmpty {
            Label("No matching models", icon: .magnifyingGlass)
        } else {
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 1) {
                    if provider == nil {
                        Text(group.provider)
                            .dockFont(.compactStatus, weight: .semibold)
                            .foregroundStyle(Color.dockMetadataText)
                            .dockPadding(.horizontal, 8)
                            .dockPadding(.top, 6)
                    }
                    if let notice = ProviderPeakSchedule.quotaID(forProvider: group.provider)
                        .flatMap({ ProviderPeakSchedule.notice(forQuotaID: $0) })
                    {
                        let color = notice.isPeak ? Color.dockWarning : Color.dockSuccess
                        HStack(spacing: 6) {
                            DockIcon(notice.isPeak ? .warning : .checkCircle, size: 12, color: color)
                            Text(notice.text).foregroundStyle(color)
                        }
                        .dockPadding(.horizontal, 8)
                    }
                    ForEach(group.models) { option in
                        let isSelected = option.id == selectedID
                        Button {
                            onSelect(option)
                        } label: {
                            HStack(spacing: 8) {
                                Circle()
                                    .stroke(isSelected ? Color.dockPrimaryText : Color.dockSecondaryText, lineWidth: 1)
                                    .frame(width: 15, height: 15)
                                    .overlay {
                                        if isSelected {
                                            DockIcon(.check, size: 10, color: Color.dockPrimaryText)
                                        }
                                    }
                                Text(option.model)
                                    .dockFont(.body, weight: isSelected ? .semibold : .regular)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 8)
                            }
                        }
                        .accessibilityLabel("\(group.provider), \(option.model)\(isSelected ? ", selected" : "")")
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
            title: "Available Models",
            subtitle: "Choose which Hermes models appear in the picker.",
            width: 440, contentPadding: 0
        ) {
            VStack(spacing: 0) {
                searchField
                    .dockPadding(.horizontal, 20)
                    .dockPadding(.top, 16)
                    .dockPadding(.bottom, 12)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if groups.isEmpty {
                            Text(options.isEmpty ? "No models available" : "No matching models")
                                .dockFont(.body)
                                .foregroundStyle(Color.dockSecondaryText)
                                .frame(maxWidth: .infinity)
                                .dockPadding(.vertical, 40)
                        }
                        ForEach(groups) { providerSection($0) }
                    }
                    .dockPadding(.horizontal, 20)
                    .dockPadding(.bottom, 16)
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
        .dockPadding(.horizontal, 10)
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
                        Color.dockBorderLight.frame(height: DockLayout.hairline).dockPadding(.leading, 12)
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
        .dockPadding(.horizontal, 12)
        .dockPadding(.vertical, 7)
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
