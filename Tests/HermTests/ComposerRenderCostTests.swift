import Foundation
import Testing

@testable import Herm

struct ComposerRenderCostTests {
    @Test func pulseUsesBreathAndStaticEmphasis() {
        for (time, expected) in [(0.0, 0.28), (0.4, 0.465), (0.8, 0.65), (1.6, 0.28)] {
            let date = Date(timeIntervalSinceReferenceDate: time)
            #expect(abs(ComposerRecordingPulse.opacity(at: date, animates: true) - expected) < 0.000001)
            #expect(ComposerRecordingPulse.opacity(at: date, animates: false) == 0.65)
        }
    }

    @Test func clocksBelongToEffectsAndRecordingStroke() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        func source(_ path: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        }
        let composer = try source("Sources/Herm/Conversation/ChatComposerView.swift")
        let surface = try source("Sources/Herm/Conversation/ComposerComponents.swift")
        let slider = try source("Sources/Herm/Conversation/ComposerEffortSlider.swift")
        #expect(!composer.contains("isComposerPulsing"))
        #expect(!composer.contains("repeatForever"))
        #expect(surface.contains("TimelineView(.dockMotion())"))
        #expect(slider.contains("TimelineView(.dockMotion())"))
        #expect(!slider.contains("TimelineView(.animation)"))
    }
}
