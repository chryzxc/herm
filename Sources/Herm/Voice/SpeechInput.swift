import AVFoundation
import Speech
import SwiftUI

/// Audio-buffer-rate values, kept apart so only the orb re-renders per buffer
/// instead of everything observing the recorder.
@MainActor
final class VoiceMeterReading: ObservableObject {
    @Published var level: CGFloat = 0
    /// How far the pause after the last word is toward ending the turn, 0...1.
    @Published var turnProgress: Double = 0
}

@MainActor
final class SpeechInput: ObservableObject {
    @Published var isRecording = false
    @Published var isStarting = false
    @Published var isUnavailable = false
    @Published var transcript = ""
    @Published var errorMessage: String?
    @Published var completedTranscript: String?
    /// Dictation fills the composer instead of submitting: no completedTranscript is published.
    let isDictation: Bool

    init(isDictation: Bool = false) { self.isDictation = isDictation }
    /// Smoothed microphone loudness in the 0...1 range for the voice orb.
    let reading = VoiceMeterReading()
    private(set) var audioLevel: CGFloat {
        get { reading.level }
        set { reading.level = newValue }
    }

    private let recognizer = SFSpeechRecognizer(locale: Locale.current)
    private(set) var audioEngine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var isStopping = false
    private var startGeneration = 0
    private var silenceTask: Task<Void, Never>?
    func toggle() {
        if isRecording {
            stop()
        } else {
            startListening()
        }
    }

    /// Begins one recognition turn. Call this again after Hermes has replied to
    /// continue a hands-free conversation.
    func startListening() {
        guard !isRecording, !isStarting else { return }
        startGeneration &+= 1
        // `stop()` cancels callbacks from its recognition turn. Clear that
        // marker before waiting on asynchronous permission callbacks for this
        // new turn, or every listen after the first completed turn exits at
        // the cancellation guard below. The generation still rejects stale
        // callbacks from the old turn.
        isStopping = false
        isUnavailable = false
        errorMessage = nil
        transcript = ""
        requestPermissionsAndStart(generation: startGeneration)
    }

    func stop() {
        startGeneration &+= 1
        isStopping = true
        silenceTask?.cancel()
        silenceTask = nil
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        request?.endAudio()
        recognitionTask?.cancel()
        request = nil
        recognitionTask = nil
        isRecording = false
        isStarting = false
        audioLevel = 0
    }

    /// Submits the partial transcript now instead of waiting for silence.
    func finishUtterance() {
        guard isRecording else { return }
        completedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        stop()
    }

    func consumeCompletedTranscript() {
        completedTranscript = nil
    }

    func reset() {
        stop()
        completedTranscript = nil
        transcript = ""
        errorMessage = nil
        isUnavailable = false
    }

    func dismissError() {
        errorMessage = nil
        isUnavailable = false
    }

    /// Assistant playback must never share a recognition turn. Cancelling the
    /// request before TTS starts prevents the system recognizer from treating
    /// Hermes's speaker output as a new user message.
    func stopForAssistantSpeech() {
        completedTranscript = nil
        transcript = ""
        stop()
    }

    private func requestPermissionsAndStart(generation: Int) {
        isStarting = true
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            isStarting = false
            isUnavailable = true
            errorMessage = "Voice input requires the packaged Herm app."
            return
        }
        guard hasUsageDescription("NSSpeechRecognitionUsageDescription"),
            hasUsageDescription("NSMicrophoneUsageDescription")
        else {
            isStarting = false
            isUnavailable = true
            errorMessage = "This app build is missing voice permissions. Rebuild the Herm app bundle."
            return
        }
        Task { [weak self] in
            guard let self, self.startGeneration == generation, !self.isStopping else { return }
            guard await Self.requestSpeechAuthorization() == .authorized else {
                guard self.startGeneration == generation, !self.isStopping else { return }
                self.isStarting = false
                self.isUnavailable = true
                self.errorMessage = "Speech recognition permission is required."
                return
            }
            guard self.startGeneration == generation, !self.isStopping else { return }
            guard await Self.requestMicrophoneAuthorization() else {
                guard self.startGeneration == generation, !self.isStopping else { return }
                self.isStarting = false
                self.isUnavailable = true
                self.errorMessage = "Microphone permission is required."
                return
            }
            guard self.startGeneration == generation, !self.isStopping else { return }
            self.start(generation: generation)
        }
    }

    nonisolated static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        let status = SFSpeechRecognizer.authorizationStatus()
        guard status == .notDetermined else { return status }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    nonisolated static func requestMicrophoneAuthorization() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        guard status == .notDetermined else { return status == .authorized }
        return await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private nonisolated static func installAudioTap(
        on inputNode: AVAudioInputNode,
        request: SFSpeechAudioBufferRecognitionRequest,
        onAudioLevel: @escaping (CGFloat) -> Void
    ) {
        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: nil) { buffer, _ in
            request.append(buffer)
            onAudioLevel(normalizedAudioLevel(buffer))
        }
    }

    nonisolated static func normalizedAudioLevel(_ buffer: AVAudioPCMBuffer) -> CGFloat {
        guard let channels = buffer.floatChannelData else { return 0 }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return 0 }

        let samples = channels[0]
        var sum: Float = 0
        for index in 0..<frameCount {
            let sample = samples[index]
            sum += sample * sample
        }
        let rms = sqrt(sum / Float(frameCount))
        let decibels = 20 * log10(max(rms, 0.000_001))
        // Speech normally lives between roughly -55 dB (silence) and -10 dB.
        return CGFloat(min(1, max(0, (decibels + 55) / 45)))
    }

    private func start(generation: Int) {
        guard startGeneration == generation, !isStopping else { return }
        guard let recognizer, recognizer.isAvailable else {
            isStarting = false
            isUnavailable = true
            errorMessage = "Speech recognition is currently unavailable."
            return
        }

        transcript = ""
        isStopping = false
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        self.request = request

        let audioEngine = AVAudioEngine()
        self.audioEngine = audioEngine
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            stop()
            isStarting = false
            isUnavailable = true
            errorMessage = "No microphone input device is available."
            return
        }
        inputNode.removeTap(onBus: 0)
        Self.installAudioTap(on: inputNode, request: request) { [weak self] level in
            Task { @MainActor [weak self] in
                self?.updateAudioLevel(level)
            }
        }

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.request === request else { return }
                guard !isStopping else { return }
                if let result {
                    transcript = result.bestTranscription.formattedString
                    scheduleAutomaticSubmit(after: transcript)
                }
                switch VoiceRecognitionCompletion.resolve(
                    transcript, isFinal: result?.isFinal == true, hasError: error != nil)
                {
                case .listening:
                    break
                case .finished(let text):
                    stop()
                    if !isDictation { completedTranscript = text }
                case .failed:
                    errorMessage = "Speech recognition couldn’t continue. Try again."
                    isUnavailable = true
                    stop()
                }
            }
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
            isRecording = true
            isStarting = false
        } catch {
            stop()
            isUnavailable = true
            errorMessage = "Could not start the microphone: \(error.localizedDescription)"
        }
    }

    private func hasUsageDescription(_ key: String) -> Bool {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func scheduleAutomaticSubmit(after transcript: String) {
        silenceTask?.cancel()
        guard !isDictation else { return }
        silenceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled,
                let self,
                self.isRecording,
                self.transcript == transcript
            else { return }
            completedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            stop()
        }
    }

    private func updateAudioLevel(_ level: CGFloat) {
        // Fast attack keeps speech responsive; a slower release avoids a jittery orb.
        let smoothing: CGFloat = level > audioLevel ? 0.52 : 0.14
        audioLevel += (level - audioLevel) * smoothing
    }
}

/// Recognition can end with an error after successfully producing words.
/// Keep that utterance instead of losing it behind a Retry message.
enum VoiceRecognitionCompletion: Equatable {
    case listening
    case finished(String)
    case failed

    static func resolve(_ transcript: String, isFinal: Bool, hasError: Bool) -> Self {
        guard isFinal || hasError else { return .listening }
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        return hasError && text.isEmpty ? .failed : .finished(text)
    }
}

/// Microphone tap and live transcription for the voice orb.
/// CoreAudio shares input devices between processes, so this never competes
/// with Hermes' recorder. While endpointing it also transcribes on-device, so
/// captions follow the user live and a turn submits the moment they stop
/// talking instead of waiting on Hermes' whisper pass.
@MainActor
final class MicLevelMeter: ObservableObject {
    @Published private(set) var errorMessage: String?
    @Published private(set) var isStarting = false
    @Published private(set) var isRunning = false
    let reading = VoiceMeterReading()
    private(set) var level: CGFloat {
        get { reading.level }
        set { reading.level = newValue }
    }
    /// Live on-device transcript of the current utterance.
    @Published private(set) var transcript = ""
    private(set) var turnProgress: Double {
        get { reading.turnProgress }
        set { reading.turnProgress = newValue }
    }
    /// Called once per utterance when `isEndpointing` and the speaker stops,
    /// with the transcript, or nil once on-device recognition has failed.
    var onUtteranceEnd: ((String?) -> Void)?
    /// Called while endpointing once nobody has spoken for `idleLimit`.
    var onIdle: (() -> Void)?
    /// A quiet gap with no partial words, safe for a pending result announcement.
    var onQuiet: (() -> Void)?
    var idleLimit: TimeInterval = 30
    /// Hermes' own VAD uses a fixed RMS threshold, so steady room noise keeps
    /// it recording until the user presses send. While this is on, Herm ends
    /// the turn itself against an adaptive noise floor.
    private(set) var isEndpointing = false
    /// While a reply plays: transcribe without ending turns, reporting each
    /// partial to `onBargeSpeech` so talking over the reply can cut it off.
    private(set) var isWatchingForBarge = false
    var onBargeSpeech: ((String) -> Bool)?
    private var acceptedBargeIn = false

    /// Starts a fresh transcript for the next voice state.
    func listen(endpointing: Bool, watchingForBarge: Bool) {
        let preserveUtterance = acceptedBargeIn && isWatchingForBarge && endpointing
        acceptedBargeIn = false
        isEndpointing = endpointing
        isWatchingForBarge = watchingForBarge && !endpointing
        endpoint.beginTurn()
        pendingEndSince = nil
        turnProgress = 0
        // The words that stopped playback belong to the next request. Keep
        // the same recognition task so its later partials extend those words.
        if preserveUtterance {
            heardPlayback = false
        } else {
            restartRecognition()
        }
    }
    /// The transcript to submit now, or nil when on-device recognition failed.
    var utteranceTranscript: String? { recognitionFailures > 2 ? nil : transcript }

    /// Whether Herm can transcribe voice turns itself.
    static var canTranscribe: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
            && SFSpeechRecognizer.authorizationStatus() == .authorized
            && SFSpeechRecognizer(locale: .current)?.isAvailable == true
    }

    /// Asks once, so the first voice turn can already transcribe on-device.
    static func askForSpeechPermission() async {
        guard Bundle.main.bundleURL.pathExtension == "app",
            SFSpeechRecognizer.authorizationStatus() == .notDetermined
        else { return }
        _ = await SpeechInput.requestSpeechAuthorization()
    }

    /// Listening for the wake phrase while asleep stays on this Mac.
    static var canDetectWakePhrase: Bool {
        canTranscribe && SFSpeechRecognizer(locale: .current)?.supportsOnDeviceRecognition == true
    }

    private var endpoint = VoiceEndpointDetector()
    private var engine: AVAudioEngine?
    private var generation = 0
    private let recognizer = SFSpeechRecognizer(locale: .current)
    private let feed = RecognitionFeed()
    private var recognitionTask: SFSpeechRecognitionTask?
    /// Text from earlier recognition requests in this utterance; the
    /// recognizer ends a request on long pauses and errors.
    private var committedTranscript = ""
    /// The current request's latest partial text.
    private var requestText = ""
    private var recognitionFailures = 0
    private var requestHeardSpeech = false
    private var requestStartedAt: TimeInterval = 0
    /// When the mic went quiet; the turn ends once the transcript settles.
    private var pendingEndSince: TimeInterval?
    private var lastWordAt: TimeInterval = 0
    private var lastLoudAt: TimeInterval = 0
    /// This turn's audio for the smart-turn model, when it is installed.
    private let turnAudio = TurnAudio()
    /// The model's call on the current pause: finished, still going, or not asked.
    private var turnVerdict: Bool?
    private var checkedPause: TimeInterval?
    /// Something played through the speakers during this utterance, so the
    /// mic may have heard Hermes' own reply (a late TTS sentence).
    private(set) var heardPlayback = false

    func start() {
        guard engine == nil, !isStarting else { return }
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            errorMessage = "Voice input requires the packaged Herm app."
            return
        }
        errorMessage = nil
        isStarting = true
        generation &+= 1
        let expected = generation
        recognitionFailures = 0
        Task { [weak self] in
            guard let self, self.generation == expected, self.isStarting else { return }
            // TCC answers on a background queue; main-actor callbacks trap there.
            let granted = await SpeechInput.requestMicrophoneAuthorization()
            guard self.generation == expected, self.isStarting else { return }
            guard granted else {
                self.isStarting = false
                self.errorMessage =
                    "Allow microphone access in System Settings → Privacy & Security → Microphone, then retry."
                return
            }
            if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
                _ = await SpeechInput.requestSpeechAuthorization()
            }
            guard self.generation == expected, self.engine == nil else { return }
            self.isStarting = false
            self.startEngine()
        }
    }

    func stop() {
        generation &+= 1
        listen(endpointing: false, watchingForBarge: false)
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        engine = nil
        isStarting = false
        isRunning = false
        level = 0
    }

    private func restartRecognition() {
        recognitionTask?.cancel()
        recognitionTask = nil
        feed.request?.endAudio()
        feed.request = nil
        committedTranscript = ""
        requestText = ""
        transcript = ""
        turnAudio.reset()
        turnVerdict = nil
        checkedPause = nil
        lastWordAt = ProcessInfo.processInfo.systemUptime
        lastLoudAt = lastWordAt
        heardPlayback = false
        beginRecognitionRequest()
    }

    private func beginRecognitionRequest() {
        guard isEndpointing || isWatchingForBarge, recognitionFailures <= 2, Self.canTranscribe, let recognizer else {
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        feed.request = request
        requestText = ""
        requestHeardSpeech = false
        requestStartedAt = ProcessInfo.processInfo.systemUptime
        let requestID = ObjectIdentifier(request)
        recognitionTask = Self.recognize(request, with: recognizer) { [weak self] text, ended, error in
            Task { @MainActor [weak self] in
                guard let self, self.feed.request.map(ObjectIdentifier.init) == requestID else { return }
                if let text, !text.isEmpty {
                    self.receiveRecognizedText(text)
                }
                guard self.feed.request.map(ObjectIdentifier.init) == requestID, ended else { return }
                // The recognizer gives up after silence or ~1 minute; keep
                // listening with a fresh request. Repeated empty failures mean
                // it is unusable (dictation off, no on-device model).
                // A quiet room also ends requests with an error ("no speech
                // detected") after a few seconds; counting those switched voice
                // to Hermes' recorder for good. Only instant failures count.
                let lived = ProcessInfo.processInfo.systemUptime - self.requestStartedAt
                if VoiceEndpointDetector.isRecognizerFailure(
                    heardSpeech: self.requestHeardSpeech, failed: error != nil, lived: lived)
                {
                    self.recognitionFailures += 1
                }
                self.committedTranscript = self.transcript
                self.feed.request = nil
                if self.recognitionFailures > 2, self.isEndpointing {
                    self.onUtteranceEnd?(nil)
                } else {
                    self.beginRecognitionRequest()
                }
            }
        }
    }

    func receiveRecognizedText(_ text: String) {
        guard isEndpointing || isWatchingForBarge else { return }
        requestHeardSpeech = true
        recognitionFailures = 0
        // On-device recognition can restart its partial text after a pause
        // without ending the request; keep the words said before the pause.
        if VoiceEndpointDetector.startsNewSegment(
            previous: requestText, next: text, pause: ProcessInfo.processInfo.systemUptime - lastWordAt)
        {
            committedTranscript = transcript
        }
        requestText = text
        let updated = [committedTranscript, text].filter { !$0.isEmpty }.joined(separator: " ")
        if updated != transcript {
            lastWordAt = ProcessInfo.processInfo.systemUptime
            turnVerdict = nil
        }
        transcript = updated
        if isWatchingForBarge, !acceptedBargeIn { acceptedBargeIn = onBargeSpeech?(transcript) == true }
    }

    private func startEngine(cancellingEcho: Bool = true) {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if cancellingEcho { Self.cancelEcho(on: engine) }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            errorMessage = "No microphone input is available. Connect a microphone and retry."
            return
        }
        let expected = generation
        Self.installTap(on: input, feed: feed, turnAudio: turnAudio) { [weak self] value in
            Task { @MainActor [weak self] in
                guard let self, self.generation == expected else { return }
                let smoothing: CGFloat = value > self.level ? 0.5 : 0.12
                self.level += (value - self.level) * smoothing
                guard self.isEndpointing else { return }
                let now = ProcessInfo.processInfo.systemUptime
                if !self.heardPlayback, VoiceAudioOutput.isOutputRunning() == true { self.heardPlayback = true }
                if self.endpoint.ingest(level: Double(value), at: now) {
                    self.pendingEndSince = self.pendingEndSince ?? now
                }
                if self.endpoint.isHearingSpeech {
                    self.lastLoudAt = now
                    self.turnVerdict = nil
                }
                self.askTurnModel(at: now)
                let progress =
                    self.endpoint.isHearingSpeech || (self.utteranceTranscript ?? "").isEmpty
                    ? 0
                    : min(
                        1,
                        (now - self.lastWordAt)
                            / VoiceEndpointDetector.turnHold(
                                self.utteranceTranscript ?? "", quietSince: self.pendingEndSince,
                                finished: self.turnVerdict))
                if abs(progress - self.turnProgress) > 0.03 || (progress == 0) != (self.turnProgress == 0) {
                    self.turnProgress = progress
                }
                // Words trail the audio, and a soft voice can stay under the
                // level detector, so the transcript also ends (and keeps awake) a turn.
                if VoiceEndpointDetector.shouldEndTurn(
                    self.utteranceTranscript, lastWordAt: self.lastWordAt, quietSince: self.pendingEndSince, now: now,
                    finished: self.turnVerdict, isHearingSpeech: self.endpoint.isHearingSpeech
                ) {
                    self.pendingEndSince = nil
                    self.onUtteranceEnd?(self.utteranceTranscript)
                    // Each utterance starts from a clean transcript, so words
                    // heard while asleep never pile up into the next one.
                    if self.isEndpointing { self.restartRecognition() }
                } else if self.pendingEndSince == nil, self.transcript.isEmpty {
                    if self.endpoint.heardNothing(for: self.idleLimit, at: now) {
                        self.onIdle?()
                    } else if self.endpoint.heardNothing(for: 1.5, at: now) {
                        self.onQuiet?()
                    }
                }
            }
        }
        do {
            try engine.start()
            self.engine = engine
            isRunning = true
            // Speech permission may have arrived after `listen` was called.
            if feed.request == nil { beginRecognitionRequest() }
        } catch {
            input.removeTap(onBus: 0)
            // Some input devices refuse voice processing: listen without it rather than not at all.
            if input.isVoiceProcessingEnabled {
                DebugLog.write("voice: echo cancellation failed to start; using the plain microphone")
                startEngine(cancellingEcho: false)
            } else {
                errorMessage =
                    "Couldn’t start the microphone: " + HermesDiagnosticsService.safeSummary(error.localizedDescription)
            }
        }
    }

    /// macOS voice processing subtracts whatever the output device plays
    /// (Hermes' `afplay` TTS included) from the mic, so replies aren't heard
    /// as the user. Other audio keeps its volume. Must run before the engine starts.
    private nonisolated static func cancelEcho(on engine: AVAudioEngine) {
        let input = engine.inputNode
        guard (try? input.setVoiceProcessingEnabled(true)) != nil, input.isVoiceProcessingEnabled else { return }
        input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
        _ = engine.mainMixerNode  // joins the output node, which carries the echo reference
    }

    /// Once per pause, asks the smart-turn model (if downloaded) whether the
    /// speaker sounds done; a few ms, so the verdict lands before any hold expires.
    private func askTurnModel(at now: TimeInterval) {
        let pause = max(lastLoudAt, lastWordAt)
        guard let predictor = TurnModelStore.shared.predictor, !transcript.isEmpty, !endpoint.isHearingSpeech,
            now - pause >= 0.25, checkedPause != pause
        else { return }
        checkedPause = pause
        predictor.isComplete(turnAudio.snapshot()) { complete in
            Task { @MainActor [weak self] in
                guard let self, max(self.lastLoudAt, self.lastWordAt) == pause else { return }
                self.turnVerdict = complete
            }
        }
    }

    /// Speech calls back on its own queue, so the handler must not be main-actor isolated.
    private nonisolated static func recognize(
        _ request: SFSpeechAudioBufferRecognitionRequest,
        with recognizer: SFSpeechRecognizer,
        onResult: @escaping @Sendable (String?, Bool, (any Error)?) -> Void
    ) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, error in
            onResult(result?.bestTranscription.formattedString, error != nil || result?.isFinal == true, error)
        }
    }

    private nonisolated static func installTap(
        on input: AVAudioInputNode, feed: RecognitionFeed, turnAudio: TurnAudio,
        onLevel: @escaping @Sendable (CGFloat) -> Void
    ) {
        let firstChannelOnly = input.isVoiceProcessingEnabled
        input.installTap(onBus: 0, bufferSize: 1_024, format: nil) { buffer, _ in
            guard let buffer = firstChannelOnly ? firstChannel(of: buffer) : buffer else { return }
            feed.request?.append(buffer)
            turnAudio.append(buffer)
            onLevel(SpeechInput.normalizedAudioLevel(buffer))
        }
    }

    /// Voice processing hands the tap extra channels (3 on most Macs); only
    /// channel 0 is the cleaned voice, the rest would mix the echo back in.
    nonisolated static func firstChannel(of buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.format.channelCount > 1 else { return buffer }
        guard let source = buffer.floatChannelData, !buffer.format.isInterleaved,
            let mono = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: buffer.format.sampleRate, channels: 1, interleaved: false),
            let out = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: buffer.frameLength),
            let target = out.floatChannelData
        else { return nil }
        out.frameLength = buffer.frameLength
        target[0].update(from: source[0], count: Int(buffer.frameLength))
        return out
    }
}

/// The recognition request the audio thread feeds, swapped from the main actor.
private final class RecognitionFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var current: SFSpeechAudioBufferRecognitionRequest?

    var request: SFSpeechAudioBufferRecognitionRequest? {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
}

/// End-of-speech detection on normalized mic levels (0...1 over -55...-10 dB).
/// Speech is anything `margin` above a noise floor that follows the room, so a
/// fan or air conditioner no longer reads as endless talking.
struct VoiceEndpointDetector {
    /// Calibration knobs: ~8 dB above the floor, 0.3s to confirm speech (skips
    /// Hermes' start beep and clicks), 1.2s of quiet ends the turn.
    var margin = 0.18
    var minSpeech: TimeInterval = 0.3
    var endSilence: TimeInterval = 1.2
    private(set) var noiseFloor: Double?
    private var speechStart: TimeInterval?
    private var silenceStart: TimeInterval?
    private var hasSpoken = false
    private var turnStart: TimeInterval?
    /// The latest frame is above the noise floor: someone is mid-word.
    private(set) var isHearingSpeech = false

    /// Keeps the learned noise floor; forgets any half-heard utterance.
    mutating func beginTurn() {
        turnStart = nil
        speechStart = nil
        silenceStart = nil
        hasSpoken = false
        isHearingSpeech = false
    }

    /// Returns true once, when confirmed speech is followed by `endSilence` of quiet.
    mutating func ingest(level: Double, at time: TimeInterval) -> Bool {
        turnStart = turnStart ?? time
        let floor = noiseFloor ?? min(level, 0.25)
        let isLoud = level > floor + margin
        // Quiet frames pull the floor quickly; loud ones only creep it up, so
        // a noise source that switches on is learned within ~10s.
        noiseFloor = floor + (level - floor) * (isLoud ? 0.002 : 0.05)

        isHearingSpeech = isLoud
        if isLoud {
            silenceStart = nil
            let start = speechStart ?? time
            speechStart = start
            if time - start >= minSpeech { hasSpoken = true }
            return false
        }
        guard hasSpoken else {
            speechStart = nil
            return false
        }
        let quietSince = silenceStart ?? time
        silenceStart = quietSince
        guard time - quietSince >= endSilence else { return false }
        beginTurn()
        return true
    }

    /// `quietSince` is when the level detector heard the speaker stop. With
    /// words, the wait after the last one depends on how the sentence ends:
    /// short when it sounds finished, long when it trails off ("and…", "um…").
    /// Without words, 3s of quiet ends it as noise. A nil transcript means no recognizer.
    /// `finished` is the smart-turn model's verdict when installed; it replaces
    /// the trailing-word guess and leaves 0.5s for the last words to transcribe.
    static func shouldEndTurn(
        _ transcript: String?, lastWordAt: TimeInterval, quietSince: TimeInterval?, now: TimeInterval,
        finished: Bool? = nil, isHearingSpeech: Bool = false
    ) -> Bool {
        // New words extend a turn; steady background noise cannot hold it forever.
        if isHearingSpeech {
            guard let transcript, !transcript.isEmpty else { return false }
            return now - lastWordAt >= 4
        }
        guard let transcript else { return quietSince != nil }
        if transcript.isEmpty { return quietSince.map { now - $0 >= 3 } ?? false }
        return now - lastWordAt >= turnHold(transcript, quietSince: quietSince, finished: finished)
    }

    /// How long after the last word a turn ends.
    static func turnHold(_ transcript: String, quietSince: TimeInterval?, finished: Bool?) -> TimeInterval {
        let hold: TimeInterval = finished.map { $0 ? 0.5 : 3 } ?? (trailsOff(transcript) ? 3 : 0.8)
        // Under the level threshold the meter can't confirm the pause; wait a bit more.
        return hold + (quietSince == nil ? 0.4 : 0)
    }

    /// Whether the last word leaves the sentence hanging.
    /// A partial that no longer begins like the previous one, after a pause,
    /// is a fresh segment rather than a revision of the earlier words.
    // ponytail: first-word heuristic; a late revision of the first word after
    // a pause would repeat it. Use segment timestamps if that shows up.
    static func startsNewSegment(previous: String, next: String, pause: TimeInterval) -> Bool {
        guard pause >= 0.5 else { return false }
        func words(_ text: String) -> [Substring] {
            text.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "'" }
        }
        let old = words(previous)
        let new = words(next)
        guard let first = old.first, let start = new.first else { return false }
        return start != first && new.count <= old.count
    }

    static func trailsOff(_ transcript: String) -> Bool {
        guard let last = transcript.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "'" }).last else {
            return false
        }
        return unfinishedEndings.contains(String(last))
    }

    private static let unfinishedEndings: Set<String> = [
        "and", "or", "but", "so", "because", "cause", "then", "if", "when", "while", "that", "which", "who",
        "the", "a", "an", "my", "your", "our", "their", "this", "these", "those", "some", "any",
        "to", "of", "for", "with", "in", "on", "at", "about", "from", "into", "like", "as", "by",
        "is", "are", "was", "were", "be", "can", "could", "should", "would", "will", "want", "need",
        "um", "uh", "uhm", "hmm", "er", "erm", "also", "maybe", "just", "i", "i'm", "we", "you",
    ]

    /// A request that errors before hearing anything, within a second of
    /// starting, means recognition is unusable (dictation off, no model).
    static func isRecognizerFailure(heardSpeech: Bool, failed: Bool, lived: TimeInterval) -> Bool {
        failed && !heardSpeech && lived < 1
    }

    /// True once `limit` has passed this turn with no one speaking.
    func heardNothing(for limit: TimeInterval, at time: TimeInterval) -> Bool {
        guard let turnStart, speechStart == nil, !hasSpoken else { return false }
        return time - turnStart >= limit
    }
}
