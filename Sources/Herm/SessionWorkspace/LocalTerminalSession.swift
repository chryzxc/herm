import Darwin
@preconcurrency import Dispatch
import Foundation
import os

@MainActor
final class LocalTerminalSession: ObservableObject, Identifiable {
    let id = UUID()
    enum State: Equatable {
        case idle
        case starting
        case ready
        case running
        case interrupting
        case exited
        case closed
        case failed(String)
    }

    nonisolated static let maxOutputBytes = 256_000
    nonisolated static let maxOutputLines = 2_000
    nonisolated static let outputDeliveryBytes = 8_192

    /// Bounded terminal output that trims only at UTF-8-safe line boundaries.
    struct OutputBuffer: Equatable {
        let maxBytes: Int
        let maxLines: Int
        private var bytes = Data()
        private var head = 0
        private var newlineCount = 0
        var text: String { String(decoding: bytes[head...], as: UTF8.self) }

        init(maxBytes: Int = LocalTerminalSession.maxOutputBytes, maxLines: Int = LocalTerminalSession.maxOutputLines) {
            self.maxBytes = max(1, maxBytes)
            self.maxLines = max(1, maxLines)
        }

        mutating func append(_ addition: String) {
            bytes.append(contentsOf: addition.utf8)
            newlineCount += addition.utf8.count { $0 == 10 }
            trim()
        }

        mutating func removeAll() {
            bytes.removeAll(keepingCapacity: true)
            head = bytes.startIndex
            newlineCount = 0
        }

        private mutating func trim() {
            let partialLine = head == bytes.endIndex || bytes.last == 10 ? 0 : 1
            while bytes.endIndex - head > maxBytes || newlineCount + partialLine > maxLines {
                if let newline = bytes[head...].firstIndex(of: 10) {
                    head = bytes.index(after: newline)
                    newlineCount -= 1
                } else {
                    // A single oversized line keeps its newest valid UTF-8 suffix.
                    head = bytes.index(bytes.endIndex, offsetBy: -maxBytes)
                    while head < bytes.endIndex, bytes[head] & 0xC0 == 0x80 {
                        head = bytes.index(after: head)
                    }
                    break
                }
            }
            // Amortize copying the retained bytes when the buffer is already full.
            if head - bytes.startIndex >= maxBytes {
                bytes.removeSubrange(bytes.startIndex..<head)
                head = bytes.startIndex
            }
        }
    }

    // SwiftTerm renders bytes directly; output retention must not rebuild the
    // enclosing SwiftUI workspace for every PTY chunk.
    var output: String { outputBuffer.text }
    @Published private(set) var state: State = .idle
    @Published private(set) var workingDirectory: String?
    @Published private(set) var commandHistory: [String] = []
    @Published private(set) var lastVerificationRun: VerificationRun?
    lazy var emulator = SessionTerminalEmulator(session: self)

    var shellProcessID: pid_t { processID }
    var hasForegroundJob: Bool {
        guard masterFD >= 0, processID > 0 else { return false }
        let foreground = tcgetpgrp(masterFD)
        return foreground > 0 && foreground != processID
    }

    private var masterFD: Int32 = -1
    private var processID: pid_t = 0
    private var reader: DispatchSourceRead?
    private var writer: DispatchSourceWrite?
    private var pendingInput = Data()
    private var inputOffset = 0
    private var outputBuffer = OutputBuffer()
    private var lifecycleID = UUID()
    private var verificationMarker: String?
    private var verificationRun: VerificationRun?
    private var verificationTail = ""

    /// SSH mode opens the shell on the backend host, like Hermes Desktop; the
    /// directory is a remote path and `cd` falls back to the remote home.
    nonisolated static func shellArguments(directory: String, backend: GatewayConnectionSettings) -> [String] {
        guard backend.mode == .ssh else { return ["/bin/zsh", "-il"] }
        let quoted = "'" + directory.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return ["/usr/bin/ssh", "-tt"] + backend.sshOptions + ["cd \(quoted) 2>/dev/null; exec \"$SHELL\" -l"]
    }

    func start(directory: String) {
        close()
        let backend = GatewayConnectionStore.backendSettings
        let url = URL(fileURLWithPath: directory).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard
            backend.mode == .ssh
                || FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
        else {
            state = .failed("Project directory is unavailable.")
            return
        }
        state = .starting
        outputBuffer.removeAll()
        commandHistory = []
        lastVerificationRun = nil
        verificationMarker = nil
        verificationRun = nil
        verificationTail = ""
        workingDirectory = url.path
        emulator.reset()
        var size = winsize(ws_row: 24, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
        var fd: Int32 = -1
        // Only async-signal-safe calls may run between fork and exec in a
        // multithreaded process (malloc/setenv can deadlock the child), so
        // every C string is allocated before forking.
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        // The ssh client itself runs from the Mac home; the remote shell does its own cd.
        let directoryPath = strdup(backend.mode == .ssh ? NSHomeDirectory() : url.path)
        let arguments: [UnsafeMutablePointer<CChar>?] =
            Self.shellArguments(directory: url.path, backend: backend).map { strdup($0) } + [nil]
        let environmentPointers: [UnsafeMutablePointer<CChar>?] =
            environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            free(directoryPath)
            for pointer in arguments + environmentPointers { free(pointer) }
        }
        let child = forkpty(&fd, nil, nil, &size)
        guard child >= 0 else {
            state = .failed(String(cString: strerror(errno)))
            return
        }
        if child == 0 {
            _ = chdir(directoryPath)
            _ = execve(arguments[0], arguments, environmentPointers)
            _exit(127)
        }
        masterFD = fd
        processID = child
        let lifecycleID = self.lifecycleID
        // Cancellation closes only this source's duplicate, even if a new shell already owns masterFD.
        let readFD = fcntl(fd, F_DUPFD_CLOEXEC, 0)
        guard readFD >= 0 else {
            let error = String(cString: strerror(errno))
            close()
            state = .failed(error)
            return
        }
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            let error = String(cString: strerror(errno))
            Darwin.close(readFD)
            close()
            state = .failed(error)
            return
        }
        let outputQueue = DispatchQueue(label: "Herm.terminal.output")
        let source = DispatchSource.makeReadSource(fileDescriptor: readFD, queue: outputQueue)
        let decoder = OutputDecoder()
        reader = source
        source.setCancelHandler { @Sendable in Darwin.close(readFD) }
        source.setEventHandler { @Sendable [weak self] in
            guard let data = Self.readOutput(readFD) else { return }
            let text = Self.cleanTerminalText(decoder.decode(data))
            let bytes = Array(data)
            // Keep just one delivery outstanding and give AppKit a turn between batches.
            source.suspend()
            TerminalOutputDelivery.shared.enqueue { [weak self] in
                defer { outputQueue.async { source.resume() } }
                guard let self, self.lifecycleID == lifecycleID, self.masterFD >= 0 else { return }
                if bytes.isEmpty {
                    if !text.isEmpty { self.consume(text) }
                    self.reader?.cancel()
                    self.reader = nil
                    Darwin.close(self.masterFD)
                    self.clearPendingInput()
                    self.finishVerificationFailure("Terminal exited before reporting a result.")
                    self.masterFD = -1
                    self.processID = 0
                    self.state = .exited
                } else {
                    self.emulator.view.receiveOutput(bytes[...])
                    self.consume(text)
                    if self.state == .starting { self.state = .ready }
                }
            }
        }
        source.resume()
        state = .ready
        resize(columns: emulator.view.getTerminal().cols, rows: emulator.view.getTerminal().rows)
    }

    func resize(columns: Int, rows: Int) {
        guard masterFD >= 0 else { return }
        var size = winsize(
            ws_row: UInt16(clamping: max(1, rows)), ws_col: UInt16(clamping: max(1, columns)), ws_xpixel: 0,
            ws_ypixel: 0)
        _ = ioctl(masterFD, TIOCSWINSZ, &size)
    }

    func sendInput(_ bytes: ArraySlice<UInt8>) {
        guard masterFD >= 0 else { return }
        if bytes.elementsEqual([3]) {
            interrupt()
            return
        }
        guard verificationRun == nil else { return }
        if bytes.contains(13) || bytes.contains(10) { state = .running }
        enqueueInput(Data(bytes))
    }

    /// Interactive shell input never creates verification evidence.
    @discardableResult
    func submitCommand(_ command: String) -> Bool {
        guard masterFD >= 0, verificationRun == nil, !command.isEmpty else { return false }
        send(command + "\n")
        return masterFD >= 0
    }

    private func send(_ text: String) {
        guard masterFD >= 0, let data = text.data(using: .utf8) else { return }
        guard verificationRun == nil || text == "\u{03}" else { return }
        if text != "\u{03}", text.hasSuffix("\n") {
            let command = String(text.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
            if !command.isEmpty {
                commandHistory.append(command)
                commandHistory = Array(commandHistory.suffix(100))
            }
            state = .running
        }
        enqueueInput(data)
    }

    func interrupt() {
        guard masterFD >= 0 else { return }
        cancelVerification()
        state = .interrupting
        let droppedInput = inputOffset < pendingInput.count
        clearPendingInput()
        // Keep the normal Ctrl-C byte for raw-mode programs when the PTY accepts it.
        // If backed up, signal the PTY's foreground group without waiting for another write.
        if !droppedInput, Self.writeInput(Data([3]), from: 0, to: masterFD) == 1 { return }
        _ = tcflush(masterFD, TCIFLUSH)
        let foreground = tcgetpgrp(masterFD)
        if foreground > 0, foreground != getpgrp() {
            kill(-foreground, SIGINT)
        } else if processID > 0 {
            kill(processID, SIGINT)
        }
    }

    func runVerification(_ recipe: VerificationRecipe, repositoryID: String, repositoryFingerprint: String) {
        guard Self.acceptedVerificationRecipe(recipe) != nil, masterFD >= 0, state == .ready else { return }
        let id = UUID()
        let marker = "__HERMES_VERIFY_\(id.uuidString.replacingOccurrences(of: "-", with: ""))__"
        let run = VerificationRun(
            id: id, recipeID: recipe.id, repositoryID: repositoryID, repositoryFingerprint: repositoryFingerprint,
            command: recipe.command, startedAt: .now, finishedAt: nil, exitCode: nil, outputSummary: nil)
        verificationMarker = marker
        verificationRun = run
        lastVerificationRun = run
        verificationTail = ""
        state = .running
        let payload = "\(recipe.command); printf '\\n\(marker):%s\\n' \"$?\"\n"
        enqueueInput(Data(payload.utf8))
    }

    private func enqueueInput(_ data: Data) {
        guard masterFD >= 0, !data.isEmpty else { return }
        pendingInput.append(data)
        if writer == nil { drainInput() }
    }

    /// One bounded, nonblocking write per callback. Only arm the source while bytes are pending.
    private func drainInput() {
        let count = Self.writeInput(pendingInput, from: inputOffset, to: masterFD)
        if count < 0 {
            finishVerificationFailure("Terminal input failed before reporting a result.")
            close()
            state = .failed("Terminal input failed. Restart the terminal to reconnect.")
            return
        }
        inputOffset += count
        if inputOffset == pendingInput.count {
            clearPendingInput()
        } else if writer == nil {
            let lifecycle = lifecycleID
            let fd = fcntl(masterFD, F_DUPFD_CLOEXEC, 0)
            guard fd >= 0 else {
                finishVerificationFailure("Terminal input failed before reporting a result.")
                close()
                state = .failed("Terminal input failed. Restart the terminal to reconnect.")
                return
            }
            let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: .main)
            writer = source
            source.setCancelHandler { @Sendable in Darwin.close(fd) }
            source.setEventHandler { @Sendable [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.lifecycleID == lifecycle, self.writer != nil else { return }
                    self.drainInput()
                }
            }
            source.activate()
        }
    }

    nonisolated static func writeInput(_ data: Data, from offset: Int, to fd: Int32) -> Int {
        guard offset < data.count else { return 0 }
        let wrote = data.withUnsafeBytes { buffer in
            Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), min(data.count - offset, 16384))
        }
        if wrote < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) { return 0 }
        return wrote
    }

    private func clearPendingInput() {
        writer?.cancel()
        writer = nil
        pendingInput.removeAll()
        inputOffset = 0
    }

    nonisolated static func acceptedVerificationRecipe(_ recipe: VerificationRecipe) -> VerificationRecipe? {
        guard VerificationRecipeBuilder.normalizedCommand(recipe.command) == recipe.command else { return nil }
        return recipe
    }

    func clear() {
        emulator.view.receiveOutput(Array("\u{1b}[2J\u{1b}[3J\u{1b}[H".utf8)[...])
        outputBuffer.removeAll()
    }

    private func consume(_ text: String) {
        guard let marker = verificationMarker, let pending = verificationRun else {
            outputBuffer.append(text)
            return
        }
        verificationTail.append(text)
        guard let receipt = Self.verificationReceipt(marker: marker, in: verificationTail) else {
            let keep = marker.count + 24
            if verificationTail.count > keep {
                let flushCount = verificationTail.count - keep
                let flushIndex = verificationTail.index(verificationTail.startIndex, offsetBy: flushCount)
                outputBuffer.append(String(verificationTail[..<flushIndex]))
                verificationTail = String(verificationTail[flushIndex...])
            }
            return
        }
        let before = String(verificationTail[..<receipt.range.lowerBound])
        outputBuffer.append(before)
        outputBuffer.append(String(verificationTail[receipt.range.upperBound...]))
        let completed = VerificationRun(
            id: pending.id, recipeID: pending.recipeID, repositoryID: pending.repositoryID,
            repositoryFingerprint: pending.repositoryFingerprint, command: pending.command,
            startedAt: pending.startedAt, finishedAt: .now, exitCode: receipt.exitCode,
            outputSummary: HermesDiagnosticsService.safeSummary(before))
        verificationRun = nil
        verificationMarker = nil
        verificationTail = ""
        lastVerificationRun = completed
        state = .ready
    }

    private func cancelVerification() {
        finishVerificationFailure("Interrupted", exitCode: 130)
    }

    private func finishVerificationFailure(_ message: String, exitCode: Int? = nil) {
        guard let pending = verificationRun else { return }
        outputBuffer.append(verificationTail)
        lastVerificationRun = VerificationRun(
            id: pending.id, recipeID: pending.recipeID, repositoryID: pending.repositoryID,
            repositoryFingerprint: pending.repositoryFingerprint, command: pending.command,
            startedAt: pending.startedAt, finishedAt: .now, exitCode: exitCode, outputSummary: message)
        verificationRun = nil
        verificationMarker = nil
        verificationTail = ""
    }

    /// An empty result means EOF. A nil result means a nonblocking read must wait for more data.
    nonisolated static func readOutput(_ fd: Int32) -> Data? {
        var buffer = [UInt8](repeating: 0, count: outputDeliveryBytes)
        repeat {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { return nil }
            return Data(buffer.prefix(max(0, count)))
        } while true
    }

    /// The serial PTY reader owns the pending bytes. The emulator receives the original stream.
    final class OutputDecoder: @unchecked Sendable {
        private var pending = Data()

        func decode(_ data: Data) -> String {
            var bytes = pending
            bytes.append(data)
            pending.removeAll()
            if !data.isEmpty, let start = bytes.indices.suffix(3).last(where: { bytes[$0] & 0xC0 != 0x80 }) {
                let lead = bytes[start]
                let length: Int
                switch lead {
                case 0xC2...0xDF: length = 2
                case 0xE0...0xEF: length = 3
                case 0xF0...0xF4: length = 4
                default: length = 1
                }
                if bytes.endIndex - start < length {
                    pending = Data(bytes[start...])
                    bytes.removeSubrange(start...)
                }
            }
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    nonisolated private static let escapePatterns = [
        "\u{001B}\\][^\u{0007}]*(?:\u{0007}|\u{001B}\\\\)",
        "\u{001B}\\[[0-?]*[ -/]*[@-~]",
        "\u{001B}[()][0-2]",
    ].map { try! NSRegularExpression(pattern: $0) }

    nonisolated private static func cleanTerminalText(_ text: String) -> String {
        var cleaned = text
        if text.contains("\u{001B}") {
            for regex in escapePatterns {
                let range = NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned)
                cleaned = regex.stringByReplacingMatches(in: cleaned, range: range, withTemplate: "")
            }
        }
        return cleaned.replacingOccurrences(of: "\r", with: "")
    }

    nonisolated static func verificationReceipt(marker: String, in text: String)
        -> (range: Range<String.Index>, exitCode: Int)?
    {
        let prefix = marker + ":"
        var start = text.startIndex
        while let end = text[start...].firstIndex(of: "\n") {
            let line = text[start..<end]
            let next = text.index(after: end)
            if line.hasPrefix(prefix), let code = Int(line.dropFirst(prefix.count)), (0...255).contains(code) {
                return (start..<next, code)
            }
            start = next
        }
        return nil
    }

    nonisolated static func verificationExitCode(marker: String, in text: String) -> Int? {
        verificationReceipt(marker: marker, in: text)?.exitCode
    }

    func close() {
        lifecycleID = UUID()
        reader?.cancel()
        reader = nil
        clearPendingInput()
        finishVerificationFailure("Terminal closed before reporting a result.")
        if masterFD >= 0 {
            let foreground = tcgetpgrp(masterFD)
            if foreground > 0, foreground != getpgrp() { kill(-foreground, SIGHUP) }
            Darwin.close(masterFD)
        }
        if processID > 0 { kill(processID, SIGTERM) }
        masterFD = -1
        processID = 0
        if state != .idle { state = .closed }
    }

    deinit {
        reader?.cancel()
        writer?.cancel()
        if masterFD >= 0 { Darwin.close(masterFD) }
        if processID > 0 { kill(processID, SIGTERM) }
    }
}

/// One queue for all PTYs. Each reader holds at most one delivery while suspended.
private final class TerminalOutputDelivery: Sendable {
    typealias Work = @MainActor @Sendable () -> Void

    static let shared = TerminalOutputDelivery()
    private struct State {
        var queued: [Work] = []
        var scheduled = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    func enqueue(_ work: @escaping Work) {
        let shouldSchedule = state.withLock { state in
            state.queued.append(work)
            guard !state.scheduled else { return false }
            state.scheduled = true
            return true
        }
        if shouldSchedule { schedule() }
    }

    private func schedule() {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(4)) { self.drain() }
    }

    @MainActor private func drain() {
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<4 {
            let work = state.withLock { state -> Work? in
                guard !state.queued.isEmpty else {
                    state.scheduled = false
                    return nil
                }
                return state.queued.removeFirst()
            }
            guard let work else { return }
            work()
            if DispatchTime.now().uptimeNanoseconds - start >= 2_000_000 { break }
        }
        let hasPendingWork = state.withLock { state in
            if state.queued.isEmpty { state.scheduled = false }
            return state.scheduled
        }
        if hasPendingWork { schedule() }
    }
}
