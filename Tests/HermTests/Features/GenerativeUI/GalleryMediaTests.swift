import Foundation
import Testing

@testable import Herm

struct GalleryMediaTests {
    @Test func commonsImagesCanPreviewButOtherLinksAreNotFetchedAutomatically() throws {
        let photo = try #require(
            RichResourcePolicy.url(
                "https://upload.wikimedia.org/wikipedia/commons/example.jpg", image: true))
        #expect(RichResourcePolicy.previewsGalleryImageAutomatically(photo))
        for link in [
            "https://images.example.com/dog.jpg",
            "https://upload.wikimedia.org.example.com/wikipedia/commons/dog.jpg",
            "https://upload.wikimedia.org/wikipedia/commons/dog.jpg?token=sample",
            "https://upload.wikimedia.org:8443/wikipedia/commons/dog.jpg",
        ] {
            let url = try #require(RichResourcePolicy.url(link, image: true))
            #expect(!RichResourcePolicy.previewsGalleryImageAutomatically(url))
        }
    }

    @Test func galleryDownloadsMustBeSuccessfulBoundedImages() throws {
        let url = try #require(URL(string: "https://upload.wikimedia.org/wikipedia/commons/example.jpg"))
        for (status, length, type, expected) in [
            (200, 4_096, "image/jpeg", true),
            (302, 1024, "image/jpeg", false),
            (200, 7_000_000, "image/jpeg", false),
            (200, 1024, "text/html", false),
        ] {
            let response = try #require(
                HTTPURLResponse(
                    url: url, statusCode: status, httpVersion: nil,
                    headerFields: ["Content-Type": type, "Content-Length": String(length)]))
            #expect(AttachmentThumbnailLoader.acceptsGalleryImage(response) == expected)
        }
    }

    @Test func galleryStillDecodesInlineImageBytes() async throws {
        let url = try #require(
            RichResourcePolicy.url(
                "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGMICAgAAAHkAPEGGOe8AAAAAElFTkSuQmCC",
                image: true))
        #expect(await AttachmentThumbnailLoader.shared.galleryImage(at: url, loadRequested: false) != nil)
    }
}
