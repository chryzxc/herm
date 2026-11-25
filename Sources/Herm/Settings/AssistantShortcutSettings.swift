import Contacts
import SwiftUI

struct AssistantShortcutSettings: View {
    @AppStorage(AssistantShortcutPreferences.key) private var saved = Data()
    @State private var installed: [AssistantShortcutPreferences.Shortcut] = []
    @State private var selection: UUID?
    @State private var alias = ""
    @State private var loading = false
    @State private var listFailed = false
    @State private var contacts = CNContactStore.authorizationStatus(for: .contacts)
    @State private var requestingContacts = false

    private var preferences: AssistantShortcutPreferences {
        (try? JSONDecoder().decode(AssistantShortcutPreferences.self, from: saved)) ?? AssistantShortcutPreferences()
    }

    var body: some View {
        SettingsPreferenceRow(
            title: "Voice Shortcuts",
            detail: listFailed
                ? "Shortcuts couldn't load. Refresh to try again."
                : "Save a spoken alias for a shortcut on this Mac. Herm asks before running it."
        ) {
            Button(loading ? "Refreshing…" : "Refresh Shortcuts") {
                Task { await refresh() }
            }
            .buttonStyle(.dockSecondary)
            .disabled(loading)
        }
        if !installed.isEmpty {
            SettingsPreferenceRow(title: "New shortcut alias", detail: "Say “run shortcut” followed by the alias.") {
                DockMenuPicker(
                    "Shortcut", title: installed.first(where: { $0.id == selection })?.name ?? "Choose Shortcut",
                    selection: $selection
                ) {
                    ForEach(installed) { shortcut in Text(shortcut.name).tag(Optional(shortcut.id)) }
                }
                DockTextField("Alias", text: $alias).textFieldStyle(.dockGlass).frame(width: 110)
                Button("Add", action: addAlias).buttonStyle(.dockSecondary)
                    .disabled(selection == nil || AssistantIntent.normalized(alias).isEmpty)
            }
        }
        ForEach(preferences.aliases) { binding in
            SettingsPreferenceRow(title: binding.name, detail: binding.shortcut.name) {
                Button("Remove") { update { $0.aliases.removeAll { $0.id == binding.id } } }.buttonStyle(.dockSecondary)
            }
        }
        ForEach(AssistantChannel.allCases, id: \.self) { channel in
            SettingsPreferenceRow(
                title: "\(channel.title) sending shortcut",
                detail:
                    "Choose a shortcut configured to receive Herm’s message JSON and return “submitted” after handing it off."
            ) {
                sendingPicker(channel)
            }
        }
        SettingsPreferenceRow(
            title: "Contacts for voice",
            detail: contacts == .authorized
                ? "Herm can look up spoken names for voice drafts."
                : "Allow name lookup for voice drafts. You can also speak a full address or phone number."
        ) {
            if contacts == .notDetermined {
                Button(requestingContacts ? "Connecting…" : "Connect Contacts") {
                    Task {
                        requestingContacts = true
                        _ = try? await CNContactStore().requestAccess(for: .contacts)
                        contacts = CNContactStore.authorizationStatus(for: .contacts)
                        requestingContacts = false
                    }
                }
                .buttonStyle(.dockSecondary)
                .disabled(requestingContacts)
            } else if contacts != .authorized {
                Text("Manage access in System Settings")
                    .dockFont(.body)
                    .foregroundStyle(Color.dockSecondaryText)
            }
        }
    }

    private func sendingPicker(_ channel: AssistantChannel) -> some View {
        let current = preferences.shortcut(for: channel)
        let selection = Binding<UUID?>(
            get: { preferences.shortcut(for: channel)?.id },
            set: { id in
                let next = installed.first(where: { $0.id == id })
                update {
                    if channel == .mail { $0.mail = next } else { $0.messages = next }
                }
            })
        return DockMenuPicker("\(channel.title) shortcut", title: current?.name ?? "None", selection: selection) {
            Text("None").tag(nil as UUID?)
            if let current, !installed.contains(where: { $0.id == current.id }) {
                Text(current.name).tag(Optional(current.id))
            }
            ForEach(installed) { shortcut in Text(shortcut.name).tag(Optional(shortcut.id)) }
        }
        .disabled(installed.isEmpty && current == nil)
    }

    private func addAlias() {
        let name = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let shortcut = installed.first(where: { $0.id == selection }) else { return }
        let binding = AssistantShortcutPreferences.Alias(name: name, shortcut: shortcut)
        update {
            if let index = $0.aliases.firstIndex(where: { $0.id == binding.id }) {
                $0.aliases[index] = binding
            } else {
                $0.aliases.append(binding)
            }
        }
        alias = ""
    }

    private func refresh() async {
        loading = true
        defer { loading = false }
        do {
            installed = try await AssistantShortcuts.installed()
            if !installed.contains(where: { $0.id == selection }) { selection = nil }
            listFailed = false
        } catch {
            listFailed = true
        }
    }

    private func update(_ edit: (inout AssistantShortcutPreferences) -> Void) {
        var values = preferences
        edit(&values)
        if let data = try? JSONEncoder().encode(values) { saved = data }
    }
}
