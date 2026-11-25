import Foundation
import Testing

@testable import Herm

@MainActor
struct VoiceReplyMediaTests {
    @Test func showsExplicitImagesAndVideosInOrderAndOnlyOnce() {
        let activity = ActiveToolCall(
            id: "image", name: "image_generate", input: "", context: "", startedAt: .now,
            result: #"{"success": true, "image": "/tmp/photo.jpg"}"#,
            isComplete: true)
        let reply = ChatMessage(
            role: .hermes,
            text: """
                Here's what I found.
                ![City](/tmp/photo.jpg)
                MEDIA:file:///tmp/photo.jpg
                MEDIA:/tmp/clip.mp4
                """,
            activity: [activity])
        let items = VoiceReplyMedia.items(in: reply)
        #expect(items.map(\.kind) == [.image, .video])
        #expect(items.map(\.url.lastPathComponent) == ["photo.jpg", "clip.mp4"])
    }

    @Test func noticesMediaWhenStoredToolResultsArriveForTheSameReply() {
        let reply = ChatMessage(role: .hermes, text: "Here is the image.")
        #expect(VoiceReplyMedia.items(in: reply).isEmpty)

        let activity = ActiveToolCall(
            id: "image", name: "image_generate", input: "", context: "", startedAt: .now,
            result: #"{"success": true, "image": "https://example.com/render.png"}"#,
            isComplete: true)
        let delivered = ChatMessage(id: reply.id, role: .hermes, text: reply.text, activity: [activity])
        #expect(VoiceReplyMedia.items(in: delivered).map(\.url.lastPathComponent) == ["render.png"])
    }

    @Test func skipsExamplesLinksAndUntrustedURLs() {
        let reply = ChatMessage(
            role: .hermes,
            text: """
                ~~~text
                MEDIA:/tmp/example.mp4
                ~~~
                [Download the video](https://example.com/clip.mp4)
                ![Relative](relative.png)
                ![Local network](https://127.0.0.1/private.jpg)
                ![Internal network](https://printer.local/photo.png)
                MEDIA:javascript:bad.mp4
                MEDIA:/tmp/report.pdf
                ![Public](https://example.com/photo.jpg)
                MEDIA:https://example.com/clip.mp4
                """)
        let items = VoiceReplyMedia.items(in: reply)
        #expect(items.map(\.kind) == [.file, .image, .video])
        #expect(items.map(\.url.lastPathComponent) == ["report.pdf", "photo.jpg", "clip.mp4"])
    }

    @Test func videoAndFileDirectivesSurviveAlongsideAGeneratedSurface() {
        let reply = ChatMessage(
            role: .hermes,
            text: """
                ~~~herm-ui
                {"version":1,"id":"summary","title":"Summary","fallback":"One result","kind":"native","blocks":[{"type":"text","text":"Result"}]}
                ~~~
                ::preview{file="/tmp/clip.mov"}
                MEDIA:/tmp/report.pdf
                """)
        let items = VoiceReplyMedia.items(in: reply)
        #expect(items.map(\.kind) == [.video, .file])
        #expect(items.map(\.label) == ["Video", "report.pdf"])
    }
}
