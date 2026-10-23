import SwiftUI
import Testing

@testable import Herm

struct HermFaceTests {
    @Test func genesAreSeededPerProfile() {
        #expect(HermFaceGenes(id: "nexus") == HermFaceGenes(id: " Nexus "))
        let roster = Set(
            (0..<40).map { "\(HermFaceGenes(id: "bot-\($0)").body)\(HermFaceGenes(id: "bot-\($0)").eyes)" })
        #expect(roster.count > 8)
        for i in 0..<40 {
            let genes = HermFaceGenes(id: "bot-\(i)")
            #expect(abs(genes.tilt) <= 7)
            #expect(HermFaceGenes.palettes.indices.contains(genes.palette))
        }
    }

    @Test func activityStatesMapToFaces() {
        #expect(BotMood(activity: .queued) == .queued)
        #expect(BotMood(activity: .working) == .tool)
        #expect(BotMood(activity: .waiting) == .clarify)
        #expect(BotMood(activity: .completed) == .done)
        #expect(BotMood(activity: .failed) == .failed)
        #expect(BotMood(activity: .canceled) == .stopped)
        // Settled states never keep a clock running.
        for mood in [BotMood.idle, .done, .failed, .stopped, .queued, .offline, .sleepy] { #expect(!mood.moves) }
    }

    @Test func sessionAsksPickFaces() {
        #expect(BotMood(ask: .approval, compacting: true) == .approval)
        #expect(BotMood(ask: .clarification) == .clarify)
        #expect(BotMood(ask: .running, compacting: true) == .compressing)
        #expect(BotMood(ask: .running) == nil)
        #expect(BotMood(ask: nil) == nil)
        #expect(BotMood(status: .needsClarification, compacting: false) == .clarify)
        #expect(BotMood(status: .working, compacting: false) == nil)
    }

    @Test func skinsPickToneAndOutline() {
        #expect(HermFaceTone(theme: nil) == .hue)
        #expect(HermFaceTone(theme: .eInk) == .gray)
        #expect(HermFaceTone(theme: .terminal) == .accent)
        #expect(HermFaceTone.outline(.cartoon) != nil)
        #expect(HermFaceTone.outline(.glass) == nil)
        #expect(HermFaceTone.glossy(.glass) && !HermFaceTone.glossy(.cartoon) && !HermFaceTone.glossy(nil))
    }

    @Test func pathReaderHandlesFaceCommands() {
        let tile = HermFacePath.parse("M30 9 H70 C84 9 91 16 91 30 V70 Z").boundingRect
        #expect(abs(tile.minX - 30) < 0.01 && abs(tile.maxX - 91) < 0.01)
        #expect(abs(tile.minY - 9) < 0.01 && abs(tile.maxY - 70) < 0.01)
        let mouth = HermFacePath.parse("M-7 3 Q0 -7 7 3").boundingRect
        #expect(abs(mouth.minX + 7) < 0.01 && mouth.minY < 3)
        for body in HermFaceGenes.Body.allCases {
            let box = HermFacePath.bodies[body]!.boundingRect
            #expect(box.minX >= 5 && box.maxX <= 95 && box.minY >= 4 && box.maxY <= 95)
        }
    }
}
