import AppKit
import SwiftUI

/// Starts a fixed-length capture while the user reproduces lag elsewhere in Herm.
struct HermPerformanceCaptureSettings: View {
    @ObservedObject private var recorder = HermPerformanceRecorder.shared

    var body: some View {
        SettingsSection(title: "Performance capture", subtitle: "Local report", tint: .dockAccent) {
            VStack(alignment: .leading, spacing: 8) {
                Text(
                    recorder.isRecording
                        ? "Recording. Scroll and click where Herm feels slow; the report opens when it ends."
                        : "Records frame drops, what redraws the workspace, and stack samples of slow seconds for \(Int(HermPerformanceRecorder.duration)) seconds."
                )
                .dockFont(.body)
                .foregroundStyle(Color.dockSecondaryText)
                .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    if recorder.isRecording {
                        Button("Stop and save") { recorder.stop() }.buttonStyle(.dockPrimary)
                    } else {
                        Button("Record \(Int(HermPerformanceRecorder.duration)) seconds") { recorder.start() }
                            .buttonStyle(.dockPrimary)
                    }
                    if let report = recorder.lastReportURL, !recorder.isRecording {
                        Button("Show last report") { NSWorkspace.shared.activateFileViewerSelecting([report]) }
                            .buttonStyle(.dockSecondary)
                    }
                }
                .dockButtonSize(.compact)
            }
        }
    }
}
