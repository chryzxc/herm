import AVFoundation
import CoreML
import CryptoKit
import SwiftUI

/// Smart Turn v3.2 (pipecat-ai, BSD-2-Clause) as a Core ML build: from the
/// last 8s of speech it tells whether the speaker finished their thought or
/// is pausing mid-sentence, using intonation rather than silence alone.
/// Downloaded on launch unless the user opts out, and verified against pinned hashes.
@MainActor
final class TurnModelStore: ObservableObject {
    static let shared = TurnModelStore()

    enum Phase: Equatable {
        case notInstalled
        case downloading(Double)
        case installed
        case failed(String)
    }

    @Published private(set) var phase: Phase = .notInstalled
    private(set) var predictor: TurnPredictor?
    private let defaults: UserDefaults
    private let directory: URL
    private var download: Task<Void, Never>?
    private var transfer: URLSessionDownloadTask?

    private static let repository =
        "https://huggingface.co/aufklarer/Smart-Turn-v3.2-CoreML/resolve/75f069717f500947195fa1945c46ddb472559cff/smart_turn.mlmodelc/"
    private static let files: [(path: String, size: Int, sha256: String)] = [
        ("analytics/coremldata.bin", 243, "1646746d0029e78d26be065e62602d4f89e51013ec238b653adf7d7d21057f89"),
        ("coremldata.bin", 643, "9245ac99889c9d738cba6c89da9e851fd16488bf8effbc15a109d06b401c9383"),
        ("model.mil", 69_968, "41a6d9ac0f7d01d738e56ecdf4435e55f139591541b7cf1a4dba6b9ce2f1c9ef"),
        ("weights/weight.bin", 16_714_240, "b6295316741a0149e1fcab7cdf030e1b9bfb0eef778207accee91a2a9703a39c"),
    ]
    static let downloadSize = files.reduce(0) { $0 + $1.size }

    static func downloadProgress(completedBytes: Int, fileBytes: Int, fraction: Double) -> Double {
        (Double(completedBytes) + min(max(fraction, 0), 1) * Double(fileBytes)) / Double(downloadSize)
    }

    private static let automaticInstallOptOutKey = "herm.voice.turnModel.autoInstallOptOut"

    private static var modelDirectory: URL {
        (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
                "Library/Application Support", isDirectory: true))
            .appendingPathComponent("Herm/Models/smart_turn.mlmodelc", isDirectory: true)
    }

    init(defaults: UserDefaults = .standard, directory: URL? = nil) {
        self.defaults = defaults
        self.directory = directory ?? Self.modelDirectory
        if FileManager.default.fileExists(atPath: self.directory.path) { load() }
    }

    static func prepareOnLaunch() {
        // Leave loading an existing Core ML model to the first voice or Settings access.
        guard !FileManager.default.fileExists(atPath: modelDirectory.path), shared.shouldInstallAutomatically else {
            return
        }
        shared.install()
    }

    var shouldInstallAutomatically: Bool {
        phase == .notInstalled && !defaults.bool(forKey: Self.automaticInstallOptOutKey)
    }

    func install() {
        guard download == nil, phase != .installed else { return }
        defaults.removeObject(forKey: Self.automaticInstallOptOutKey)
        phase = .downloading(0)
        download = Task { [self] in
            let staging = FileManager.default.temporaryDirectory.appendingPathComponent(
                "herm-smart-turn-\(UUID().uuidString)", isDirectory: true)
            defer {
                download = nil
                transfer = nil
                try? FileManager.default.removeItem(at: staging)
            }
            do {
                var done = 0
                for file in Self.files {
                    try Task.checkCancellation()
                    let base = done
                    let fetched = try await fetch(Self.repository + file.path) { [weak self] fraction in
                        guard let self, self.download?.isCancelled == false,
                            case .downloading(let previous) = self.phase
                        else { return }
                        let progress = Self.downloadProgress(
                            completedBytes: base, fileBytes: file.size, fraction: fraction)
                        self.phase = .downloading(max(previous, progress))
                    }
                    defer { try? FileManager.default.removeItem(at: fetched) }
                    try Task.checkCancellation()
                    let digest = SHA256.hash(data: try Data(contentsOf: fetched)).map { String(format: "%02x", $0) }
                        .joined()
                    guard digest == file.sha256 else { throw TurnModelError.corrupt }
                    let target = staging.appendingPathComponent(file.path)
                    try FileManager.default.createDirectory(
                        at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try FileManager.default.moveItem(at: fetched, to: target)
                    done += file.size
                }
                try FileManager.default.createDirectory(
                    at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: directory)
                try FileManager.default.moveItem(at: staging, to: directory)
                load()
            } catch {
                phase =
                    error is CancellationError || (error as? URLError)?.code == .cancelled
                    ? .notInstalled
                    : .failed(
                        error is TurnModelError
                            ? "The download didn't match the expected model."
                            : HermesDiagnosticsService.safeSummary(error.localizedDescription))
            }
        }
    }

    func cancel() {
        defaults.set(true, forKey: Self.automaticInstallOptOutKey)
        download?.cancel()
        transfer?.cancel()
    }

    func remove() {
        cancel()
        predictor = nil
        try? FileManager.default.removeItem(at: directory)
        phase = .notInstalled
    }

    private func load() {
        do {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .all
            predictor = TurnPredictor(model: try MLModel(contentsOf: directory, configuration: configuration))
            phase = .installed
        } catch {
            predictor = nil
            phase = .failed("The model couldn't be loaded. Remove it and download again.")
        }
    }

    /// Downloads one file to a temporary location, reporting 0...1 progress.
    private func fetch(_ address: String, progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        guard let url = URL(string: address) else { throw URLError(.badURL) }
        return try await withCheckedThrowingContinuation { continuation in
            let kept = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            nonisolated(unsafe) var observation: NSKeyValueObservation?
            let task = URLSession.shared.downloadTask(with: url) { location, response, error in
                observation?.invalidate()
                if let error { return continuation.resume(throwing: error) }
                guard let location, (response as? HTTPURLResponse)?.statusCode == 200 else {
                    return continuation.resume(throwing: URLError(.badServerResponse))
                }
                // The system deletes `location` once this handler returns.
                do {
                    try FileManager.default.moveItem(at: location, to: kept)
                    continuation.resume(returning: kept)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            observation = task.progress.observe(\.fractionCompleted) { value, _ in
                let fraction = value.fractionCompleted
                Task { @MainActor in progress(fraction) }
            }
            transfer = task
            task.resume()
        }
    }
}

private enum TurnModelError: Error { case corrupt }

/// Runs the turn model off the main thread; one prediction takes a few ms.
final class TurnPredictor: @unchecked Sendable {
    static let windowSamples = 8 * 16_000
    private let model: MLModel
    private let queue = DispatchQueue(label: "herm.turn-model", qos: .userInitiated)

    init(model: MLModel) { self.model = model }

    /// Whether the speaker finished their turn, from 16 kHz mono audio.
    /// Errors read as "still talking", leaving the silence fallback in charge.
    func isComplete(_ audio: [Float], completion: @escaping @Sendable (Bool) -> Void) {
        queue.async { [self] in completion(((try? probability(audio)) ?? 0) > 0.5) }
    }

    private func probability(_ audio: [Float]) throws -> Float {
        // Most recent audio last, zeros at the front.
        let input = try MLMultiArray(shape: [1, NSNumber(value: Self.windowSamples)], dataType: .float32)
        let tail = audio.suffix(Self.windowSamples)
        let offset = Self.windowSamples - tail.count
        input.withUnsafeMutableBufferPointer(ofType: Float.self) { buffer, _ in
            buffer.update(repeating: 0)
            for (index, sample) in tail.enumerated() { buffer[offset + index] = sample }
        }
        let output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["audio": input]))
        return output.featureValue(for: "probability")?.multiArrayValue?[0].floatValue ?? 0
    }
}

/// The current turn's audio at 16 kHz mono, fed from the mic tap.
final class TurnAudio: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var converter: AVAudioConverter?
    private var conversionBuffer: AVAudioPCMBuffer?
    private var enabled = false
    private let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    var isEnabled: Bool {
        get { lock.withLock { enabled } }
        set {
            lock.withLock {
                guard enabled != newValue else { return }
                enabled = newValue
                if !enabled {
                    samples.removeAll()
                    converter = nil
                    conversionBuffer = nil
                }
            }
        }
    }

    /// Called on the audio thread. Wake-only listening never resamples for Smart Turn.
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            guard enabled else { return }
            if converter?.inputFormat != buffer.format { converter = AVAudioConverter(from: buffer.format, to: format) }
            let capacity =
                AVAudioFrameCount(
                    Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate) + 32
            if (conversionBuffer?.frameCapacity ?? 0) < capacity {
                conversionBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity)
            }
            guard let converter, let output = conversionBuffer else { return }
            nonisolated(unsafe) var supplied = false
            nonisolated(unsafe) let source = buffer
            var error: NSError?
            converter.convert(to: output, error: &error) { _, status in
                if supplied {
                    status.pointee = .noDataNow
                    return nil
                }
                supplied = true
                status.pointee = .haveData
                return source
            }
            guard error == nil, let channel = output.floatChannelData?[0] else { return }
            samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
            if samples.count > 2 * TurnPredictor.windowSamples {
                samples.removeFirst(samples.count - TurnPredictor.windowSamples)
            }
        }
    }

    func snapshot() -> [Float] { lock.withLock { Array(samples.suffix(TurnPredictor.windowSamples)) } }
    func reset() { lock.withLock { samples.removeAll(keepingCapacity: true) } }
}

struct TurnModelSettingsView: View {
    @ObservedObject var store: TurnModelStore
    var compact = false

    var body: some View {
        if compact {
            VoiceQuickRow(title: "Smart turn detection", detail: detail) { action }
        } else {
            SettingsPreferenceRow(title: "Smart turn detection", detail: detail) { action }
        }
    }

    @ViewBuilder private var action: some View {
        switch store.phase {
        case .notInstalled, .failed:
            Button(store.phase == .notInstalled ? "Download" : "Retry") { store.install() }
                .buttonStyle(.dockPrimary)
                .accessibilityLabel(
                    store.phase == .notInstalled ? "Download Smart turn detection" : "Retry Smart turn detection")
        case .downloading(let fraction):
            HStack(spacing: 8) {
                if !compact {
                    ProgressView(value: fraction)
                        .frame(width: 120)
                        .accessibilityLabel("Turn model download")
                    Text("\(Int(fraction * 100))%")
                        .dockFont(.metadata).monospacedDigit()
                        .foregroundStyle(Color.dockMetadataText)
                        .lineLimit(1)
                        .fixedSize()
                        .frame(minWidth: 40, alignment: .trailing)
                }
                Button("Cancel") { store.cancel() }
                    .buttonStyle(.dockSecondary)
            }
            .fixedSize(horizontal: true, vertical: false)
        case .installed:
            if !compact {
                Button("Remove") { store.remove() }
                    .buttonStyle(.dockCompact)
                    .dockFont(.body, weight: .medium)
                    .foregroundStyle(Color.dockAccent)
            }
        }
    }

    private var detail: String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(TurnModelStore.downloadSize), countStyle: .file)
        switch store.phase {
        case .notInstalled:
            return compact
                ? "Waits through pauses · \(size)"
                : "Waits while you pause mid-sentence and replies as soon as you finish, from how you sound. Runs on this Mac (\(size))."
        case .downloading(let fraction):
            return compact ? "Downloading… \(Int(fraction * 100))%" : "Downloading the turn model (\(size))…"
        case .installed:
            return compact
                ? "Installed on this Mac."
                : "Installed. Voice mode replies as soon as you finish a thought and waits through pauses."
        case .failed(let reason):
            return reason
        }
    }
}
