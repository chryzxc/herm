import AVKit
import Testing

@testable import Herm

struct ChatVideoPreviewTests {
    @Test func recognizesVideoAttachments() throws {
        for path in ["/tmp/waving cat.mp4", "/tmp/CLIP.MOV", "/tmp/clip.m4v", "/tmp/clip.webm"] {
            #expect(ChatVideoPreview.supports(URL(fileURLWithPath: path)))
        }
        #expect(ChatVideoPreview.supports(try #require(URL(string: "https://example.com/clip.MP4?token=test"))))
        for value in ["https://example.com/image.png", "https://example.com/mp4", "ftp://example.com/clip.mp4"] {
            #expect(!ChatVideoPreview.supports(try #require(URL(string: value))))
        }
    }

    @Test func deliveredVideoUsesTheSharedMediaRenderer() {
        #expect(
            ChatMediaSegment.split("Here is your video.", delivered: ["/tmp/waving-cat.mp4"]) == [
                .markdown("Here is your video."), .media("/tmp/waving-cat.mp4"),
            ])
    }

    @Test @MainActor func leavingVideoReleasesPlayback() {
        let view = AVPlayerView()
        let player = AVPlayer(playerItem: AVPlayerItem(url: URL(fileURLWithPath: "/tmp/missing-video.mp4")))
        view.player = player
        let coordinator = ChatNativeVideoPlayer.Coordinator()
        ChatNativeVideoPlayer.dismantleNSView(view, coordinator: coordinator)
        #expect(view.player == nil)
        #expect(player.currentItem == nil)
        #expect(player.rate == 0)
        #expect(coordinator.observation == nil)
    }
}
