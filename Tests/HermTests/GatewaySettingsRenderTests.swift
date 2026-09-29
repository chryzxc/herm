import AppKit
import SwiftUI
import Testing
@testable import Herm

@MainActor
struct GatewaySettingsRenderTests {
    @Test func renderSettings() async throws {
        guard let directory = ProcessInfo.processInfo.environment["GATEWAY_SNAPSHOT_DIR"] else { return }
        let states = [
            "Launchd plist: /Users/test/Library/LaunchAgents/ai.hermes.gateway.plist\n✓ Gateway is supervised by launchd (PID 9623)",
            "Launchd plist: /Users/test/Library/LaunchAgents/ai.hermes.gateway.plist\n✗ Gateway service is not loaded",
            "Unrecognized response",
        ]
        var models: [HermesGatewayLifecycleModel] = []
        for state in states {
            let model = HermesGatewayLifecycleModel(pause: {}) { _ in .init(succeeded: true, output: state) }
            await model.refresh()
            models.append(model)
        }
        let content = VStack(spacing: 20) {
            ForEach(models.indices, id: \.self) { index in
                SettingsSection(title: "Hermes gateway", subtitle: "Messaging service", tint: .dockAccent) {
                    HermesGatewaySettingsView(service: models[index])
                }
            }
        }
        .padding(20)
        .background(Color.dockCanvas)
        .dockThemedRoot()
        let renderer = ImageRenderer(content: content.frame(width: 440))
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("gateway-settings.png"))
    }
}
