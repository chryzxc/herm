import AppKit
import Foundation
import SwiftUI
import Testing
import Vision

@testable import Herm

@MainActor
struct VoiceOutputTests {
    @Test func quickMenuOffersKokoroBeforeDownloadOnSupportedMacs() {
        #expect(
            VoiceOutputSettings.engineChoices(supportsKokoro: false, selected: .hermes) == [.hermes, .apple, .natural])
        #expect(
            VoiceOutputSettings.engineChoices(supportsKokoro: true, selected: .apple)
                == [.hermes, .apple, .natural, .kokoro])
        #expect(VoiceOutputSettings.engineChoices(supportsKokoro: false, selected: .kokoro).contains(.kokoro))
    }

    @Test func naturalVoiceUsesTheAutomaticChoiceInsteadOfTheManualAppleVoice() {
        let automatic = VoiceSpeechEngine.natural.localAppleVoice(identifier: "")
        if let manual = VoiceSpeechEngine.appleVoices.first(where: { $0.identifier != automatic?.identifier }) {
            #expect(
                VoiceSpeechEngine.apple.localAppleVoice(identifier: manual.identifier)?.identifier == manual.identifier)
            #expect(
                VoiceSpeechEngine.natural.localAppleVoice(identifier: manual.identifier)?.identifier
                    == automatic?.identifier)
        }
    }

    @Test(arguments: [(false, VoiceSpeechEngine.apple), (true, .apple), (true, .kokoro), (true, .natural)])
    func quickMenuRendersTheSavedVoiceAndSpeed(dark: Bool, engine: VoiceSpeechEngine) async throws {
        _ = NSApplication.shared
        let previousTheme = DockThemeRuntime.current
        let previousAppearance = NSApplication.shared.appearance
        DockThemeRuntime.current = .glass
        DockThemeRuntime.revision &+= 1
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        NSApplication.shared.appearance = appearance
        defer {
            NSApplication.shared.appearance = previousAppearance
            DockThemeRuntime.current = previousTheme
            DockThemeRuntime.revision &+= 1
        }
        let name = "herm.quick-voice-test." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(engine.rawValue, forKey: VoiceSpeechEngine.outputKey)
        defaults.set(1.15, forKey: VoiceSpeechEngine.speedKey)
        defaults.set("classic", forKey: VoiceRecognitionPreference.engineKey)
        let turnModel = TurnModelStore(
            defaults: defaults, directory: FileManager.default.temporaryDirectory.appendingPathComponent(name))

        let host = NSHostingView(
            rootView: VoiceQuickSettings(recognitionStatus: VoiceRecognitionStatus(), turnModel: turnModel)
                .defaultAppStorage(defaults)
                .background(Color.dockOpaqueCanvas)
                .dockThemedRoot())
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(200))
        window.setContentSize(host.fittingSize)
        host.layoutSubtreeIfNeeded()
        #expect(host.bounds.width == 360)
        #expect(host.fittingSize.height <= 440)

        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        if let dir = ProcessInfo.processInfo.environment["HERM_FOUNDATION_UI_DIR"] {
            let output = URL(fileURLWithPath: dir)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let rendered = engine == .apple ? (dark ? "dark" : "light") : engine.rawValue
            try #require(bitmap.representation(using: .png, properties: [:])).write(
                to: output.appendingPathComponent("quick-voice-\(rendered).png"))
        }
        let image = try #require(bitmap.cgImage)
        let request = VNRecognizeTextRequest()
        try VNImageRequestHandler(cgImage: image).perform([request])
        let text = request.results?.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ") ?? ""
        var labels = [
            "Conversation voice", engine.title, "Preview", "Speaking speed", "Recognizer",
            "Speech language", "Smart turn detection", "Download", "Wake word",
        ]
        if engine == .apple {
            labels += ["Apple voice", "Acknowledge right away", "Announce aloud", "Activity cards"]
            #expect(!text.contains("Kokoro setup"))
            #expect(text.lowercased().components(separatedBy: "activity cards").count == 2)
        } else if engine == .natural {
            labels.append("Natural voice")
            #expect(text.localizedCaseInsensitiveContains("Try Kokoro") == KokoroVoice.available)
        } else if KokoroVoice.installed {
            labels.append("Kokoro voice")
        } else {
            labels += ["Kokoro setup", "Apple voice"]
            if KokoroVoice.available {
                labels.append(KokoroVoice.installer == nil ? "Get uv" : "Install Kokoro")
            }
        }
        for label in labels {
            #expect(text.localizedCaseInsensitiveContains(label), "Missing \(label) from the quick voice menu: \(text)")
        }
        let speed = 1.15.formatted(.percent).filter { !$0.isWhitespace }
        let speedObservation = try #require(
            request.results?.first {
                $0.topCandidates(1).first?.string.filter { !$0.isWhitespace }.contains(speed) == true
            })
        #expect((1 - speedObservation.boundingBox.maxX) * host.bounds.width >= 17)
    }

    @Test func newOutputPreferenceOverridesTheLegacyMacVoiceToggle() {
        let name = "herm.voice-output-test." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(VoiceSpeechEngine.selected(in: defaults) == .hermes)
        defaults.set(true, forKey: VoiceSpeechEngine.macVoiceKey)
        #expect(VoiceSpeechEngine.selected(in: defaults) == .apple)
        defaults.set(VoiceSpeechEngine.kokoro.rawValue, forKey: VoiceSpeechEngine.outputKey)
        #expect(VoiceSpeechEngine.selected(in: defaults) == .kokoro)
        defaults.set(VoiceSpeechEngine.natural.rawValue, forKey: VoiceSpeechEngine.outputKey)
        #expect(VoiceSpeechEngine.selected(in: defaults) == .natural)
        defaults.set("unknown", forKey: VoiceSpeechEngine.outputKey)
        #expect(VoiceSpeechEngine.selected(in: defaults) == .apple)
    }

    @Test func savedSpeedIsFiniteAndBoundedForBothLocalEngines() {
        #expect(VoiceSpeechEngine.boundedSpeed(.nan) == 1)
        #expect(VoiceSpeechEngine.boundedSpeed(.infinity) == 1)
        #expect(VoiceSpeechEngine.boundedSpeed(0) == VoiceSpeechEngine.speedRange.lowerBound)
        #expect(VoiceSpeechEngine.boundedSpeed(2) == VoiceSpeechEngine.speedRange.upperBound)
        #expect(VoiceSpeechEngine.boundedSpeed(0.95) == 0.95)
    }

    @Test func presetsKeepTheirStableIDsAndAccents() {
        #expect(Set(KokoroVoice.presets.map(\.id)).count == KokoroVoice.presets.count)
        #expect(KokoroVoice.resolvedPreset("bf_emma").language == "en-gb")
        #expect(KokoroVoice.resolvedPreset("unrecognized").id == "af_heart")
        #expect(LocalVoicePlayback.supportsKokoro("Two minutes left."))
    }

    @Test func literalReadbackKeepsTheLinkDestination() {
        let text = "Message: See [the draft](https://example.test/private-path)."
        #expect(!HermesVoicePlayback.cues(text).joined(separator: " ").contains("private-path"))
        #expect(HermesVoicePlayback.cues(text, literal: true).joined(separator: " ") == text)
    }

    @Test func stoppingPlaybackNeverReportsSuccessfulCompletion() async {
        let stopped = PlaybackFinish()
        stopped.end()
        stopped.end(completed: true)
        #expect(await stopped.wait() == false)
        let played = PlaybackFinish()
        played.end(completed: true)
        played.end()
        #expect(await played.wait() == true)
    }

    @Test func cancellingActiveSynthesisKeepsQueuedAudioOnTheWarmWorker() async throws {
        let worker = KokoroVoiceWorker()
        let command = #"""
            while IFS= read -r request; do
                if [ "$request" = "slow" ]; then
                    /bin/sleep 0.20
                    printf '\010\000\000\000RIFFslow'
                else
                    printf '\004\000\000\000RIFF'
                fi
            done
            """#
        try worker.prepare(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", command],
            environment: ["PATH": "/usr/bin:/bin"])
        defer { worker.close() }
        let audio = Data("RIFF".utf8)
        #expect(try await worker.speak(Data("first".utf8)) == audio)
        #expect(try await worker.speak(Data("second".utf8)) == audio)

        let playing = Task { try await worker.speak(Data("slow".utf8)) }
        try await Task.sleep(for: .milliseconds(50))
        let queued = Task { try await worker.speak(Data("next".utf8)) }
        await Task.yield()
        playing.cancel()
        do {
            _ = try await playing.value
            Issue.record("A cancelled synthesis returned audio.")
        } catch is CancellationError {
            #expect(try await queued.value == audio)
            #expect(try await worker.speak(Data("later".utf8)) == audio)
        }
    }

    @Test func aStalledCancelledFrameRestartsTheWorkerAndServesTheQueue() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let started = root.appendingPathComponent("started")
        let worker = KokoroVoiceWorker()
        defer { worker.close() }
        let command = #"""
            while IFS= read -r request; do
                if [ "$request" = "hang" ]; then
                    : > "$1"
                    exec /bin/sleep 30
                fi
                printf '\004\000\000\000RIFF'
            done
            """#
        try worker.prepare(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", command, "worker", started.path],
            environment: ["PATH": "/usr/bin:/bin"])

        let stalled = Task { try await worker.speak(Data("hang".utf8)) }
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: started.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(FileManager.default.fileExists(atPath: started.path))
        let queued = Task { try await worker.speak(Data("next".utf8)) }
        let start = ContinuousClock.now
        stalled.cancel()
        await #expect(throws: CancellationError.self) { try await stalled.value }
        #expect(try await queued.value == Data("RIFF".utf8))
        #expect(start.duration(to: .now) < .seconds(5))
    }

}
