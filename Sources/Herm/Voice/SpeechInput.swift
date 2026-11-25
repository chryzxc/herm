import AVFoundation
import AppKit
import Combine
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
        let normalizer = MicBufferNormalizer(firstChannelOnly: false)
        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: nil) { buffer, _ in
            guard let buffer = normalizer.normalize(buffer) else { return }
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
    @Published private(set) var isPreparingSpeech = false
    @Published private(set) var isRunning = false
    let reading = VoiceMeterReading()
    private(set) var level: CGFloat {
        get { reading.level }
        set { reading.level = newValue }
    }
    /// Live on-device transcript of the current utterance.
    @Published private(set) var transcript = ""

    #if DEBUG
        /// Snapshot tests drive the voice widget's captions without a microphone.
        func showForSnapshot(transcript: String, level: CGFloat, errorMessage: String?) {
            self.transcript = transcript
            self.level = level
            self.errorMessage = errorMessage
        }
    #endif
    private(set) var turnProgress: Double {
        get { reading.turnProgress }
        set { reading.turnProgress = newValue }
    }
    /// Called once per utterance when `isEndpointing` and the speaker stops,
    /// with the transcript, or nil once on-device recognition has failed.
    var onUtteranceEnd: ((String?) -> Void)?
    /// The listener stays available, but an unfinished transcript must not run a request.
    var onUnfinishedUtterance: (() -> Void)?
    let recognitionStatus = VoiceRecognitionStatus()
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
    private var requiresOnDevice = false
    private var wakeOnly = false
    private var smoothedLevel: CGFloat = 0
    private var nextOutputCheck: TimeInterval = 0
    private var nextQuietCheck: TimeInterval = 0
    private let outputIsRunning: () -> Bool?

    /// Starts a fresh transcript for the next voice state.
    func listen(
        endpointing: Bool, watchingForBarge: Bool, requiresOnDevice: Bool = false, wakeOnly: Bool = false,
        preservingUtterance: Bool = false, preservingPlaybackOnBargeIn: Bool = false
    ) {
        if preservingUtterance, isEndpointing, endpointing,
            self.requiresOnDevice == requiresOnDevice, self.wakeOnly == wakeOnly,
            !transcript.isEmpty || endpoint.isHearingSpeech || drainingRequest != nil
        {
            return
        }
        let preserveUtterance =
            acceptedBargeIn && isWatchingForBarge && endpointing
            && self.requiresOnDevice == requiresOnDevice && self.wakeOnly == wakeOnly
        self.requiresOnDevice = requiresOnDevice
        self.wakeOnly = wakeOnly
        turnAudio.isEnabled = !wakeOnly && (endpointing || watchingForBarge) && TurnModelStore.shared.predictor != nil
        nextOutputCheck = 0
        nextQuietCheck = 0
        if wakeOnly {
            smoothedLevel = 0
            if level != 0 { level = 0 }
        }
        acceptedBargeIn = false
        isEndpointing = endpointing
        isWatchingForBarge = watchingForBarge && !endpointing
        endpoint.beginTurn()
        endpoint.margin = wakeOnly ? 0.11 : 0.18
        endpoint.minSpeech = wakeOnly ? 0.18 : 0.3
        pendingEndSince = nil
        turnProgress = 0
        // The words that stopped playback belong to the next request. Keep
        // the same recognition task so its later partials extend those words.
        if preserveUtterance {
            heardPlayback = preservingPlaybackOnBargeIn
        } else {
            restartRecognition()
        }
    }
    /// The transcript to submit now, or nil when on-device recognition failed.
    var utteranceTranscript: String? { recognitionFailures > 2 ? nil : transcript }

    /// Whether Herm can transcribe voice turns itself.
    static var canTranscribe: Bool {
        guard speechAuthorized else { return false }
        let preference = VoiceRecognitionPreference.read()
        return modernSpeechSupported(preference) || recognizerAvailable(for: preference.locale)
    }

    private static var speechAuthorized: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
            && SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    private static func modernSpeechSupported(_ preference: VoiceRecognitionPreference) -> Bool {
        if #available(macOS 26, *), preference.engine == .automatic {
            return VoiceTranscriber.shared.isSupported(for: preference.locale)
        }
        return false
    }

    /// Views read availability every render, so it is re-checked at most every 2 s.
    /// A long-lived recognizer's `isAvailable` can stay stale, so each check is fresh.
    private static var availabilityCheck: (locale: Locale, at: Date, available: Bool)?
    private static func recognizerAvailable(for locale: Locale) -> Bool {
        if let check = availabilityCheck, check.locale == locale, Date().timeIntervalSince(check.at) < 2 {
            return check.available
        }
        let available = SFSpeechRecognizer(locale: locale)?.isAvailable == true
        availabilityCheck = (locale, Date(), available)
        return available
    }

    /// A successful offline support query is cached by locale.
    private static var onDeviceLocale: Locale?
    private static func supportsOnDevice(_ locale: Locale) -> Bool {
        if onDeviceLocale == locale { return true }
        let supported = SFSpeechRecognizer(locale: locale)?.supportsOnDeviceRecognition == true
        if supported { onDeviceLocale = locale }
        return supported
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
        guard speechAuthorized else { return false }
        let preference = VoiceRecognitionPreference.read()
        return modernSpeechSupported(preference)
            || (recognizerAvailable(for: preference.locale) && supportsOnDevice(preference.locale))
    }

    private var endpoint = VoiceEndpointDetector()
    private var engine: AVAudioEngine?
    private var levelUpdates: Task<Void, Never>?
    private var routeChanges: AnyCancellable?
    private var sleepChanges: AnyCancellable?
    private var routeRestart: Task<Void, Never>?
    private var isSuspended = false
    private var restartingRoute = false
    private var generation = 0
    private var preference = VoiceRecognitionPreference.read()
    private var classicRecognizer: (locale: Locale, recognizer: SFSpeechRecognizer?)?
    private let feed: RecognitionFeed
    private let cancelRecognition: (SFSpeechRecognitionTask?) -> Void
    private var drainingRequest: ObjectIdentifier?
    private var drainDeadline: Task<Void, Never>?
    private var recognitionEpoch = 0
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognitionRetry: Task<Void, Never>?
    private var speechPreparation: Task<Void, Never>?
    /// The macOS 26 analyzer session, when it replaced `recognitionTask`.
    private var transcriberSession: (any VoiceTranscriberSession)?
    /// Names the recognizer should expect (bot, projects, agents), so they aren't misheard.
    var vocabulary: [String] = []
    var wakeNames: [String] = []
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

    init(
        feed: RecognitionFeed = RecognitionFeed(),
        cancelRecognition: @escaping (SFSpeechRecognitionTask?) -> Void = { $0?.cancel() },
        outputIsRunning: @escaping () -> Bool? = VoiceAudioOutput.isOutputRunning
    ) {
        self.feed = feed
        self.cancelRecognition = cancelRecognition
        self.outputIsRunning = outputIsRunning
    }

    func start() {
        guard engine == nil, !isStarting, !isSuspended else { return }
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
            if #available(macOS 26, *), Self.speechAuthorized, preference.engine == .automatic {
                VoiceTranscriber.shared.prepare(locale: preference.locale)
            }
            self.observeSleepChanges()
            self.startEngine()
        }
    }

    func stop() {
        sleepChanges = nil
        isSuspended = false
        restartingRoute = false
        tearDownEngine()
        listen(endpointing: false, watchingForBarge: false)
    }

    private func tearDownEngine() {
        generation &+= 1
        feed.acceptAudio(from: generation)
        routeChanges = nil
        routeRestart?.cancel()
        routeRestart = nil
        levelUpdates?.cancel()
        levelUpdates = nil
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        engine = nil
        isStarting = false
        isRunning = false
        smoothedLevel = 0
        if level != 0 { level = 0 }
    }

    func stopAfterRecognitionFailure(_ message: String) {
        stop()
        errorMessage = message
    }

    private func restartRecognition() {
        recognitionEpoch &+= 1
        speechPreparation?.cancel()
        speechPreparation = nil
        if isPreparingSpeech { isPreparingSpeech = false }
        recognitionRetry?.cancel()
        recognitionRetry = nil
        drainDeadline?.cancel()
        drainDeadline = nil
        drainingRequest = nil
        cancelActiveRecognition()
        feed.endAudio()
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
        preference = VoiceRecognitionPreference.read()
        beginRecognitionRequest()
    }

    private func cancelActiveRecognition() {
        cancelRecognition(recognitionTask)
        recognitionTask = nil
        transcriberSession?.cancel()
        transcriberSession = nil
    }

    private func beginRecognitionRequest() {
        guard engine != nil, isEndpointing || isWatchingForBarge, recognitionRetry == nil,
            speechPreparation == nil, recognitionFailures <= 2
        else { return }
        guard Self.speechAuthorized else {
            reportUnavailableSpeech()
            return
        }
        requestText = ""
        requestHeardSpeech = false
        requestStartedAt = ProcessInfo.processInfo.systemUptime
        let vocabulary = Self.recognizerVocabulary(vocabulary)
        let wakeNames = wakeOnly ? wakeNames : []
        if #available(macOS 26, *), preference.engine == .automatic {
            let modern = VoiceTranscriber.shared
            modern.select(preference.locale)
            if let session = modern.makeSession(vocabulary: vocabulary, wakeNames: wakeNames),
                let locale = modern.preparedLocale
            {
                useTranscriberSession(session, locale: locale)
                return
            }
        }
        let classic = classicRecognizerForTurn()
        if #available(macOS 26, *), preference.engine == .automatic {
            let modern = VoiceTranscriber.shared
            if classic == nil,
                let session = modern.makeSession(vocabulary: vocabulary, wakeNames: wakeNames, ignoreCooldown: true),
                let locale = modern.preparedLocale
            {
                useTranscriberSession(session, locale: locale)
                return
            }
            if let preparation = modern.prepare(locale: preference.locale), classic == nil {
                waitForSpeechModel(preparation)
                return
            }
        }
        guard let recognizer = classic else {
            reportUnavailableSpeech()
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.contextualStrings = vocabulary
        request.requiresOnDeviceRecognition = requiresOnDevice || recognizer.supportsOnDeviceRecognition
        feed.request = request
        recognitionStatus.started(.classic, locale: recognizer.locale)
        let requestID = ObjectIdentifier(request)
        recognitionTask = Self.recognize(request, with: recognizer, wakeNames: wakeNames) {
            [weak self] text, ended, error in
            Task { @MainActor [weak self] in
                self?.receiveRecognitionResult(text, ended: ended, requestID: requestID, error: error)
            }
        }
    }

    private func classicRecognizerForTurn() -> SFSpeechRecognizer? {
        let locale = preference.locale
        guard Self.recognizerAvailable(for: locale) else { return nil }
        if classicRecognizer?.locale != locale {
            classicRecognizer = (locale, SFSpeechRecognizer(locale: locale))
        }
        guard let recognizer = classicRecognizer?.recognizer,
            !requiresOnDevice || recognizer.supportsOnDeviceRecognition
        else { return nil }
        return recognizer
    }

    private func useTranscriberSession(_ session: any VoiceTranscriberSession, locale: Locale) {
        recognitionStatus.started(.modern, locale: locale)
        let requestID = ObjectIdentifier(session)
        session.onResult = { [weak self] text, ended, error in
            self?.receiveRecognitionResult(text, ended: ended, requestID: requestID, error: error, cumulative: true)
        }
        feed.request = session
        transcriberSession = session
    }

    private func waitForSpeechModel(_ preparation: Task<Bool, Never>) {
        let epoch = recognitionEpoch
        isPreparingSpeech = true
        speechPreparation = Task { [weak self] in
            let ready = await preparation.value
            guard let self, !Task.isCancelled, recognitionEpoch == epoch else { return }
            speechPreparation = nil
            isPreparingSpeech = false
            if ready || classicRecognizerForTurn() != nil {
                beginRecognitionRequest()
            } else {
                reportUnavailableSpeech()
            }
        }
    }

    private func reportUnavailableSpeech() {
        recognitionFailures = 3
        if requiresOnDevice {
            tearDownEngine()
            errorMessage = "On-device speech recognition is unavailable. Try again or check Speech Recognition access."
        } else if isEndpointing {
            onUtteranceEnd?(nil)
        }
    }

    /// Distinct, non-empty names, capped at the 100 phrases Apple recommends.
    nonisolated static func recognizerVocabulary(_ names: [String]) -> [String] {
        var seen = Set<String>()
        let names = names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count <= 60 && seen.insert($0.lowercased()).inserted }
        return Array(names.prefix(100))
    }

    func receiveRecognitionResult(
        _ text: String?, ended: Bool, requestID: ObjectIdentifier, error: (any Error)? = nil,
        cumulative: Bool = false
    ) {
        guard feed.request.map(ObjectIdentifier.init) == requestID else { return }
        if let text, cumulative || !text.isEmpty {
            // After the mic closes, results revise this request's words rather than
            // starting a segment, even when a rescored first word differs.
            if drainingRequest == requestID {
                receiveFinalText(text)
            } else {
                receiveRecognizedText(text, cumulative: cumulative || ended)
            }
        }
        guard feed.request.map(ObjectIdentifier.init) == requestID, ended else { return }
        if drainingRequest == requestID {
            finishRecognitionDrain(requestID: requestID, finalized: error == nil)
            return
        }
        if error != nil, !transcript.isEmpty {
            onUnfinishedUtterance?()
            restartRecognition()
            return
        }
        // Quiet-room errors are normal; only instant failures count.
        let lived = ProcessInfo.processInfo.systemUptime - requestStartedAt
        let failed = VoiceEndpointDetector.isRecognizerFailure(
            heardSpeech: requestHeardSpeech, failed: error != nil, lived: lived)
        committedTranscript = transcript
        feed.request = nil
        if failed {
            recognitionFailures += 1
            if recognitionFailures > 2 {
                reportUnavailableSpeech()
                return
            }
            // Speech services can be briefly unavailable after a request closes.
            let delay: Duration = recognitionFailures == 1 ? .milliseconds(250) : .milliseconds(750)
            recognitionRetry = Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard let self, !Task.isCancelled else { return }
                recognitionRetry = nil
                beginRecognitionRequest()
            }
        } else {
            recognitionFailures = 0
            beginRecognitionRequest()
        }
    }

    func setRecognitionRequestForTesting(_ request: any VoiceRecognitionRequest) {
        requestStartedAt = ProcessInfo.processInfo.systemUptime
        feed.request = request
    }

    func finishDetectedUtterance() {
        guard drainingRequest == nil, recognitionRetry == nil else { return }
        pendingEndSince = nil
        // Partials are the recognizer's running guess; the final result rescores
        // the whole utterance with its ending, so wait briefly for it.
        if let heard = utteranceTranscript, let request = feed.request {
            let requestID = ObjectIdentifier(request)
            drainingRequest = requestID
            feed.endAudio()
            let wait = Self.finalResultWait(hasPartial: !heard.isEmpty)
            drainDeadline = Task { [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled else { return }
                self?.finishRecognitionDrain(requestID: requestID, finalized: false)
            }
            return
        }
        onUtteranceEnd?(utteranceTranscript)
        if isEndpointing { restartRecognition() }
    }

    /// The normal path returns when the final arrives, not when this deadline expires.
    nonisolated static func finalResultWait(hasPartial: Bool) -> TimeInterval { hasPartial ? 1.8 : 3 }

    func finishRecognitionDrain(requestID: ObjectIdentifier, finalized: Bool = true) {
        guard drainingRequest == requestID, feed.request.map(ObjectIdentifier.init) == requestID else { return }
        let result = finalized ? utteranceTranscript : ""
        let needsRepeat = !finalized && !transcript.isEmpty
        drainDeadline?.cancel()
        drainDeadline = nil
        drainingRequest = nil
        feed.request = nil
        cancelActiveRecognition()
        let epoch = recognitionEpoch
        if needsRepeat { onUnfinishedUtterance?() }
        onUtteranceEnd?(result)
        if isEndpointing, recognitionEpoch == epoch { restartRecognition() }
    }

    /// Gives on-device recognition a fresh start after Herm fell back to Hermes' recorder.
    func resetRecognitionFailures() {
        recognitionFailures = 0
    }

    func receiveFinalText(_ text: String) {
        if !text.isEmpty { requestHeardSpeech = true }
        requestText = text
        transcript = VoiceTranscriptText.join(committedTranscript, text)
    }

    func receiveRecognizedText(_ text: String, cumulative: Bool = false) {
        guard isEndpointing || isWatchingForBarge else { return }
        if !text.isEmpty {
            requestHeardSpeech = true
            recognitionFailures = 0
        }
        // On-device recognition can restart its partial text after a pause
        // without ending the request; keep the words said before the pause.
        if !cumulative,
            VoiceEndpointDetector.startsNewSegment(
                previous: requestText, next: text, pause: ProcessInfo.processInfo.systemUptime - lastWordAt)
        {
            committedTranscript = transcript
        }
        requestText = text
        let updated = VoiceTranscriptText.join(committedTranscript, text)
        if updated != transcript {
            lastWordAt = ProcessInfo.processInfo.systemUptime
            turnVerdict = nil
        }
        transcript = updated
        if isWatchingForBarge, !acceptedBargeIn {
            // The callback can synchronously change capture mode. Let that
            // transition keep this partial before it switches to endpointing.
            acceptedBargeIn = true
            if onBargeSpeech?(transcript) != true { acceptedBargeIn = false }
        }
    }

    private func observeSleepChanges() {
        guard sleepChanges == nil else { return }
        let center = NSWorkspace.shared.notificationCenter
        sleepChanges = center.publisher(for: NSWorkspace.willSleepNotification).map { @Sendable _ in true }
            .merge(with: center.publisher(for: NSWorkspace.didWakeNotification).map { @Sendable _ in false })
            .sink { @Sendable [weak self] sleeping in
                Task { @MainActor [weak self] in self?.handleSleepChange(sleeping) }
            }
    }

    private func handleSleepChange(_ sleeping: Bool) {
        guard sleepChanges != nil, sleeping != isSuspended else { return }
        isSuspended = sleeping
        if sleeping {
            restartingRoute = false
            tearDownEngine()
            resetCaptureForRouteChange()
        } else {
            scheduleEngineRestart()
        }
    }

    private func recoverAudioRoute(generation expected: Int) {
        guard generation == expected, engine != nil, !isSuspended else { return }
        tearDownEngine()
        resetCaptureForRouteChange()
        if restartingRoute {
            errorMessage = "The audio device changed again. Check your microphone and try again."
        } else {
            restartingRoute = true
            scheduleEngineRestart()
        }
    }

    private func resetCaptureForRouteChange() {
        endpoint = VoiceEndpointDetector()
        endpoint.margin = wakeOnly ? 0.11 : 0.18
        endpoint.minSpeech = wakeOnly ? 0.18 : 0.3
        pendingEndSince = nil
        turnProgress = 0
        acceptedBargeIn = false
        recognitionFailures = 0
        restartRecognition()
    }

    private func scheduleEngineRestart() {
        let expected = generation
        errorMessage = nil
        isStarting = true
        routeRestart = Task { [weak self] in
            // Give Core Audio a moment to settle on its new default input.
            try? await Task.sleep(for: .milliseconds(200))
            guard let self, !Task.isCancelled, generation == expected else { return }
            routeRestart = nil
            startEngine()
        }
    }

    /// Enabling voice processing blocks for about a second, so the engine starts
    /// off the main thread; the notch opens while it does.
    private func startEngine() {
        let expected = generation
        let feed = feed
        feed.acceptAudio(from: expected)
        let turnAudio = turnAudio
        let (levels, input) = AsyncStream<VoiceLevelSample>.makeStream(bufferingPolicy: .bufferingNewest(1))
        levelUpdates = Task { [weak self] in
            for await sample in levels {
                guard let self, self.generation == expected else { return }
                guard engine != nil else { continue }
                restartingRoute = false
                guard errorMessage == nil, !isPreparingSpeech else { continue }
                if !isRunning {
                    guard !requiresOnDevice || sample.fedRecognizer else { continue }
                    isStarting = false
                    isRunning = true
                }
                self.ingestAudioLevel(sample.level, at: sample.time)
            }
        }
        Task.detached(priority: .userInitiated) { [weak self] in
            let launch = Self.launchEngine(feed: feed, turnAudio: turnAudio, generation: expected) { sample in
                input.yield(sample)
            }
            switch launch {
            case .started: break
            case .noInput, .failed: input.finish()
            }
            await self?.engineLaunched(launch, generation: expected)
        }
    }

    private func engineLaunched(_ launch: EngineLaunch, generation expected: Int) {
        switch launch {
        case .started(let box):
            guard generation == expected, engine == nil else {
                box.engine.stop()
                box.engine.inputNode.removeTap(onBus: 0)
                return
            }
            if !box.engine.inputNode.isVoiceProcessingEnabled {
                DebugLog.write("voice: listening without echo cancellation")
            }
            engine = box.engine
            routeChanges = NotificationCenter.default.publisher(
                for: .AVAudioEngineConfigurationChange, object: box.engine
            ).sink { @Sendable [weak self] _ in
                // Core Audio notifies from an internal queue. Rebuild away from it.
                Task { @MainActor [weak self] in self?.recoverAudioRoute(generation: expected) }
            }
            guard box.engine.isRunning else { return recoverAudioRoute(generation: expected) }
            beginRecognitionRequest()
        case .noInput:
            guard generation == expected else { return }
            isStarting = false
            errorMessage = "No microphone input is available. Connect a microphone and retry."
        case .failed(let message):
            guard generation == expected else { return }
            isStarting = false
            errorMessage = "Couldn’t start the microphone: " + HermesDiagnosticsService.safeSummary(message)
        }
    }

    enum EngineLaunch: Sendable {
        final class Box: @unchecked Sendable {
            let engine: AVAudioEngine
            init(_ engine: AVAudioEngine) { self.engine = engine }
        }
        case started(Box)
        case noInput
        case failed(String)
    }

    private nonisolated static func launchEngine(
        feed: RecognitionFeed, turnAudio: TurnAudio, generation: Int,
        onLevel: @escaping @Sendable (VoiceLevelSample) -> Void,
        cancellingEcho: Bool = true
    ) -> EngineLaunch {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if cancellingEcho { cancelEcho(on: engine) }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return .noInput }
        installTap(on: input, feed: feed, turnAudio: turnAudio, generation: generation, onLevel: onLevel)
        do {
            try engine.start()
            return .started(EngineLaunch.Box(engine))
        } catch {
            input.removeTap(onBus: 0)
            // Some input devices refuse voice processing: listen without it rather than not at all.
            guard input.isVoiceProcessingEnabled else { return .failed(error.localizedDescription) }
            return launchEngine(
                feed: feed, turnAudio: turnAudio, generation: generation, onLevel: onLevel, cancellingEcho: false)
        }
    }

    func ingestAudioLevel(_ value: CGFloat, at now: TimeInterval, outputPlaying: Bool? = nil) {
        if !wakeOnly {
            let smoothing: CGFloat = value > smoothedLevel ? 0.5 : 0.12
            smoothedLevel += (value - smoothedLevel) * smoothing
            let nextLevel = (smoothedLevel * 100).rounded() / 100
            if level != nextLevel { level = nextLevel }
        }
        guard isEndpointing, drainingRequest == nil else { return }
        if endpoint.ingest(level: Double(value), at: now) { pendingEndSince = pendingEndSince ?? now }
        if endpoint.isHearingSpeech {
            lastLoudAt = now
            pendingEndSince = nil
            turnVerdict = nil
        }
        let utterance = utteranceTranscript
        if !wakeOnly {
            if !heardPlayback {
                if let outputPlaying {
                    heardPlayback = outputPlaying
                } else if endpoint.isHearingSpeech || utterance?.isEmpty == false, now >= nextOutputCheck {
                    nextOutputCheck = now + 0.1
                    heardPlayback = outputIsRunning() == true
                }
            }
            askTurnModel(at: now)
            let progress =
                endpoint.isHearingSpeech || (utterance ?? "").isEmpty
                ? 0
                : min(
                    1,
                    max(0, now - max(lastWordAt, lastLoudAt))
                        / VoiceEndpointDetector.turnHold(
                            utterance ?? "", quietSince: pendingEndSince, finished: turnVerdict, wakeOnly: wakeOnly))
            if abs(progress - turnProgress) > 0.03 || (progress == 0) != (turnProgress == 0) {
                turnProgress = progress
            }
        }
        if VoiceEndpointDetector.shouldEndTurn(
            utterance, lastWordAt: lastWordAt, quietSince: pendingEndSince, now: now,
            finished: turnVerdict, isHearingSpeech: endpoint.isHearingSpeech, lastLoudAt: lastLoudAt,
            wakeOnly: wakeOnly
        ) {
            finishDetectedUtterance()
        } else if !wakeOnly, pendingEndSince == nil, transcript.isEmpty, now >= nextQuietCheck {
            nextQuietCheck = now + 0.25
            if endpoint.heardNothing(for: idleLimit, at: now) {
                onIdle?()
            } else if endpoint.heardNothing(for: 1.5, at: now) {
                onQuiet?()
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
        guard !transcript.isEmpty, !endpoint.isHearingSpeech, now - pause >= 0.25, checkedPause != pause,
            turnAudio.isEnabled, let predictor = TurnModelStore.shared.predictor
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
        with recognizer: SFSpeechRecognizer, wakeNames: [String],
        onResult: @escaping @Sendable (String?, Bool, (any Error)?) -> Void
    ) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, error in
            let text = result.map { result in
                let best = result.bestTranscription.formattedString
                guard !wakeNames.isEmpty, VoicePrompts.afterWakePhrase(best, names: wakeNames) == nil else {
                    return best
                }
                return VoiceTranscriptText.wakeAlternative(
                    result.transcriptions.prefix(4).map(\.formattedString), matching: best, names: wakeNames) ?? best
            }
            onResult(text, error != nil || result?.isFinal == true, error)
        }
    }

    private nonisolated static func installTap(
        on input: AVAudioInputNode, feed: RecognitionFeed, turnAudio: TurnAudio, generation: Int,
        onLevel: @escaping @Sendable (VoiceLevelSample) -> Void
    ) {
        // Voice processing hands the tap extra channels (3 on most Macs); only
        // channel 0 is the cleaned voice, the rest would mix the echo back in.
        let normalizer = MicBufferNormalizer(firstChannelOnly: input.isVoiceProcessingEnabled)
        nonisolated(unsafe) var sampler = VoiceLevelSampler()
        input.installTap(onBus: 0, bufferSize: 1_024, format: nil) { buffer, _ in
            guard let buffer = normalizer.normalize(buffer) else { return }
            let fedRecognizer = feed.append(buffer, generation: generation)
            if fedRecognizer { turnAudio.append(buffer) }
            if let sample = sampler.sample(
                SpeechInput.normalizedAudioLevel(buffer), at: ProcessInfo.processInfo.systemUptime,
                fedRecognizer: fedRecognizer)
            {
                onLevel(sample)
            }
        }
    }
}

struct VoiceLevelSample: Sendable {
    let level: CGFloat
    let time: TimeInterval
    let fedRecognizer: Bool
}

/// The tap still feeds every speech frame. Only meter and endpoint updates are sampled.
struct VoiceLevelSampler {
    private let interval: TimeInterval = 1.0 / 30
    private var nextDelivery: TimeInterval?
    private var peak: CGFloat = 0

    mutating func sample(_ level: CGFloat, at time: TimeInterval, fedRecognizer: Bool = false) -> VoiceLevelSample? {
        peak = max(peak, level)
        let deadline = nextDelivery ?? time
        guard time >= deadline else { return nil }
        let sample = VoiceLevelSample(level: peak, time: time, fedRecognizer: fedRecognizer)
        let next = deadline + interval
        nextDelivery = next > time ? next : time + interval
        peak = 0
        return sample
    }
}

/// Turns whatever a microphone delivers (interleaved, Int16/Int32, many
/// channels) into deinterleaved Float32 that the level meter and recognizer
/// read. Used only from one tap's audio thread, which calls it serially.
final class MicBufferNormalizer: @unchecked Sendable {
    private let firstChannelOnly: Bool
    private var converter: AVAudioConverter?
    private var loggedFormat: AVAudioFormat?
    private var loggedDrop = false

    init(firstChannelOnly: Bool) {
        self.firstChannelOnly = firstChannelOnly
    }

    func normalize(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let format = buffer.format
        let isFloat = format.commonFormat == .pcmFormatFloat32 && !format.isInterleaved
        if loggedFormat != format {
            loggedFormat = format
            Self.log(
                "voice: mic format channels=\(format.channelCount) interleaved=\(format.isInterleaved) "
                    + "common=\(format.commonFormat.rawValue) rate=\(Int(format.sampleRate))"
                    + (isFloat ? "" : "; converting to mono Float32"))
        }
        if isFloat, format.channelCount == 1 || !firstChannelOnly { return buffer }
        if isFloat { return Self.copyFirstChannel(of: buffer) }
        guard let converted = convertFirstChannel(of: buffer) else {
            if !loggedDrop {
                loggedDrop = true
                Self.log("voice: dropping mic buffers the converter cannot read")
            }
            return nil
        }
        return converted
    }

    private static func copyFirstChannel(of buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let source = buffer.floatChannelData, let mono = monoFormat(sampleRate: buffer.format.sampleRate),
            let out = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: buffer.frameLength),
            let target = out.floatChannelData
        else { return nil }
        out.frameLength = buffer.frameLength
        target[0].update(from: source[0], count: Int(buffer.frameLength))
        return out
    }

    private func convertFirstChannel(of buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let mono = Self.monoFormat(sampleRate: buffer.format.sampleRate) else { return nil }
        if converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: mono)
            converter?.channelMap = [0]
        }
        guard let converter, let out = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: buffer.frameLength),
            (try? converter.convert(to: out, from: buffer)) != nil
        else { return nil }
        return out
    }

    /// The tap runs on the audio thread; the log writer is main-actor isolated.
    private static func log(_ line: String) {
        Task { @MainActor in DebugLog.write(line) }
    }

    private static func monoFormat(sampleRate: Double) -> AVAudioFormat? {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)
    }
}

/// The recognition request the audio thread feeds, swapped from the main actor.
/// One utterance's recognizer input: Apple's classic request or, on macOS 26,
/// a `SpeechAnalyzer` session. Called only under `RecognitionFeed`'s lock.
protocol VoiceRecognitionRequest: AnyObject {
    func append(_ buffer: AVAudioPCMBuffer)
    func endAudio()
}

extension SFSpeechAudioBufferRecognitionRequest: VoiceRecognitionRequest {}

final class RecognitionFeed: @unchecked Sendable {
    private let lock = NSLock()
    private let endRequest: (any VoiceRecognitionRequest) -> Void
    private var current: (any VoiceRecognitionRequest)?
    private var ended = false
    private var generation = 0

    init(endRequest: @escaping (any VoiceRecognitionRequest) -> Void = { $0.endAudio() }) {
        self.endRequest = endRequest
    }

    var request: (any VoiceRecognitionRequest)? {
        get { lock.withLock { current } }
        set {
            lock.withLock {
                current = newValue
                ended = false
            }
        }
    }

    func acceptAudio(from generation: Int) {
        lock.withLock { self.generation = generation }
    }

    @discardableResult func append(_ buffer: AVAudioPCMBuffer, generation: Int = 0) -> Bool {
        lock.withLock {
            guard generation == self.generation, !ended, let current else { return false }
            current.append(buffer)
            return true
        }
    }

    func endAudio() {
        lock.withLock {
            guard !ended, let current else { return }
            ended = true
            endRequest(current)
        }
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
    /// A model verdict can shorten a settled pause, but doesn't override renewed
    /// speech or a trailing word that still sounds like part of a sentence.
    static func shouldEndTurn(
        _ transcript: String?, lastWordAt: TimeInterval, quietSince: TimeInterval?, now: TimeInterval,
        finished: Bool? = nil, isHearingSpeech: Bool = false, lastLoudAt: TimeInterval? = nil, wakeOnly: Bool = false
    ) -> Bool {
        // New words extend a turn; steady background noise cannot hold it forever.
        if isHearingSpeech {
            guard let transcript, !transcript.isEmpty else { return false }
            return now - lastWordAt >= 4
        }
        guard let transcript else { return quietSince != nil }
        if transcript.isEmpty { return quietSince.map { now - $0 >= 3 } ?? false }
        let pauseStart = max(lastWordAt, lastLoudAt ?? lastWordAt)
        return now - pauseStart >= turnHold(transcript, quietSince: quietSince, finished: finished, wakeOnly: wakeOnly)
    }

    /// A smart-turn verdict is a hint, not permission to cut someone off at their first pause.
    static func turnHold(
        _ transcript: String, quietSince: TimeInterval?, finished: Bool?, wakeOnly: Bool
    ) -> TimeInterval {
        let hold: TimeInterval
        if finished == false || trailsOff(transcript) {
            hold = 3
        } else if wakeOnly {
            hold = 1.25
        } else {
            hold = finished == true ? 1.8 : 2
        }
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
