import Foundation
import SwiftUI

/// What the office jukebox shows. Parsed from the AppleScript reply: an
/// `error` line plus message, `stopped`, or player state, track, artist lines.
struct OfficeMusicState: Equatable {
    var isPlaying = false
    var track: String?
    var artist: String?
    var message: String?

    static func parse(_ output: String) -> Self {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        switch lines.first {
        case "error": return Self(message: lines.dropFirst().joined(separator: " "))
        case "playing", "paused":
            guard lines.count >= 3 else { return Self(message: "Nothing is playing on Spotify.") }
            return Self(isPlaying: lines[0] == "playing", track: lines[1], artist: lines[2].isEmpty ? nil : lines[2])
        case "stopped": return Self(message: "Nothing is playing on Spotify.")
        default: return Self(message: "Spotify is unavailable.")
        }
    }
}

/// Drives the Spotify desktop app over AppleScript, the same way the Hermes
/// agent plays songs here. No Web API login needed; the first call makes
/// macOS ask once for permission to control Spotify.
@MainActor
final class OfficeMusicService: ObservableObject {
    @Published private(set) var state = OfficeMusicState()
    @Published private(set) var isBusy = false

    /// Polls while the office is on screen; SwiftUI's `.task` cancels it.
    func poll() async {
        while !Task.isCancelled {
            if !isBusy { await run([]) }
            // Back off while Spotify is idle or closed; hover refreshes.
            try? await Task.sleep(for: .seconds(state.track == nil ? 30 : 5))
        }
    }

    func refresh() { Task { await run([]) } }

    func togglePlayback() { Task { await run([state.isPlaying ? "pause" : "play"]) } }
    func next() { Task { await run(["next"]) } }

    private func run(_ actions: [String]) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        // Optimistic, so the speakers react on click instead of after the round trip.
        if actions == ["play"] || actions == ["pause"] { state.isPlaying = actions == ["play"] }
        let output = await Task.detached { Self.invoke(actions) }.value
        let next = OfficeMusicState.parse(output)
        if next != state { state = next }
    }

    /// Checks `is running` first so polling never launches Spotify.
    nonisolated private static let script = """
    on run argv
        if application "Spotify" is not running then return "error" & linefeed & "Open Spotify to play music here."
        tell application "Spotify"
            repeat with action in argv
                set action to action as text
                if action is "play" then play
                if action is "pause" then pause
                if action is "next" then next track
            end repeat
            -- Spotify reports the new track a beat after a skip.
            if (count of argv) > 0 then delay 0.4
            set s to player state as text
            if s is "stopped" then return "stopped"
            return s & linefeed & (name of current track) & linefeed & (artist of current track)
        end tell
    end run
    """

    nonisolated private static func invoke(_ actions: [String]) -> String {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script] + actions
        process.standardOutput = output
        process.standardError = errors
        do {
            try process.run()
            let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 150, execute: timeout)
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let failure = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            timeout.cancel()
            if process.terminationStatus != 0 {
                // -1743: Automation access denied; -1712: the first-run permission prompt went unanswered.
                let reply = String(decoding: failure, as: UTF8.self)
                return reply.contains("-1743") || reply.contains("-1712")
                    ? "error\nAllow Herm to control Spotify in System Settings › Privacy & Security › Automation."
                    : "error\nCould not reach Spotify."
            }
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return "error\nCould not reach Spotify."
        }
    }
}

/// The small card that appears while hovering the lounge record player.
struct OfficeMusicControl: View {
    @ObservedObject var music: OfficeMusicService

    var body: some View {
        HStack(spacing: 10) {
            DockIcon(music.state.isPlaying ? .waveform : .musicNote)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.dockAccent)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.dockAccent.opacity(0.15)))
            VStack(alignment: .leading, spacing: 1) {
                Text(music.state.track ?? "Spotify")
                    .font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(music.state.track == nil ? (music.state.message ?? "Loading…") : (music.state.artist ?? ""))
                    .font(.system(size: 11)).foregroundStyle(Color.dockSecondaryText).lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 200, alignment: .leading)
            .frame(minHeight: 42)
            .help(music.state.message ?? "")
            Button(action: music.togglePlayback) {
                DockIcon(music.state.isPlaying ? .pause : .play, weight: .fill).frame(width: 24, height: 24)
            }
            .help(music.state.isPlaying ? "Pause" : "Play")
            Button(action: music.next) {
                DockIcon(.fastForward, weight: .fill).frame(width: 24, height: 24)
            }
            .help("Next song")
        }
        .buttonStyle(.borderless)
        .disabled(music.isBusy)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DockLayout.paneRadius + 2))
        .overlay(RoundedRectangle(cornerRadius: DockLayout.paneRadius + 2).stroke(Color.dockBorder, lineWidth: 0.5))
        .fixedSize()
    }
}
