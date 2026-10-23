import AppKit
import SwiftUI
import Testing

@testable import Herm

/// Opt-in native fixtures, without starting recognition, audio, or Hermes.
@MainActor
struct VoiceInputRenderTests {
    @Test func warningActionsAndSpokenCaptions() async throws {
        guard let path = ProcessInfo.processInfo.environment["VOICE_SNAPSHOT_DIR"] else { return }
        let savedTheme = DockThemeRuntime.current
        defer {
            DockThemeRuntime.current = savedTheme
            DockThemeRuntime.revision &+= 1
        }
        for theme in [DockThemeID.clean, .glass, .mono] {
            DockThemeRuntime.current = theme
            DockThemeRuntime.revision &+= 1
            for dark in [false, true] {
                for width: CGFloat in [420, 760] {
                    let model = DockModel(initialSessionID: "voice-render")
                    model.composer.text = "Words appear here while I speak."
                    let speech = SpeechInput()
                    speech.errorMessage = "Speech recognition couldn’t continue. Try again."
                    let content = VStack(spacing: 24) {
                        VoiceReplyCaption(
                            text:
                                "Code: build features, fix bugs, review changes, run tests, and start apps for you to try."
                        )
                        .frame(width: min(width - 48, 360), height: 96, alignment: .top)
                        ChatComposerView(
                            model: model, composer: model.composer, speechInput: speech,
                            botMode: BotModeModel(), onStop: {})
                    }
                    .padding(16)
                    .frame(width: width, height: 340)
                    .background(Color.dockCanvas)
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .transaction { $0.disablesAnimations = true }
                    .dockThemedRoot()
                    let host = NSHostingView(rootView: content)
                    host.frame = NSRect(x: 0, y: 0, width: width, height: 340)
                    let window = NSWindow(
                        contentRect: host.frame, styleMask: [.borderless], backing: .buffered,
                        defer: false)
                    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    window.contentView = host
                    window.orderFrontRegardless()
                    host.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(100))
                    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let png = try #require(bitmap.representation(using: .png, properties: [:]))
                    try png.write(
                        to: URL(fileURLWithPath: path).appendingPathComponent(
                            "voice-\(theme.rawValue)-\(dark ? "dark" : "light")-\(Int(width)).png"))
                    window.orderOut(nil)
                    model.shutdown()
                }
            }
        }
    }
}
