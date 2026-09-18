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
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = normalizedQuery.isEmpty
            ? options
            : options.filter {
                $0.provider.localizedCaseInsensitiveContains(normalizedQuery)
                    || $0.model.localizedCaseInsensitiveContains(normalizedQuery)
            }
        let grouped = Dictionary(grouping: filtered, by: \.provider)
        return grouped.keys.sorted().compactMap { provider in
            guard let models = grouped[provider]?.sorted(by: { $0.model.localizedStandardCompare($1.model) == .orderedAscending }) else { return nil }
            return ModelPickerProviderGroup(provider: provider, models: models)
        }
    }

    static func reconciledSelection(selectedID: String?, options: [HermesModelOption]) -> String? {
        guard let selectedID, options.contains(where: { $0.id == selectedID }) else { return nil }
        return selectedID
    }
}

enum ModelPickerRefreshState: Equatable {
    case pending
    case success
    case empty
    case unavailable

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
    @State private var preferences = ModelPickerPreferences()

    private var catalog: ModelPickerCatalog { ModelPickerCatalog(options: options) }
    private var refreshState: ModelPickerRefreshState {
        if isRefreshing { return .pending }
        if refreshError != nil { return .unavailable }
        return options.isEmpty ? .empty : .success
    }

    var body: some View {
        Menu {
            pickerContent
        } label: {
            Text(selectedOption?.displayName ?? "Select model")
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.borderless)
        .accessibilityLabel("Select model, currently \(selectedOption?.displayName ?? "none")")
        .sheet(isPresented: $showingEditor) {
            ModelPickerEditorView(options: options, activeID: selectedID, preferences: $preferences)
        }
    }

    @ViewBuilder
    private var pickerContent: some View {
        TextField("Search models", text: $query)
            .accessibilityLabel("Search models")
        Button {
            onRefresh()
        } label: {
            Label(isRefreshing ? "Refreshing models…" : "Refresh models", systemImage: "arrow.clockwise")
        }
        .disabled(isRefreshing)
        Divider()

        switch refreshState {
        case .pending:
            Label("Loading model catalog…", systemImage: "hourglass")
        case .unavailable:
            Label("Model catalog unavailable", systemImage: "exclamationmark.triangle")
        case .empty:
            Label("No models available", systemImage: "tray")
        case .success:
            let groups = catalog.groups(matching: query).filter { group in
                group.models.contains { preferences.isEnabled($0.id) }
            }
            if groups.isEmpty {
                Label("No matching models", systemImage: "magnifyingglass")
            } else {
                ForEach(groups) { group in
                    Section(group.provider) {
                        ForEach(group.models.filter { preferences.isEnabled($0.id) }) { option in
                            Button {
                                onSelect(option)
                            } label: {
                                HStack {
                                    Text(option.model)
                                    if option.id == selectedID {
                                        Spacer()
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                            .accessibilityLabel("\(group.provider), \(option.model)\(option.id == selectedID ? ", selected" : "")")
                        }
                    }
                }
            }
        }
        Divider()
        Button("Edit available models…") {
            showingEditor = true
        }
    }

    private var selectedOption: HermesModelOption? {
        options.first { $0.id == selectedID }
    }
}

private struct ModelPickerEditorView: View {
    let options: [HermesModelOption]
    let activeID: String?
    @Binding var preferences: ModelPickerPreferences
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Available models")
                .font(.system(size: 16, weight: .semibold))
            Text("Disabled models stay hidden from the picker. Hermes remains the source of truth for the catalog.")
                .font(.system(size: 12))
                .foregroundStyle(Color.dockSecondaryText)
            List {
                ForEach(ModelPickerCatalog(options: options).groups()) { group in
                    Section(group.provider) {
                        ForEach(group.models) { option in
                            Toggle(isOn: Binding(
                                get: { preferences.isEnabled(option.id) },
                                set: { preferences.setEnabled($0, for: option.id) }
                            )) {
                                Text(option.id == activeID ? "\(option.model) (active)" : option.model)
                            }
                            .accessibilityLabel("Enable \(group.provider) \(option.model)")
                            .disabled(option.id == activeID)
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 360, height: 420)
    }
}
