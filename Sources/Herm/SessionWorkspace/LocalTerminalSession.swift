import Foundation
import Darwin

@MainActor
final class LocalTerminalSession: ObservableObject, Identifiable {
    let id = UUID()
    @Published private(set) var projectCommand: LocalProjectCommand?
    private var projectCommandTail = ""

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

    /// Bounded terminal output that trims only at UTF-8-safe line boundaries.
    struct OutputBuffer: Equatable {
        let maxBytes: Int
        let maxLines: Int
        private(set) var text = ""
        private var byteCount = 0
        private var newlineCount = 0

        init(maxBytes: Int = LocalTerminalSession.maxOutputBytes, maxLines: Int = LocalTerminalSession.maxOutputLines) {
            self.maxBytes = max(1, maxBytes)
            self.maxLines = max(1, maxLines)
        }

        mutating func append(_ addition: String) {
            text.append(addition)
            byteCount += addition.utf8.count
            newlineCount += addition.utf8.count { $0 == 10 }
            trim()
        }

        mutating func removeAll() {
            text.removeAll(keepingCapacity: true)
            byteCount = 0
            newlineCount = 0
        }

        private mutating func trim() {
            let partialLine = text.isEmpty || text.hasSuffix("\n") ? 0 : 1
            guard byteCount > maxBytes || newlineCount + partialLine > maxLines else { return }
            let bytes = text.utf8
            var start = bytes.startIndex
            while byteCount > maxBytes || newlineCount + partialLine > maxLines {
                if let newline = bytes[start...].firstIndex(of: 10) {
                    let next = bytes.index(after: newline)
                    byteCount -= bytes.distance(from: start, to: next)
                    newlineCount -= 1
                    start = next
                } else {
                    // A single oversized line keeps its newest valid UTF-8 suffix.
                    start = bytes.index(bytes.endIndex, offsetBy: -maxBytes)
                    while start < bytes.endIndex, bytes[start] & 0xC0 == 0x80 {
                        start = bytes.index(after: start)
                    }
                    byteCount = bytes.distance(from: start, to: bytes.endIndex)
                    break
                }
            }
            text = String(decoding: bytes[start...], as: UTF8.self)
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
    private var handle: FileHandle?
    private var outputBuffer = OutputBuffer()
    private var lifecycleID = UUID()
    private var verificationMarker: String?
    private var verificationRun: VerificationRun?
    private var verificationTail = ""

    func start(directory: String) {
        close()
        let url = URL(fileURLWithPath: directory).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
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
        let directoryPath = strdup(url.path)
        let arguments: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/zsh"), strdup("-il"), nil]
        let environmentPointers: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            free(directoryPath)
            (arguments + environmentPointers).forEach { free($0) }
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
        let terminalHandle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        handle = terminalHandle
        terminalHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                Task { @MainActor [weak self] in
                    guard let self, self.lifecycleID == lifecycleID, self.masterFD >= 0 else { return }
                    self.handle?.readabilityHandler = nil
                    Darwin.close(self.masterFD)
                    self.handle = nil
                    self.masterFD = -1
                    self.processID = 0
                    if self.projectCommand?.isRunning == true { self.projectCommand?.interrupted = true }
                    self.state = .exited
                }
                return
            }
            let text = Self.cleanTerminalText(String(decoding: data, as: UTF8.self))
            Task { @MainActor [weak self] in
                guard let self, self.lifecycleID == lifecycleID, self.masterFD >= 0 else { return }
                self.emulator.view.feed(byteArray: Array(data)[...])
                self.consumeProjectCommand(String(decoding: data, as: UTF8.self))
                self.consume(text)
                if self.state == .starting { self.state = .ready }
            }
        }
        state = .ready
        resize(columns: emulator.view.getTerminal().cols, rows: emulator.view.getTerminal().rows)
    }

    func resize(columns: Int, rows: Int) {
        guard masterFD >= 0 else { return }
        var size = winsize(ws_row: UInt16(clamping: max(1, rows)), ws_col: UInt16(clamping: max(1, columns)), ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(masterFD, TIOCSWINSZ, &size)
    }

    func sendInput(_ bytes: ArraySlice<UInt8>) {
        guard masterFD >= 0 else { return }
        if bytes.elementsEqual([3]) { interrupt(); return }
        guard verificationRun == nil else { return }
        if bytes.contains(13) || bytes.contains(10) { state = .running }
        try? handle?.write(contentsOf: Data(bytes))
    }

    /// Interactive shell input never creates verification evidence.
    @discardableResult
    func submitCommand(_ command: String) -> Bool {
        guard masterFD >= 0, verificationRun == nil, !command.isEmpty else { return false }
        send(command + "\n")
        return true
    }

    @discardableResult
    func runProjectCommand(_ command: String) -> Bool {
        let id = UUID()
        guard projectCommand?.isRunning != true, !hasForegroundJob,
              let payload = LocalProjectCommand.payload(command: command, id: id), masterFD >= 0 else { return false }
        projectCommand = LocalProjectCommand(id: id, command: command)
        projectCommandTail = ""
        send(payload)
        return true
    }
    private func consumeProjectCommand(_ output: String) {
        guard let command = projectCommand, command.isRunning else { return }
        projectCommandTail += output
        if let code = LocalProjectCommand.exitCode(id: command.id, output: projectCommandTail) {
            projectCommand?.exitCode = code; projectCommandTail = ""; state = .ready
        } else { projectCommandTail = String(projectCommandTail.suffix(512)) }
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
        try? handle?.write(contentsOf: data)
    }

    func interrupt() {
        guard masterFD >= 0 else { return }
        cancelVerification()
        state = .interrupting
        send("\u{03}")
    }

    func runVerification(_ recipe: VerificationRecipe, repositoryID: String, repositoryFingerprint: String) {
        guard Self.acceptedVerificationRecipe(recipe) != nil, masterFD >= 0, state == .ready else { return }
        let id = UUID()
        let marker = "__HERMES_VERIFY_\(id.uuidString.replacingOccurrences(of: "-", with: ""))__"
        let run = VerificationRun(id: id, recipeID: recipe.id, repositoryID: repositoryID, repositoryFingerprint: repositoryFingerprint, command: recipe.command, startedAt: .now, finishedAt: nil, exitCode: nil, outputSummary: nil)
        verificationMarker = marker
        verificationRun = run
        lastVerificationRun = run
        verificationTail = ""
        state = .running
        let payload = "\(recipe.command); printf '\\n\(marker):%s\\n' \"$?\"\n"
        if let data = payload.data(using: .utf8) { try? handle?.write(contentsOf: data) }
    }

    nonisolated static func acceptedVerificationRecipe(_ recipe: VerificationRecipe) -> VerificationRecipe? {
        guard VerificationRecipeBuilder.normalizedCommand(recipe.command) == recipe.command else { return nil }
        return recipe
    }

    func clear() {
        emulator.view.feed(text: "\u{1b}[2J\u{1b}[3J\u{1b}[H")
        outputBuffer.removeAll()
    }

    private func consume(_ text: String) {
        guard let marker = verificationMarker, let pending = verificationRun else {
            outputBuffer.append(text)
            return
        }
        verificationTail.append(text)
        guard let markerRange = verificationTail.range(of: marker) else {
            let keep = marker.count + 24
            if verificationTail.count > keep {
                let flushCount = verificationTail.count - keep
                let flushIndex = verificationTail.index(verificationTail.startIndex, offsetBy: flushCount)
                outputBuffer.append(String(verificationTail[..<flushIndex]))
                verificationTail = String(verificationTail[flushIndex...])
            }
            return
        }
        let before = String(verificationTail[..<markerRange.lowerBound])
        outputBuffer.append(before)
        let afterMarker = verificationTail[markerRange.upperBound...]
        guard let exitCode = Self.verificationExitCode(marker: marker, in: "\(marker):\(afterMarker)") else { return }
        let completed = VerificationRun(id: pending.id, recipeID: pending.recipeID, repositoryID: pending.repositoryID, repositoryFingerprint: pending.repositoryFingerprint, command: pending.command, startedAt: pending.startedAt, finishedAt: .now, exitCode: exitCode, outputSummary: HermesDiagnosticsService.safeSummary(before))
        verificationRun = nil
        verificationMarker = nil
        verificationTail = ""
        lastVerificationRun = completed
        state = .ready
    }

    private func cancelVerification() {
        guard let pending = verificationRun else { return }
        lastVerificationRun = VerificationRun(id: pending.id, recipeID: pending.recipeID, repositoryID: pending.repositoryID, repositoryFingerprint: pending.repositoryFingerprint, command: pending.command, startedAt: pending.startedAt, finishedAt: .now, exitCode: 130, outputSummary: "Interrupted")
        verificationRun = nil
        verificationMarker = nil
        verificationTail = ""
    }

    nonisolated private static func cleanTerminalText(_ text: String) -> String {
        var cleaned = text
        let patterns = [
            "\u{001B}\\][^\u{0007}]*(?:\u{0007}|\u{001B}\\\\)",
            "\u{001B}\\[[0-?]*[ -/]*[@-~]",
            "\u{001B}[()][0-2]"
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned)
                cleaned = regex.stringByReplacingMatches(in: cleaned, range: range, withTemplate: "")
            }
        }
        return cleaned.replacingOccurrences(of: "\r", with: "")
    }

    nonisolated static func verificationExitCode(marker: String, in text: String) -> Int? {
        guard let range = text.range(of: "\(marker):") else { return nil }
        let digits = text[range.upperBound...].prefix(while: { $0.isNumber })
        return Int(digits)
    }

    func close() {
        if projectCommand?.isRunning == true { projectCommand?.interrupted = true }
        projectCommandTail = ""
        lifecycleID = UUID()
        handle?.readabilityHandler = nil
        if masterFD >= 0 {
            let foreground = tcgetpgrp(masterFD)
            if foreground > 0, foreground != getpgrp() { kill(-foreground, SIGHUP) }
            if let data = "exit\n".data(using: .utf8) {
                try? handle?.write(contentsOf: data)
            }
            Darwin.close(masterFD)
        }
        if processID > 0 { kill(processID, SIGTERM) }
        handle = nil
        masterFD = -1
        processID = 0
        if state != .idle { state = .closed }
    }

    deinit {
        handle?.readabilityHandler = nil
        if masterFD >= 0 { Darwin.close(masterFD) }
        if processID > 0 { kill(processID, SIGTERM) }
    }
}
