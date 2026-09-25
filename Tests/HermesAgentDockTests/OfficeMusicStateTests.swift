import Foundation
import Testing
@testable import HermesAgentDock

struct OfficeMusicStateTests {
    @Test func parsesSpotifyAppleScriptReplies() {
        #expect(OfficeMusicState.parse("playing\nSong\nA, B") == OfficeMusicState(isPlaying: true, track: "Song", artist: "A, B"))
        #expect(OfficeMusicState.parse("paused\nSong\n") == OfficeMusicState(isPlaying: false, track: "Song"))
        #expect(OfficeMusicState.parse("stopped") == OfficeMusicState(message: "Nothing is playing on Spotify."))
        #expect(OfficeMusicState.parse("error\nOpen Spotify.") == OfficeMusicState(message: "Open Spotify."))
        #expect(OfficeMusicState.parse("").message != nil)
    }
}
