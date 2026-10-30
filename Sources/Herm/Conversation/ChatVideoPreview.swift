import AVKit
import SwiftUI

/// Native controls own playback; the attachment row keeps its file actions.
struct ChatVideoPreview: View {
    let url: URL
    @State private var failed = false

    nonisolated static func supports(_ url: URL) -> Bool {
        guard url.isFileURL || ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return false }
        return ["mp4", "m4v", "mov", "webm", "mkv", "avi"].contains(url.pathExtension.lowercased())
    }

    var body: some View {
        ChatNativeVideoPlayer(url: url) { failed = true }
            .aspectRatio(16 / 9, contentMode: .fit)
            .frame(maxWidth: 420)
            .overlay {
                if failed {
                    Text("Video playback unavailable. Use Open to try another app.")
                        .dockFont(.body)
                        .foregroundStyle(Color.dockSecondaryText)
                        .multilineTextAlignment(.center)
                        .dockPadding(16)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.dockCanvas)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous))
            .accessibilityLabel("Video \(url.lastPathComponent)")
    }
}

struct ChatNativeVideoPlayer: NSViewRepresentable {
    let url: URL
    let onFailure: @MainActor () -> Void

    final class Coordinator {
        var observation: NSKeyValueObservation?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        view.showsFullScreenToggleButton = true
        let item = AVPlayerItem(url: url)
        view.player = AVPlayer(playerItem: item)
        context.coordinator.observation = item.observe(\.status, options: [.initial, .new]) { item, _ in
            guard item.status == .failed else { return }
            Task { @MainActor in onFailure() }
        }
        return view
    }

    // The parent keys this view by URL, so transcript updates preserve the playhead.
    func updateNSView(_ view: AVPlayerView, context: Context) {}

    static func dismantleNSView(_ view: AVPlayerView, coordinator: Coordinator) {
        coordinator.observation?.invalidate()
        coordinator.observation = nil
        view.player?.pause()
        view.player?.replaceCurrentItem(with: nil)
        view.player = nil
    }
}
