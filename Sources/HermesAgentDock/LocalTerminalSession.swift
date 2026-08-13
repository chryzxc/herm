import Foundation
import Darwin

@MainActor
final class LocalTerminalSession: ObservableObject {
    enum State: Equatable { case idle, starting, running, closed, failed(String) }

    @Published private(set) var output = ""
    @Published private(set) var state: State = .idle
    @Published private(set) var workingDirectory: String?

    private var masterFD: Int32 = -1
    private var processID: pid_t = 0
    private var handle: FileHandle?

    func start(directory: String) {
        close()
        let url = URL(fileURLWithPath: directory).standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            state = .failed("Project directory is unavailable.")
            return
        }
        state = .starting
        output = ""
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
        let terminalHandle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        handle = terminalHandle
        terminalHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                Task { @MainActor [weak self] in
                    guard let self, self.masterFD >= 0 else { return }
                    self.handle?.readabilityHandler = nil
                    Darwin.close(self.masterFD)
                    self.handle = nil
                    self.masterFD = -1
                    self.processID = 0
                    self.state = .closed
                }
                return
            }
            let text = Self.cleanTerminalText(String(decoding: data, as: UTF8.self))
            Task { @MainActor [weak self] in
                guard let self, self.masterFD >= 0 else { return }
                self.output = String((self.output + text).suffix(256_000))
                self.state = .running
            }
        }
        state = .running
    }

    func send(_ text: String) {
        guard masterFD >= 0, let data = text.data(using: .utf8) else { return }
        try? handle?.write(contentsOf: data)
    }

    func interrupt() { send("\u{03}") }

    func clear() { output = "" }

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

    func close() {
        handle?.readabilityHandler = nil
        if masterFD >= 0 {
            send("exit\n")
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
