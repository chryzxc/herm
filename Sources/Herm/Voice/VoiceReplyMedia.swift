import SwiftUI

/// The same explicit deliveries chat shows, without its file actions or ordinary links.
@MainActor
enum VoiceReplyMedia {
    struct Item: Hashable, Identifiable {
        enum Kind { case image, video, file }

        let url: URL
        let kind: Kind
        var id: URL { url }
        var label: String {
            switch kind {
            case .image: "Image"
            case .video: "Video"
            case .file: url.lastPathComponent
            }
        }
    }

    private struct Cached {
        let revision: Int
        let activity: [ActiveToolCall]
        let items: [Item]
    }
    private static var cache: [UUID: Cached] = [:]

    static func items(in message: ChatMessage) -> [Item] {
        guard message.role == .hermes, !message.isError, message.text.utf8.count <= RichDocument.maximumBytes else {
            return []
        }
        if let cached = cache[message.id], cached.revision == message.contentRevision,
            cached.activity == message.activity
        {
            return cached.items
        }
        let delivered = ArtifactService.deliveredFiles(in: message.activity)
        let segments = ChatMediaSegment.split(message.text, delivered: delivered)
        var seen: Set<URL> = []
        var items: [Item] = []
        for segment in segments {
            guard case .media(let path) = segment, let item = item(for: path), seen.insert(item.url).inserted else {
                continue
            }
            items.append(item)
            if items.count == 4 { break }
        }
        if cache.count >= 4 { cache.removeAll() }
        cache[message.id] = Cached(revision: message.contentRevision, activity: message.activity, items: items)
        return items
    }

    private static func item(for path: String) -> Item? {
        let isImage = ArtifactService.kind(for: path) == .image
        let url: URL?
        if path.hasPrefix("/") || path.hasPrefix("~/") || path.hasPrefix("file:///") {
            url = ArtifactOpener.url(path)?.standardizedFileURL
        } else {
            url = RichResourcePolicy.url(path, image: isImage)
        }
        guard let url else { return nil }
        if isImage { return Item(url: url, kind: .image) }
        if ChatVideoPreview.supports(url) { return Item(url: url, kind: .video) }
        if url.isFileURL, !url.hasDirectoryPath { return Item(url: url, kind: .file) }
        return nil
    }
}

/// Media is visual content, not a file action. A remote movie only connects when played.
struct VoiceReplyMediaView: View {
    let item: VoiceReplyMedia.Item
    @State private var playsRemoteVideo = false
    @State private var localImage: CGImage?
    @State private var imageUnavailable = false

    var body: some View {
        Group {
            switch item.kind {
            case .image:
                Color.dockCanvas
                    .aspectRatio(4 / 3, contentMode: .fit)
                    .overlay { image.accessibilityLabel(item.label) }
            case .video: video
            case .file:
                HStack(spacing: DockSpacing.tight) {
                    FileTypeIcon(fileName: item.label)
                    Text(item.label)
                        .dockFont(.body, weight: .medium)
                        .foregroundStyle(Color.dockPrimaryText)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .dockPadding(10)
                .dockWell()
            }
        }
        .frame(maxWidth: 420)
        .clipShape(RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous))
    }

    @ViewBuilder private var image: some View {
        if item.url.isFileURL || item.url.scheme == "data" {
            Group {
                if let localImage {
                    Image(decorative: localImage, scale: 2).resizable().scaledToFit()
                } else {
                    imagePlaceholder(failed: imageUnavailable)
                }
            }
            .task(id: item.url) {
                let result = await AttachmentThumbnailLoader.shared.image(at: item.url)
                guard !Task.isCancelled else { return }
                localImage = result
                imageUnavailable = result == nil
            }
        } else {
            RichGalleryImage(url: item.url, title: item.label)
                .id(item.url)
        }
    }

    private func imagePlaceholder(failed: Bool) -> some View {
        Text(failed ? "Image preview unavailable" : "Loading image…")
            .dockFont(.metadata)
            .foregroundStyle(Color.dockSecondaryText)
            .frame(maxWidth: .infinity, minHeight: 72)
            .dockWell()
    }

    @ViewBuilder private var video: some View {
        if item.url.isFileURL || playsRemoteVideo {
            ChatVideoPreview(url: item.url, unavailableMessage: "Video preview unavailable.")
        } else {
            Button {
                playsRemoteVideo = true
            } label: {
                HStack(spacing: DockSpacing.tight) {
                    DockIcon(.play, size: 12).accessibilityHidden(true)
                    Text("Load video")
                }
            }
            .buttonStyle(.dockSecondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .dockWell()
            .aspectRatio(16 / 9, contentMode: .fit)
        }
    }
}
