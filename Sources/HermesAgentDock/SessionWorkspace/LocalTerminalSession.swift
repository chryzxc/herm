import Foundation
import Darwin

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

    /// Bounded terminal output that trims only at UTF-8-safe line boundaries.
    struct OutputBuffer: Equatable {
        let maxBytes: Int
        let maxLines: Int
        private(set) var text = ""

        init(maxBytes: Int = LocalTerminalSession.maxOutputBytes, maxLines: Int = LocalTerminalSession.maxOutputLines) {
            self.maxBytes = max(1, maxBytes)
            self.maxLines = max(1, maxLines)
        }

        mutating func append(_ addition: String) {
            text.append(addition)
            trim()
        }

        mutating func removeAll() { text.removeAll(keepingCapacity: true) }

        private mutating func trim() {
            var bytes = Array(text.utf8)
            if bytes.count > maxBytes {
                bytes.removeFirst(bytes.count - maxBytes)
                if let newline = bytes.firstIndex(of: 10) {
                    bytes.removeFirst(newline + 1)
                }
                text = String(decoding: bytes, as: UTF8.self)
            }

            let hasTrailingNewline = text.last == "\n"
            var lines = text.split(separator: "\n", omittingEmptySubsequences: true)
            if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
            text = lines.joined(separator: "\n") + (hasTrailingNewline ? "\n" : "")
        }
    }

    @Published private(set) var output = ""
    @Published private(set) var state: State = .idle
    @Published private(set) var workingDirectory: String?
    @Published private(set) var commandHistory: [String] = []
    @Published private(set) var lastVerificationRun: VerificationRun?

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
        output = outputBuffer.text
        commandHistory = []
        lastVerificationRun = nil
        verificationMarker = nil
        verificationRun = nil
        verificationTail = ""
        workingDirectory = url.path
        var size = winsize(ws_row: 24, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
        var fd: Int32 = -1
        let child = forkpty(&fd, nil, nil, &size)
        guard child >= 0 else {
            state = .failed(String(cString: strerror(errno)))
            return
        }
        if child == 0 {
            _ = chdir(url.path)
            setenv("TERM", "xterm-256color", 1)
            var arguments: [UnsafeMutablePointer<CChar>?] = [
                strdup("/bin/zsh"),
                strdup("-il"),
                nil
            ]
            arguments.withUnsafeMutableBufferPointer { buffer in
                _ = execv(buffer[0], buffer.baseAddress)
            }
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
                    self.state = .exited
                }
                return
            }
            let text = Self.cleanTerminalText(String(decoding: data, as: UTF8.self))
            Task { @MainActor [weak self] in
                guard let self, self.lifecycleID == lifecycleID, self.masterFD >= 0 else { return }
                self.consume(text)
                if self.state == .starting { self.state = .ready }
            }
        }
        state = .ready
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
        outputBuffer.removeAll()
        output = outputBuffer.text
    }

    private func consume(_ text: String) {
        guard let marker = verificationMarker, let pending = verificationRun else {
            outputBuffer.append(text)
            output = outputBuffer.text
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
                output = outputBuffer.text
            }
            return
        }
        let before = String(verificationTail[..<markerRange.lowerBound])
        outputBuffer.append(before)
        output = outputBuffer.text
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
        lifecycleID = UUID()
        handle?.readabilityHandler = nil
        if masterFD >= 0 {
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
