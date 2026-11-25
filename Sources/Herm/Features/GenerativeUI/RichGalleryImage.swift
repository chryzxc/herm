import SwiftUI

/// A bitmap, never a webpage; the browser is only an explicit fallback.
struct RichGalleryImage: View {
    let url: URL
    let title: String
    @Environment(\.richGlance) private var glance
    @Environment(\.richDefersRemoteMedia) private var defersRemoteMedia
    @State private var loadRequested = false
    @State private var image: CGImage?
    @State private var failed = false

    private var canLoad: Bool {
        url.scheme == "data"
            || (!defersRemoteMedia
                && (loadRequested || RichResourcePolicy.previewsGalleryImageAutomatically(url)))
    }

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 2).resizable().scaledToFit()
                    .accessibilityLabel(title)
            } else {
                VStack(spacing: 8) {
                    DockIcon(.image, size: 24, color: .dockSecondaryText).accessibilityHidden(true)
                    if failed {
                        Text("Image preview unavailable")
                        if !glance, url.scheme == "https" {
                            Button("Open image") { InAppBrowser.open(url) }.buttonStyle(.dockLink)
                        }
                    } else if canLoad {
                        Text("Loading image…")
                    } else if !glance {
                        Button("Load image") { loadRequested = true }.buttonStyle(.dockSecondary)
                    }
                }
                .dockFont(.metadata)
                .foregroundStyle(Color.dockSecondaryText)
                .frame(maxWidth: .infinity, minHeight: 120)
                .dockWell()
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 160)
        .task(id: canLoad) {
            guard canLoad else { return }
            let result = await AttachmentThumbnailLoader.shared.galleryImage(at: url, loadRequested: loadRequested)
            guard !Task.isCancelled else { return }
            image = result
            failed = result == nil
        }
    }
}
