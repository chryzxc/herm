import CryptoKit
import Foundation
import ImageIO
import SwiftUI

/// File reads and image decoding stay off the UI actor, including cache misses.
actor AttachmentThumbnailLoader {
    static let shared = AttachmentThumbnailLoader()
    static let maximumPixelSize = 840

    private final class Entry {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    private let cache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.countLimit = 128
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()

    func image(at url: URL, maximumPixelSize: Int = AttachmentThumbnailLoader.maximumPixelSize) -> CGImage? {
        guard url.isFileURL || url.scheme == "data" else { return nil }
        let identity = url.isFileURL ? url.absoluteString : SHA256.hash(data: Data(url.absoluteString.utf8)).description
        var key = "\(maximumPixelSize)|\(identity)"
        if url.isFileURL {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
            let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
            key += "|\(modified)|\(attributes[.size] ?? "")"
        }
        if let entry = cache.object(forKey: key as NSString) { return entry.image }
        let source: CGImageSource?
        if url.isFileURL {
            source = CGImageSourceCreateWithURL(url as CFURL, nil)
        } else {
            source = (try? Data(contentsOf: url)).flatMap { CGImageSourceCreateWithData($0 as CFData, nil) }
        }
        guard let source, let image = Self.thumbnail(from: source, maximumPixelSize: maximumPixelSize) else {
            return nil
        }
        cache.setObject(Entry(image), forKey: key as NSString, cost: image.bytesPerRow * image.height)
        return image
    }

    private static let maximumRemoteBytes = 6 * 1_048_576
    private static let remoteSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        return URLSession(configuration: configuration, delegate: ImageRedirectBlocker(), delegateQueue: nil)
    }()

    private final class ImageRedirectBlocker: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

    func galleryImage(at url: URL, loadRequested: Bool) async -> CGImage? {
        guard RichResourcePolicy.url(url.absoluteString, image: true) == url else { return nil }
        if url.scheme == "data" { return image(at: url) }
        guard loadRequested || RichResourcePolicy.previewsGalleryImageAutomatically(url) else { return nil }
        let key = "gallery|\(url.absoluteString)" as NSString
        if let entry = cache.object(forKey: key) { return entry.image }
        do {
            let (bytes, response) = try await Self.remoteSession.bytes(from: url)
            guard let response = response as? HTTPURLResponse, Self.acceptsGalleryImage(response) else {
                bytes.task.cancel()
                return nil
            }
            var data = Data()
            if response.expectedContentLength > 0 { data.reserveCapacity(Int(response.expectedContentLength)) }
            for try await byte in bytes {
                guard data.count < Self.maximumRemoteBytes else {
                    bytes.task.cancel()
                    return nil
                }
                data.append(byte)
            }
            try Task.checkCancellation()
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                let image = Self.thumbnail(from: source, maximumPixelSize: Self.maximumPixelSize)
            else { return nil }
            cache.setObject(Entry(image), forKey: key, cost: image.bytesPerRow * image.height)
            return image
        } catch {
            return nil
        }
    }

    static func acceptsGalleryImage(_ response: HTTPURLResponse) -> Bool {
        (200..<300).contains(response.statusCode)
            && response.expectedContentLength <= Int64(maximumRemoteBytes)
            && ["image/png", "image/jpeg", "image/webp", "image/gif", "image/avif"].contains(response.mimeType)
    }

    static func thumbnail(from source: CGImageSource, maximumPixelSize: Int) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(
            source, 0,
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            ] as CFDictionary)
    }
}

struct AttachmentThumbnailView: View {
    let url: URL
    var maximumPixelSize = AttachmentThumbnailLoader.maximumPixelSize
    var contentMode: ContentMode = .fit
    var placeholderIcon: Ph? = nil
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 2).resizable().aspectRatio(contentMode: contentMode)
            } else if let placeholderIcon {
                DockIcon(placeholderIcon, size: 16, color: Color.dockSecondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityHidden(true)
            } else {
                Color.clear
            }
        }
        .task(id: url) {
            image = nil
            let loaded = await AttachmentThumbnailLoader.shared.image(at: url, maximumPixelSize: maximumPixelSize)
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }
}
