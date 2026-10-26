import SwiftUI

/// Local thumbnails share the bounded decoder used by conversation attachments.
struct ArtifactImagePreview<Placeholder: View>: View {
    let url: URL
    let maximumPixelSize: Int
    @ViewBuilder let placeholder: () -> Placeholder
    @State private var image: CGImage?

    private struct Request: Equatable {
        let url: URL
        let pixels: Int
    }

    var body: some View {
        Group {
            if url.isFileURL || url.scheme == "data" {
                Group {
                    if let image {
                        Image(decorative: image, scale: 2).resizable().scaledToFill()
                    } else {
                        placeholder()
                    }
                }
                .task(id: Request(url: url, pixels: maximumPixelSize)) {
                    image = nil
                    let decoded = await AttachmentThumbnailLoader.shared.image(
                        at: url, maximumPixelSize: maximumPixelSize)
                    guard !Task.isCancelled else { return }
                    image = decoded
                }
            } else {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        placeholder()
                    }
                }
            }
        }
    }
}
