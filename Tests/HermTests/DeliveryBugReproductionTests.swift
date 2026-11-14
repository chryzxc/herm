import AppKit
import SwiftUI
import Testing

@testable import Herm

@MainActor
private final class DeliveryVoiceRPC: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    var requests: [(String, [String: Any])] = []

    func connect() async throws {}
    func close() {}
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        requests.append((method, params))
        if method == "voice.toggle" { return ["available": true, "stt_available": true] }
        if method == "config.get", params["key"] as? String == "voice" {
            throw NSError(
                domain: "HermesRPC", code: 4002,
                userInfo: [NSLocalizedDescriptionKey: "unknown config key: voice"])
        }
        if method == "voice.record" { return ["status": "recording"] }
        return [:]
    }
}

@MainActor
struct DeliveryBugReproductionTests {
    @Test func supportedRecorderStartsWithoutAnOptionalVoiceConfigGetter() async throws {
        let client = DeliveryVoiceRPC()
        let model = DockModel(
            sessionAgentStateFileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("delivery-voice-\(UUID().uuidString).json"),
            initialSessionID: "delivery-voice", rpcClient: client)
        model.canTranscribeVoice = { false }
        model.startVoiceConversation()
        for _ in 0..<300 where model.voiceState == .preparing {
            try await Task.sleep(for: .milliseconds(10))
        }
        await model.voiceRequestChain?.value
        #expect(client.requests.contains { $0.0 == "voice.record" && $0.1["action"] as? String == "start" })
        #expect(model.voiceState == .listening)
        #expect(!client.requests.contains { $0.0 == "config.get" && $0.1["key"] as? String == "voice" })
        model.stopVoiceConversation()
        await model.voiceRequestChain?.value
    }

    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua, .vibrantDark])
    func lightSkinSpecimenKeepsItsPaperInDarkHosts(appearance: NSAppearance.Name) async throws {
        _ = NSApplication.shared
        let content = DockSkinSpecimen(theme: .notebook).frame(width: 224)
            .environment(\.colorScheme, appearance == .aqua ? .light : .dark)
        let host = NSHostingView(rootView: content)
        host.frame = NSRect(x: 0, y: 0, width: 224, height: 148)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        for _ in 0..<3 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
        }
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let color = try #require(
            bitmap.colorAt(x: bitmap.pixelsWide - 16, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        #expect(color.redComponent > 0.6, "Notebook paper must remain recognizable under \(appearance.rawValue)")
        #expect(color.greenComponent > 0.6)
    }

    @Test func nativeScrollerInstallationPreservesTheSystemStyle() {
        _ = NSApplication.shared
        _ = NSScrollView.installDockScrollers
        #expect(DockScroller.isCompatibleWithOverlayScrollers)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .legacy
        scroll.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 2000))
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = scroll
        defer { window.orderOut(nil) }
        #expect(
            scroll.scrollerStyle == .legacy,
            "An always-visible system scrollbar must not become an autohiding overlay")
    }
}
