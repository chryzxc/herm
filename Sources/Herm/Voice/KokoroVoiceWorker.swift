import Darwin
import Foundation

/// One local model process serves the current call and the bounded audio prefetch.
@MainActor
final class KokoroVoiceWorker {
    static let shared = KokoroVoiceWorker()

    private struct Request {
        let id: UUID
        let data: Data
        var result: CheckedContinuation<Data, Error>?
    }

    private struct LaunchConfiguration {
        let executable: URL
        let arguments: [String]
        let environment: [String: String]
    }

    private let maxFrame = 2 * 1_024 * 1_024
    private let cancelledFrameGrace: Duration = .milliseconds(350)
    private var configuration: LaunchConfiguration?
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var token = UUID()
    private var frame = Data()
    private var current: Request?
    private var queue: [Request] = []
    private var deadline: Task<Void, Never>?
    private var idle: Task<Void, Never>?

    func prepare(executable: URL, arguments: [String], environment: [String: String]) throws {
        if process != nil { return }
        try launch(LaunchConfiguration(executable: executable, arguments: arguments, environment: environment))
    }

    private func launch(_ configuration: LaunchConfiguration) throws {
        let process = Process()
        let incoming = Pipe()
        let outgoing = Pipe()
        let endpoint = outgoing.fileHandleForReading
        let writer = incoming.fileHandleForWriting
        guard fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            throw KokoroVoice.Failure.unavailable
        }
        let token = UUID()
        process.executableURL = configuration.executable
        process.arguments = configuration.arguments
        process.environment = configuration.environment
        process.standardInput = incoming
        process.standardOutput = outgoing
        process.standardError = FileHandle.nullDevice
        try process.run()
        self.configuration = configuration
        self.process = process
        self.input = writer
        self.output = endpoint
        self.token = token
        endpoint.readabilityHandler = { [weak self] handle in
            let bytes = handle.availableData
            DispatchQueue.main.async { [weak self] in self?.receive(bytes, token: token) }
        }
        scheduleIdle()
    }

    func speak(_ data: Data) async throws -> Data {
        try Task.checkCancellation()
        guard process != nil, queue.count < 8 else { throw KokoroVoice.Failure.unavailable }
        let id = UUID()
        let audio = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                queue.append(Request(id: id, data: data, result: continuation))
                sendNext()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(id) }
        }
        try Task.checkCancellation()
        return audio
    }

    private func sendNext() {
        guard current == nil else { return }
        guard !queue.isEmpty, let input else {
            scheduleIdle()
            return
        }
        idle?.cancel()
        let request = queue.removeFirst()
        current = request
        scheduleDeadline(for: request.id, after: .seconds(12))
        do {
            var line = request.data
            line.append(0x0A)
            try input.write(contentsOf: line)
        } catch {
            close()
        }
    }

    private func receive(_ bytes: Data, token: UUID) {
        guard token == self.token else { return }
        guard !bytes.isEmpty, let request = current, frame.count + bytes.count <= maxFrame + 4 else {
            frameFailed()
            return
        }
        frame.append(bytes)
        guard frame.count >= 4 else { return }
        let size = Int(UInt32(littleEndian: frame.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }))
        guard size <= maxFrame, frame.count <= size + 4 else {
            frameFailed()
            return
        }
        guard frame.count == size + 4 else { return }

        deadline?.cancel()
        current = nil
        let audio = Data(frame.dropFirst(4))
        frame.removeAll(keepingCapacity: true)
        if audio.starts(with: "RIFF".utf8) {
            request.result?.resume(returning: audio)
        } else {
            request.result?.resume(throwing: KokoroVoice.Failure.unavailable)
        }
        sendNext()
    }

    private func cancel(_ id: UUID) {
        if current?.id == id, let result = current?.result {
            // Drain a finishing frame without delivering it to the next request.
            current?.result = nil
            scheduleDeadline(for: id, after: cancelledFrameGrace)
            result.resume(throwing: CancellationError())
        } else if let index = queue.firstIndex(where: { $0.id == id }) {
            queue.remove(at: index).result?.resume(throwing: CancellationError())
        }
    }

    private func scheduleDeadline(for id: UUID, after delay: Duration) {
        deadline?.cancel()
        deadline = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled, current?.id == id else { return }
            frameFailed()
        }
    }

    private func frameFailed() {
        guard let current, current.result == nil, !queue.isEmpty, let configuration else {
            close()
            return
        }
        // The queued requests were never written to the old process.
        stopProcess()
        self.current = nil
        do {
            try launch(configuration)
            sendNext()
        } catch {
            close()
        }
    }

    private func scheduleIdle() {
        idle?.cancel()
        idle = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { return }
            self?.close()
        }
    }

    private func stopProcess() {
        token = UUID()
        deadline?.cancel()
        idle?.cancel()
        output?.readabilityHandler = nil
        try? input?.close()
        try? output?.close()
        if process?.isRunning == true { process?.terminate() }
        input = nil
        output = nil
        process = nil
        configuration = nil
        frame.removeAll()
    }

    func close() {
        stopProcess()
        let abandoned = queue
        queue.removeAll()
        let request = current
        current = nil
        request?.result?.resume(throwing: KokoroVoice.Failure.unavailable)
        for waiting in abandoned { waiting.result?.resume(throwing: KokoroVoice.Failure.unavailable) }
    }
}
