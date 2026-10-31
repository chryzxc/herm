import SwiftUI

/// What the toolbar's back and forward buttons need; set by the window shell.
struct DockNavigationHistory {
    var canGoBack: Bool
    var canGoForward: Bool
    var back: () -> Void
    var forward: () -> Void
}

extension EnvironmentValues {
    @Entry var dockNavigationHistory: DockNavigationHistory? = nil
}

/// Back and forward through visited pages, placed after the sidebar toggle in the leftmost title row.
/// The ⌘[ and ⌘] shortcuts live once on the window shell, not on each instance.
struct DockHistoryButtons: View {
    @Environment(\.dockNavigationHistory) private var history

    var body: some View {
        if let history {
            HStack(spacing: 0) {
                button(.caretLeft, "Back (⌘[)", enabled: history.canGoBack, action: history.back)
                button(.caretRight, "Forward (⌘])", enabled: history.canGoForward, action: history.forward)
            }
        }
    }

    private func button(_ icon: Ph, _ label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            DockIcon(icon, size: DockLayout.toolbarIconSize)
                .foregroundStyle(enabled ? Color.dockPrimaryText : Color.dockMetadataText.opacity(0.6))
                .frame(width: DockLayout.iconControlSize, height: DockLayout.iconControlSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.dockHover)
        .disabled(!enabled)
        .help(label)
        .accessibilityLabel(label.components(separatedBy: " (").first ?? label)
    }
}
