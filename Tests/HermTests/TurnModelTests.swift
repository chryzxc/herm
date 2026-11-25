import AVFoundation
import Foundation
import Testing

@testable import Herm

@MainActor
struct TurnModelTests {
    @Test(arguments: [true, false])
    func automaticInstallRespectsCancelAndRemove(cancel: Bool) throws {
        let name = "TurnModelTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let store = TurnModelStore(defaults: defaults, directory: directory)
        #expect(store.shouldInstallAutomatically)
        if cancel {
            store.cancel()
        } else {
            store.remove()
        }
        #expect(!TurnModelStore(defaults: defaults, directory: directory).shouldInstallAutomatically)
    }

    @Test func turnAudioOnlyKeepsSamplesWhenEnabled() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_024))
        buffer.frameLength = 1_024
        buffer.floatChannelData?[0].update(repeating: 0.25, count: Int(buffer.frameLength))

        let turnAudio = TurnAudio()
        turnAudio.append(buffer)
        #expect(turnAudio.snapshot().isEmpty)
        turnAudio.isEnabled = true
        turnAudio.append(buffer)
        #expect(!turnAudio.snapshot().isEmpty)
        turnAudio.isEnabled = false
        turnAudio.append(buffer)
        #expect(turnAudio.snapshot().isEmpty)
    }

    @Test func downloadProgressWeightsCompletedFilesAndCurrentTransfer() {
        let completed = 70_854
        let weights = 16_714_240
        let total = Double(TurnModelStore.downloadSize)
        #expect(TurnModelStore.downloadProgress(completedBytes: 0, fileBytes: 243, fraction: 0) == 0)
        let start = TurnModelStore.downloadProgress(completedBytes: completed, fileBytes: weights, fraction: 0)
        let halfway = TurnModelStore.downloadProgress(completedBytes: completed, fileBytes: weights, fraction: 0.5)
        let end = TurnModelStore.downloadProgress(completedBytes: completed, fileBytes: weights, fraction: 1)
        #expect(start == Double(completed) / total)
        #expect(halfway == (Double(completed) + Double(weights) * 0.5) / total)
        #expect(start < halfway && halfway < end)
        #expect(end == 1)
    }

    @Test func downloadProgressBoundsCurrentTransfer() {
        #expect(TurnModelStore.downloadProgress(completedBytes: 0, fileBytes: 243, fraction: -1) == 0)
        #expect(
            TurnModelStore.downloadProgress(
                completedBytes: 70_854, fileBytes: 16_714_240, fraction: 2) == 1)
    }
}
