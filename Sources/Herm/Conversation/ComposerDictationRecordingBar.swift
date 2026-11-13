import SwiftUI

/// The meter observes microphone levels independently of the composer render tree.
struct ComposerDictationRecordingBar: View {
    @ObservedObject var reading: VoiceMeterReading
    let canSend: Bool
    let cancel: () -> Void
    let stop: () -> Void
    let send: () -> Void

    @State private var samples: [CGFloat] = []
    private let timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 8) {
            Button(action: cancel) {
                ComposerControlLabel(icon: .x)
            }
            .buttonStyle(.dockHover)
            .help("Cancel dictation")
            .accessibilityLabel("Cancel dictation")

            Canvas { context, size in
                let count = max(0, Int(size.width / 6))
                let visible = Array(samples.suffix(count))
                for index in 0..<count {
                    let sampleIndex = index - (count - visible.count)
                    let level = sampleIndex >= 0 ? visible[sampleIndex] : 0
                    let height = 3 + min(1, max(0, level)) * 17
                    let rect = CGRect(x: CGFloat(index) * 6, y: (size.height - height) / 2, width: 3, height: height)
                    context.fill(
                        Path(roundedRect: rect, cornerRadius: 1.5),
                        with: .color(Color.dockSecondaryText.opacity(level > 0.05 ? 0.8 : 0.3)))
                }
            }
            .frame(maxWidth: .infinity, minHeight: 32, maxHeight: 32)
            .accessibilityLabel("Recording dictation")
            .onReceive(timer) { _ in
                samples.append(reading.level)
                if samples.count > 200 { samples.removeFirst(samples.count - 200) }
            }

            Button(action: stop) {
                ComposerControlLabel(icon: .stop)
            }
            .buttonStyle(.dockHover)
            .help("Stop dictation and edit")
            .accessibilityLabel("Stop dictation and edit")

            Button(action: send) {
                ComposerSubmitLabel(isEnabled: canSend) {
                    DockIcon(.arrowUp)
                        .dockFont(.body, weight: .semibold)
                        .foregroundStyle(canSend ? Color.dockOnAccentText : Color.dockSecondaryText.opacity(0.5))
                }
            }
            .buttonStyle(.dockHover)
            .disabled(!canSend)
            .keyboardShortcut(.return, modifiers: [.command])
            .help("Send dictated message")
            .accessibilityLabel("Send dictated message")
        }
        .frame(minHeight: 40)
    }
}
