import SwiftUI

struct DockOnboardingAppearance: View {
    @ObservedObject private var theme = DockThemeStore.shared
    @AppStorage("hermes.notch.side") private var side: EdgeDockSide = .right

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("These preferences change Herm on this Mac. Your Hermes agent settings stay as they are.")
                .foregroundStyle(Color.dockSecondaryText)
            NotchDisplaySettings()
            Text("Drag the side notch to move it along either screen edge.")
                .foregroundStyle(Color.dockSecondaryText)
            Divider()
            skinPicker
        }
    }

    var skinPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose a skin").dockFont(.body, weight: .semibold)
            Text(
                side == .top
                    ? "Top island uses the Island skin. Switch to Side above to choose another skin."
                    : "Select a preview to apply it to Herm. You can change it later in Settings → Appearance."
            )
            .foregroundStyle(Color.dockSecondaryText)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 12)], spacing: 12) {
                ForEach(DockThemeID.allCases) { skin in
                    skinCard(skin)
                }
            }
            .disabled(side == .top)
        }
    }

    private func skinCard(_ skin: DockThemeID) -> some View {
        let selected = skin == (side == .top ? .island : theme.selectedThemeID)
        return Button {
            theme.selectedThemeID = skin
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                DockSkinSpecimen(theme: skin)
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(skin.title).dockFont(.body, weight: .semibold)
                            .foregroundStyle(Color.dockPrimaryText)
                        Text(skin.signature).dockFont(.body).foregroundStyle(Color.dockSecondaryText)
                    }
                    .lineLimit(1)
                    Spacer(minLength: 0)
                    DockIcon(.check).foregroundStyle(Color.dockAccent).opacity(selected ? 1 : 0)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                selected ? Color.dockAccentMuted : Color.dockSurface2,
                in: RoundedRectangle(cornerRadius: DockLayout.controlRadius)
            )
            .overlay {
                RoundedRectangle(cornerRadius: DockLayout.controlRadius)
                    .strokeBorder(
                        selected ? Color.dockAccent : Color.dockBorderLight,
                        lineWidth: DockLayout.hairline)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.dockHover)
        .accessibilityLabel(skin.title)
        .accessibilityValue(selected ? "Selected" : "")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct DockOnboardingIntelligence: View {
    @AppStorage(OnDeviceAssist.explainApprovalsKey) private var explainsApprovals = false
    @AppStorage(OnDeviceAssist.summarizeRepliesKey) private var summarizesReplies = false
    @AppStorage(OnDeviceAssist.nameSessionsKey) private var namesSessions = true
    @State private var available = OnDeviceAssist.isAvailable

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            DockCallout(
                tone: .warning, icon: .info, title: "Optional help from Apple Intelligence",
                message:
                    "Runs on this Mac using Apple’s on-device model. Your Hermes model and provider stay as configured. Generated text may be inaccurate."
            ) {
                if !available {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(OnDeviceAssist.unavailableMessage)
                            .dockFont(.body).foregroundStyle(Color.dockSecondaryText)
                        Button("Check availability") { available = OnDeviceAssist.isAvailable }
                            .buttonStyle(.dockCompact)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                assistance(
                    "Explain approvals", detail: "Add a short explanation to approval requests in Herm.",
                    value: $explainsApprovals)
                Divider().overlay(Color.dockBorderLight)
                assistance(
                    "Summarize replies",
                    detail: "Show a short summary in the notch. The original reply stays unchanged.",
                    value: $summarizesReplies)
                Divider().overlay(Color.dockBorderLight)
                assistance(
                    "Name new sessions",
                    detail: "Save generated titles to Hermes so they appear in your other clients too.",
                    value: $namesSessions)
            }
            .padding(.horizontal, 16)
            .disabled(!available)
            .background(Color.dockSurface2, in: RoundedRectangle(cornerRadius: DockLayout.controlRadius))
            .overlay {
                RoundedRectangle(cornerRadius: DockLayout.controlRadius)
                    .strokeBorder(Color.dockBorderLight, lineWidth: DockLayout.hairline)
            }
            DockCallout(
                tone: .warning, icon: .info, title: "Find Herm in your menu bar",
                message:
                    "Use your workspace shortcut to open Herm. You can revisit this guide in Settings → General → Set up Herm."
            )
        }
    }

    private func assistance(_ title: String, detail: String, value: Binding<Bool>) -> some View {
        SettingsPreferenceRow(title: title, detail: detail) {
            Toggle(title, isOn: value).toggleStyle(.dockSwitch).labelsHidden().controlSize(.small)
        }
        .padding(.vertical, 12)
    }
}
