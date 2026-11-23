import SwiftUI

/// The Status bar settings page: the master switch, every item by group, and
/// how the bar behaves. Unavailable items say why instead of hiding.
struct WorkspaceStatusBarSettings: View {
    @ObservedObject private var preferences = StatusBarPreferences.shared
    @ObservedObject private var gateways = GatewayConnectionStore.shared

    var body: some View {
        SettingsSection(
            title: "Status bar",
            subtitle:
                "Enabled items appear when their data is available and there is room in the bar.",
            tint: .dockAccent
        ) {
            SettingsPreferenceRow(title: "Show status bar", detail: "Along the bottom edge of the workspace window") {
                Toggle(isOn: $preferences.isEnabled) { EmptyView() }.switchStyle()
                    .accessibilityLabel("Show status bar")
            }
        }
        ForEach(StatusBarItem.Group.allCases, id: \.self) { group in
            SettingsSection(title: group.rawValue, subtitle: "", tint: .dockAccent) {
                ForEach(StatusBarItem.allCases.filter { $0.group == group }) { item in itemRow(item) }
            }
        }
        SettingsSection(title: "Behavior", subtitle: "", tint: .dockAccent) {
            SettingsPreferenceRow(title: "Show in floating panel", detail: "Show the status bar when space allows") {
                Toggle(isOn: $preferences.showsInFloating) { EmptyView() }.switchStyle()
                    .accessibilityLabel("Show in floating panel")
            }
            SettingsPreferenceRow(title: "Summary when you come back", detail: "What changed while you were idle") {
                DockMenuPicker(
                    title: preferences.returnSummaryMinutes == 0
                        ? "Off" : "After \(preferences.returnSummaryMinutes) min",
                    selection: $preferences.returnSummaryMinutes
                ) {
                    DockMenuOption("Off", value: 0)
                    ForEach([5, 15, 30, 60], id: \.self) { DockMenuOption("After \($0) min", value: $0) }
                }
            }
        }
    }

    private func itemRow(_ item: StatusBarItem) -> some View {
        let access = BackendReach.access(item.resource, mode: gateways.selected.mode)
        return SettingsPreferenceRow(
            title: item.title, detail: access.isAvailable ? item.detail : access.reason ?? item.detail
        ) {
            if item == .stalled {
                DockMenuPicker(title: "After \(preferences.stalledMinutes) min", selection: $preferences.stalledMinutes)
                {
                    ForEach([2, 5, 10, 20], id: \.self) { DockMenuOption("After \($0) min", value: $0) }
                }
                .disabled(!preferences.isOn(item))
            }
            if item.isLocked {
                Text("Always on").dockFont(.metadata).foregroundStyle(Color.dockSecondaryText).dockPill()
            } else {
                Toggle(isOn: preferences.binding(for: item)) {
                    EmptyView()
                }
                .switchStyle()
                .disabled(!access.isAvailable)
                .accessibilityLabel(item.title)
            }
        }
        .opacity(access.isAvailable ? 1 : 0.55)
    }

    struct QuickMenu: View {
        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: DockSpacing.section) {
                    WorkspaceStatusBarSettings()
                }
                .dockPadding(DockSpacing.section)
            }
            .frame(width: 400, height: 440)
        }
    }
}

extension Toggle {
    @MainActor
    fileprivate func switchStyle() -> some View {
        toggleStyle(.dockSwitch).controlSize(.small).tint(Color.dockAccent)
    }
}
