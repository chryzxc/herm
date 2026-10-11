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

    func groups(matching query: String = "", disabledIDs: Set<String>, activeID: String?) -> [ModelPickerProviderGroup] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = normalizedQuery.isEmpty
            ? options
            : options.filter {
                $0.provider.localizedCaseInsensitiveContains(normalizedQuery)
                    || $0.model.localizedCaseInsensitiveContains(normalizedQuery)
            }
        let grouped = Dictionary(grouping: filtered.filter {
            Self.isEnabled($0.id, disabledIDs: disabledIDs, activeID: activeID)
        }, by: \.provider)
        return grouped.keys.sorted().compactMap { provider in
            guard let models = grouped[provider]?.sorted(by: { $0.model.localizedStandardCompare($1.model) == .orderedAscending }) else { return nil }
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
        var disabled = Set(defaults.stringArray(forKey: Self.disabledKey) ?? [])
        if enabled {
            disabled.remove(id)
        } else {
            disabled.insert(id)
        }
        defaults.set(disabled.sorted(), forKey: Self.disabledKey)
    }

    var disabledIDs: Set<String> {
        Set(defaults.stringArray(forKey: Self.disabledKey) ?? [])
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
    nonisolated static func refreshState(isRefreshing: Bool, error: String?, optionCount: Int) -> ModelPickerRefreshState {
        if isRefreshing { return .pending }
        if error != nil { return optionCount == 0 ? .unavailable : .stale }
        return optionCount == 0 ? .empty : .success
    }

    private var refreshState: ModelPickerRefreshState {
        Self.refreshState(isRefreshing: isRefreshing, error: refreshError, optionCount: options.count)
    }

    var body: some View {
        Menu {
            pickerContent
        } label: {
            // Plain-button menu draws this SwiftUI label as-is, so long
            // provider/model names truncate instead of widening the toolbar.
            HStack(spacing: 4) {
                Text(selectedOption?.model ?? "Select model")
                    .lineLimit(1)
                    .truncationMode(.middle)
                DockIcon(.caretDown, size: 10, color: Color.dockMetadataText)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.dockHover)
        .menuIndicator(.hidden)
        .help(selectedOption?.provider ?? "")
        .accessibilityLabel("Select model, currently \(selectedOption?.displayName ?? "none")")
        .sheet(isPresented: $showingEditor) {
            ModelPickerEditorView(options: options, activeID: selectedID, disabledIDs: $disabledModelIDs)
        }
        .onAppear { reconcileActiveModelPreference() }
        .onChange(of: selectedID) { _, _ in reconcileActiveModelPreference() }
    }

    @ViewBuilder
    private var pickerContent: some View {
        TextField("Search models", text: $query)
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
                    Section(group.provider) {
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
                            .accessibilityLabel("\(group.provider), \(option.model)\(option.id == selectedID ? ", selected" : "")")
                        }
                    }
                }
            }
    }

    private var selectedOption: HermesModelOption? {
        options.first { $0.id == selectedID }
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
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        DockModal(icon: .cpu, title: "Available Models", subtitle: "Disabled models stay hidden from the picker. Hermes remains the source of truth for the catalog.", width: 400, contentPadding: 0) {
            List {
                ForEach(ModelPickerCatalog(options: options).groups()) { group in
                    Section(group.provider) {
                        ForEach(group.models) { option in
                            Toggle(isOn: Binding(
                                get: { ModelPickerCatalog.isEnabled(option.id, disabledIDs: disabledIDs, activeID: activeID) },
                                set: { enabled in
                                    guard option.id != activeID else { return }
                                    if enabled { disabledIDs.remove(option.id) } else { disabledIDs.insert(option.id) }
                                    ModelPickerPreferences().setEnabled(enabled, for: option.id)
                                }
                            )) {
                                Text(option.id == activeID ? "\(option.model) (active)" : option.model)
                            }
                            .accessibilityLabel("Enable \(group.provider) \(option.model)")
                            .disabled(option.id == activeID)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .frame(height: 360)
        } footer: {
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(.dockPrimary)
                .keyboardShortcut(.defaultAction)
        }
        .onAppear {
            disabledIDs = ModelPickerPreferences().disabledIDs
        }
    }
}
