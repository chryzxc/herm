import AVKit
import SwiftUI

/// Native controls own playback; the attachment row keeps its file actions.
struct ChatVideoPreview: View {
    let url: URL
    var unavailableMessage = "Video playback unavailable. Use Open to try another app."
    @State private var failed = false
    @State private var startsPlayback = false
    @State private var poster: CGImage?

    nonisolated static func supports(_ url: URL) -> Bool {
        guard url.isFileURL || ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return false }
        return ["mp4", "m4v", "mov", "webm", "mkv", "avi"].contains(url.pathExtension.lowercased())
    }

    nonisolated static func poster(at url: URL) async -> CGImage? {
        guard url.isFileURL else { return nil }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 840, height: 840)
        return try? await generator.image(at: .zero).image
    }

    var body: some View {
        Group {
            if url.isFileURL && !startsPlayback {
                localPreview
            } else {
                ChatNativeVideoPlayer(url: url, playsOnMount: startsPlayback) { failed = true }
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .frame(maxWidth: 420)
        .overlay {
            if failed {
                Text(unavailableMessage)
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

    private var localPreview: some View {
        Color.dockCanvas
            .overlay {
                if let poster {
                    Image(decorative: poster, scale: 2).resizable().scaledToFit()
                }
            }
            .overlay {
                Button {
                    startsPlayback = true
                } label: {
                    DockIconLabel("Play video", icon: .play)
                }
                .buttonStyle(.dockSecondary)
            }
            .task(id: url) {
                let image = await Self.poster(at: url)
                guard !Task.isCancelled else { return }
                poster = image
            }
    }
}

struct ChatNativeVideoPlayer: NSViewRepresentable {
    let url: URL
    let playsOnMount: Bool
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
        if playsOnMount { view.player?.play() }
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
