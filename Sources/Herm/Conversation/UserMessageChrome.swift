import AppKit
import SwiftUI

/// User-message chrome shared by the main transcript and group chats, so a prompt,
/// its files and its images look the same wherever they were sent.

/// Images above a user bubble: one keeps its aspect ratio, several become a grid of square tiles.
struct UserMessageImages: View {
    let images: [NSImage]
    /// Thumbnail cache key for the image at an index.
    let cacheKey: (Int) -> String
    let onPreview: (NSImage) -> Void

    var body: some View {
        if images.count == 1 {
            // Size the frame to the fitted image so wide shots don't
            // sit centered in a 220pt square with a gap below.
            let size = images[0].size
            let scale = min(220 / max(size.width, 1), 220 / max(size.height, 1), 1)
            thumbnail(at: 0) { $0.scaledToFit().frame(width: size.width * scale, height: size.height * scale) }
        } else if images.count > 1 {
            let tile: CGFloat = 104
            LazyVGrid(
                columns: Array(repeating: GridItem(.fixed(tile), spacing: 6), count: min(images.count, 3)),
                alignment: .trailing,
                spacing: 6
            ) {
                ForEach(images.indices, id: \.self) { index in
                    thumbnail(at: index) { $0.scaledToFill().frame(width: tile, height: tile) }
                }
            }
            .fixedSize()
        }
    }

    private func thumbnail(at index: Int, @ViewBuilder layout: (Image) -> some View) -> some View {
        let image = images[index]
        return Button {
            onPreview(image)
        } label: {
            layout(Image(nsImage: ConversationThumbnailCache.image(image, key: cacheKey(index))).resizable())
                .clipShape(RoundedRectangle(cornerRadius: DockLayout.paneRadius, style: .continuous))
        }
        .buttonStyle(.dockHover)
        .contentShape(RoundedRectangle(cornerRadius: DockLayout.paneRadius, style: .continuous))
        .help("Open image preview")
    }
}

/// One attached file inside a user bubble.
struct UserMessageAttachmentRow: View {
    let name: String

    var body: some View {
        HStack(spacing: 8) {
            FileTypeIcon(fileName: name)
            Text(name).dockFont(.body, weight: .medium).lineLimit(2)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Attachment: " + name)
    }
}

extension View {
    /// The user prompt bubble: insets, skin fill and rim. Steering prompts get an accent rim.
    func userMessageBubble(isSteering: Bool = false, isSpotlit: Bool = false, reduceMotion: Bool = false)
        -> some View
    {
        let shape = UserMessageBubbleShape.current
        let isDocument = DockSkinPresentation.current.transcript == .document
        return
            self
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(Color.dockPrimaryText)
            .dockPadding(.horizontal, 14)
            .dockPadding(.vertical, 10)
            .background(shape.fill(isDocument ? Color.dockSurface : Color.dockUserMessageBubble))
            .messageSpotlight(isSpotlit, shape: shape, reduceMotion: reduceMotion)
            .overlay {
                shape
                    .stroke(
                        isSteering
                            ? Color.dockAccent.opacity(0.45) : isDocument ? .clear : Color.dockBorderStrong,
                        lineWidth: 0.5
                    )
                    .allowsHitTesting(false)
            }
    }
}

enum UserMessageBubbleShape {
    /// The tail corner points toward the sender edge so consecutive prompts
    /// read as one side of the exchange without an avatar.
    static var current: AnyShape {
        if DockSkinPresentation.current.transcript == .document {
            return AnyShape(DockThemeShape(cornerRadius: DockLayout.paneRadius, role: .pane))
        }
        return AnyShape(
            UnevenRoundedRectangle(
                topLeadingRadius: 14,
                bottomLeadingRadius: 14,
                bottomTrailingRadius: 4,
                topTrailingRadius: 14,
                style: .continuous
            ))
    }
}
