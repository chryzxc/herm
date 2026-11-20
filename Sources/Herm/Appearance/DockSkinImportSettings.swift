import AppKit
import SwiftUI

struct DockSkinImportSettings: View {
    @ObservedObject var store: DockThemeStore
    var body: some View {
        SettingsPreferenceRow(title: "Import a skin", detail: "Copy theme JSON from T3 Themes.") {
            DockSkinImportActions(store: store, allowsRemoval: true)
        }
    }
}

struct DockSkinImportActions: View {
    @ObservedObject var store: DockThemeStore
    let allowsRemoval: Bool
    @State private var errorMessage: String?

    var body: some View {
        HStack(spacing: 8) {
            if allowsRemoval && store.selectedThemeID.importedTheme != nil {
                Button("Remove skin") {
                    do {
                        try store.removeImportedTheme(store.selectedThemeID)
                    } catch {
                        errorMessage = "The imported skin could not be removed."
                    }
                }
                .buttonStyle(.dockSecondary)
                .accessibilityHint("Removes the selected imported skin")
            }
            Button("Import from clipboard", action: importFromClipboard)
                .buttonStyle(.dockSecondary)
                .accessibilityHint("Applies a copied T3 theme")
        }
        .alert(
            "Skin import",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func importFromClipboard() {
        guard let json = NSPasteboard.general.string(forType: .string), !json.isEmpty else {
            errorMessage = "Copy theme JSON, then try again."
            return
        }
        do {
            try store.importTheme(json: json)
        } catch let error as DockThemeImportError {
            errorMessage = error.localizedDescription
        } catch {
            errorMessage = "The imported skin could not be saved."
        }
    }
}
