import AVFoundation
import Speech

/// A recognizer session the mic feeds and the meter can cancel.
protocol VoiceTranscriberSession: VoiceRecognitionRequest {
    /// Full text so far (finalized + volatile), whether the session ended, and why.
    /// Delivered on the main actor; set before audio arrives.
    var onResult: (@MainActor (String?, Bool, (any Error)?) -> Void)? { get set }
    func cancel()
}

/// Apple's newer on-device recognizer on macOS 26.
/// Herm falls back to the classic recognizer until its language asset is ready
/// or if a session fails before hearing anything.
@available(macOS 26, *)
@MainActor
final class VoiceTranscriber {
    static let shared = VoiceTranscriber()

    private var requestedLocale: Locale = .current
    private(set) var preparedLocale: Locale?
    private var preparationGeneration = 0
    private var format: AVAudioFormat?
    private var preparation: Task<Bool, Never>?
    private var hasUnsupportedLocale = false
    private var assetRetryAfter: ContinuousClock.Instant?
    private var retryAfter: ContinuousClock.Instant?

    func isSupported(for locale: Locale) -> Bool {
        SpeechTranscriber.isAvailable && (requestedLocale != locale || !hasUnsupportedLocale)
    }

    func select(_ locale: Locale) {
        guard requestedLocale != locale else { return }
        requestedLocale = locale
        preparationGeneration &+= 1
        preparation?.cancel()
        preparation = nil
        preparedLocale = nil
        format = nil
        hasUnsupportedLocale = false
        assetRetryAfter = nil
        retryAfter = nil
    }

    /// Coalesce model downloads across the idle wake listener and active calls.
    /// A missing locale is definitive. An install or format failure is not.
    @discardableResult
    func prepare(locale requested: Locale, retry: Bool = false) -> Task<Bool, Never>? {
        select(requested)
        if let preparation { return preparation }
        if retry {
            format = nil
            preparedLocale = nil
            hasUnsupportedLocale = false
        }
        let setup = VoiceRecognitionSetup.shared
        if let preparedLocale, format != nil {
            setup.report(.ready(preparedLocale), for: requested)
            return nil
        }
        guard isSupported(for: requested) else {
            setup.report(.unavailable, for: requested)
            return nil
        }
        guard retry || (assetRetryAfter.map { .now >= $0 } ?? true) else { return nil }
        setup.report(.checking, for: requested)
        let generation = preparationGeneration
        let task = Task {
            defer { if generation == preparationGeneration { preparation = nil } }
            let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: requested)
            guard !Task.isCancelled, generation == preparationGeneration else { return false }
            guard let locale = resolved else {
                // An empty inventory can also mean the speech service hasn't responded.
                let supported = await SpeechTranscriber.supportedLocales
                guard !Task.isCancelled, generation == preparationGeneration else { return false }
                hasUnsupportedLocale = !supported.isEmpty
                setup.report(hasUnsupportedLocale ? .unavailable : .failed, for: requested)
                assetRetryAfter = .now + .seconds(15)
                return false
            }
            let probe = Self.transcriber(locale)
            for attempt in 0..<2 {
                do {
                    if let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
                        guard !Task.isCancelled, generation == preparationGeneration else { return false }
                        setup.report(.installing, for: requested)
                        DebugLog.write("voice: downloading the on-device speech model")
                        try await request.downloadAndInstall()
                    }
                    let installed = await AssetInventory.status(forModules: [probe]) == .installed
                    let resolvedFormat =
                        installed ? await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [probe]) : nil
                    guard !Task.isCancelled, generation == preparationGeneration else { return false }
                    if let format = resolvedFormat {
                        preparedLocale = locale
                        self.format = format
                        setup.report(.ready(locale), for: requested)
                        DebugLog.write("voice: using SpeechTranscriber")
                        return true
                    }
                } catch {
                    guard !Task.isCancelled, generation == preparationGeneration else { return false }
                    DebugLog.write(
                        "voice: speech model unavailable: "
                            + HermesDiagnosticsService.safeSummary(error.localizedDescription))
                }
                if attempt == 0 { try? await Task.sleep(for: .seconds(3)) }
            }
            guard !Task.isCancelled, generation == preparationGeneration else { return false }
            setup.report(.failed, for: requested)
            assetRetryAfter = .now + .seconds(15)
            return false
        }
        preparation = task
        return task
    }

    func makeSession(
        vocabulary: [String], wakeNames: [String], ignoreCooldown: Bool = false
    ) -> (any VoiceTranscriberSession)? {
        guard let locale = preparedLocale, let format,
            ignoreCooldown || (retryAfter.map { .now >= $0 } ?? true)
        else { return nil }
        let generation = preparationGeneration
        return TranscriberSession(
            transcriber: Self.transcriber(locale, wakeOnly: !wakeNames.isEmpty), format: format,
            vocabulary: vocabulary, wakeNames: wakeNames,
            onEarlyFailure: { [weak self] in
                guard let self, generation == preparationGeneration else { return }
                DebugLog.write("voice: SpeechTranscriber failed; using the classic recognizer")
                // A runtime hiccup falls back for the next turn, not the life of the app.
                retryAfter = .now + .seconds(15)
            })
    }

    private static func transcriber(_ locale: Locale, wakeOnly: Bool = false) -> SpeechTranscriber {
        // Volatile results drive live captions; the final result is what Herm submits,
        // with alternatives only while waiting for the wake phrase.
        SpeechTranscriber(
            locale: locale, transcriptionOptions: [],
            reportingOptions: wakeOnly ? [.volatileResults, .alternativeTranscriptions] : [.volatileResults],
            attributeOptions: [])
    }
}

enum VoiceTranscriptText {
    /// An alternative can fix the wake address, but cannot supply a different command.
    static func wakeAlternative(
        _ candidates: [String], matching primary: String, names: [String], after finalized: String = ""
    ) -> String? {
        for candidate in candidates {
            let candidate = join("", candidate)
            guard let request = VoicePrompts.afterWakePhrase(join(finalized, candidate), names: names) else { continue }
            if request.isEmpty { return candidate }
            guard candidate.hasSuffix(request) else { continue }
            let address = candidate.dropLast(request.count).trimmingCharacters(in: .whitespacesAndNewlines)
            let best = join("", primary)
            let addressCount = address.split(separator: " ").count
            let bestWords = best.split(separator: " ")
            let beginsWithGreeting =
                !finalized.isEmpty
                || bestWords.first.map {
                    ["hey", "hi", "hello", "ok", "okay"].contains(
                        $0.lowercased().trimmingCharacters(in: .punctuationCharacters))
                } == true
            guard beginsWithGreeting, bestWords.count > addressCount else { return address }
            let bestRequest = bestWords.dropFirst(addressCount).joined(separator: " ")
            let comparison = CharacterSet.punctuationCharacters
            if bestRequest.trimmingCharacters(in: comparison)
                .caseInsensitiveCompare(request.trimmingCharacters(in: comparison)) == .orderedSame
            {
                return join(address, bestRequest)
            }
            return address
        }
        return nil
    }

    static func join(_ finalized: String, _ next: String) -> String {
        let tail = next.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !tail.isEmpty else { return finalized }
        guard !finalized.isEmpty else { return tail }
        let space = tail.first.map { ",.!?;:。！？".contains($0) } == true ? "" : " "
        return finalized + space + tail
    }
}

/// One utterance. The mic's tap thread calls `append`/`endAudio` serially under
/// `RecognitionFeed`'s lock; everything else runs on the main actor.
@available(macOS 26, *)
private final class TranscriberSession: VoiceTranscriberSession, @unchecked Sendable {
    var onResult: (@MainActor (String?, Bool, (any Error)?) -> Void)?
    private let format: AVAudioFormat
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private let analyzer: SpeechAnalyzer
    private let onEarlyFailure: @MainActor () -> Void
    private var results: Task<Void, Never>?
    private var converter: AVAudioConverter?
    private let lock = NSLock()
    private var cancelled = false
    private var inputOverran = false

    @MainActor
    init(
        transcriber: SpeechTranscriber, format: AVAudioFormat, vocabulary: [String], wakeNames: [String],
        onEarlyFailure: @escaping @MainActor () -> Void
    ) {
        self.format = format
        self.onEarlyFailure = onEarlyFailure
        // Bound audio retained if the speech service stops pulling from its input.
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingOldest(128))
        input = continuation
        let context = AnalysisContext()
        if !vocabulary.isEmpty { context.contextualStrings = [.general: vocabulary] }
        analyzer = SpeechAnalyzer(
            inputSequence: stream, modules: [transcriber],
            options: .init(priority: .userInitiated, modelRetention: .processLifetime), analysisContext: context)
        results = Task { @MainActor [weak self] in
            var finalized = ""
            var volatile = ""
            do {
                for try await result in transcriber.results {
                    var text = String(result.text.characters)
                    if !text.isEmpty, !wakeNames.isEmpty,
                        VoicePrompts.afterWakePhrase(VoiceTranscriptText.join(finalized, text), names: wakeNames) == nil
                    {
                        text =
                            VoiceTranscriptText.wakeAlternative(
                                result.alternatives.prefix(4).map { String($0.characters) }, matching: text,
                                names: wakeNames, after: finalized) ?? text
                    }
                    if result.isFinal {
                        finalized = VoiceTranscriptText.join(finalized, text)
                        volatile = ""
                    } else {
                        volatile = text
                    }
                    self?.deliver(VoiceTranscriptText.join(finalized, volatile), ended: false)
                }
                // The last volatile text was only a caption, not a finalized command.
                if volatile.isEmpty {
                    self?.deliver(finalized, ended: true)
                } else {
                    self?.deliver(nil, ended: true, error: IncompleteResult())
                }
            } catch {
                if finalized.isEmpty, volatile.isEmpty, !(error is CancellationError),
                    self?.isAcceptingRecognition == true
                {
                    onEarlyFailure()
                }
                self?.deliver(nil, ended: true, error: error)
            }
        }
    }

    private struct IncompleteResult: Error {}
    private struct InputOverrun: Error {}

    private var isAcceptingRecognition: Bool { lock.withLock { !cancelled && !inputOverran } }

    @MainActor private func deliver(_ text: String?, ended: Bool, error: (any Error)? = nil) {
        guard isAcceptingRecognition else { return }
        onResult?(text, ended, error)
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard isAcceptingRecognition, let converted = convert(buffer),
            case .dropped = input.yield(AnalyzerInput(buffer: converted))
        else { return }
        lock.withLock { inputOverran = true }
        input.finish()
        // Do not submit a command from audio with a missing tail.
        Task { @MainActor [weak self] in
            guard let self, !lock.withLock({ cancelled }) else { return }
            results?.cancel()
            onEarlyFailure()
            onResult?(nil, true, InputOverrun())
            await analyzer.cancelAndFinishNow()
        }
    }

    func endAudio() {
        guard isAcceptingRecognition else { return }
        input.finish()
        let analyzer = analyzer
        Task { try? await analyzer.finalizeAndFinishThroughEndOfInput() }
    }

    func cancel() {
        lock.withLock { cancelled = true }
        input.finish()
        results?.cancel()
        let analyzer = analyzer
        Task { await analyzer.cancelAndFinishNow() }
    }

    /// The mic delivers mono Float32 at the device rate; the model wants its own format.
    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        if converter?.inputFormat != buffer.format { converter = AVAudioConverter(from: buffer.format, to: format) }
        guard let converter else { return nil }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        nonisolated(unsafe) var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return buffer
        }
        return status == .error || output.frameLength == 0 ? nil : output
    }
}
