import SwiftUI

struct VoiceQuickSettings: View {
    let recognitionStatus: VoiceRecognitionStatus
    var turnModel = TurnModelStore.shared

    @ObservedObject private var wakeActivation = VoiceWakeActivation.shared
    @AppStorage(VoiceWakeShortcut.wakeWordKey) private var listensForWakeWord = false
    @AppStorage(VoiceAnnouncer.announcesAloudKey) private var announcesAloud = false
    @AppStorage(VoiceAcknowledgment.acknowledgesKey) private var acknowledges = VoiceAcknowledgment.enabledByDefault
    @AppStorage(VoiceStageSettings.activityPillsKey) private var showsActivityCards = true
    @State private var contentHeight: CGFloat = 440

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                VoiceOutputSettings(compact: true)

                Divider().overlay(Color.dockBorderLight)
                VoiceRecognitionSettings(status: recognitionStatus, compact: true)
                TurnModelSettingsView(store: turnModel, compact: true)

                Divider().overlay(Color.dockBorderLight)
                VoiceQuickRow(title: "Wake word", detail: wakeActivation.error ?? "Listening stays on this Mac.") {
                    quickSwitch(
                        "Wake word",
                        isOn: Binding(
                            get: { listensForWakeWord },
                            set: { enabled in Task { await wakeActivation.setEnabled(enabled) } })
                    )
                    .disabled(wakeActivation.isRequesting)
                }
                VoiceQuickRow(title: "Acknowledge right away") {
                    quickSwitch("Acknowledge right away", isOn: $acknowledges)
                }
                VoiceQuickRow(title: "Announce aloud", detail: listensForWakeWord ? nil : "Needs the wake word.") {
                    quickSwitch("Announce aloud", isOn: $announcesAloud)
                        .disabled(!listensForWakeWord && !announcesAloud)
                }
                VoiceQuickRow(title: "Activity cards") {
                    quickSwitch("Activity cards", isOn: $showsActivityCards)
                }
            }
            .dockPadding(12)
            .dockPadding(.trailing, DockSpacing.control)
            .onGeometryChange(for: CGFloat.self) {
                $0.size.height
            } action: {
                contentHeight = $0
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: 360, height: min(contentHeight, 440))
    }

    private func quickSwitch(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) { EmptyView() }
            .toggleStyle(.dockSwitch).controlSize(.small).tint(Color.dockAccent)
            .accessibilityLabel(title)
    }
}

struct VoiceQuickRow<Control: View>: View {
    let title: String
    var detail: String? = nil
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: DockSpacing.tight) {
                Text(title).dockFont(.body, weight: .semibold).foregroundStyle(Color.dockPrimaryText)
                if let detail {
                    Text(detail)
                        .dockFont(.metadata)
                        .foregroundStyle(Color.dockSecondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            control()
        }
        .frame(minHeight: 28)
    }
}
