import Foundation
import Testing
@testable import HermesAgentDock

struct LocalTerminalSessionTests {
    @MainActor @Test func terminalRendererAppliesCursorMovementAndColors() {
        let terminal = LocalTerminalSession()
        terminal.emulator.view.feed(text: "hello\r\u{1b}[31mworld\u{1b}[0m")
        let line = terminal.emulator.view.getTerminal().getLine(row: 0)?.translateToString(trimRight: true)
        #expect(line == "world")
    }

    @MainActor @Test func commandsRequireAnOpenShell() {
        let terminal = LocalTerminalSession()
        #expect(!terminal.submitCommand("pwd"))
        #expect(terminal.commandHistory.isEmpty)
        #expect(terminal.lastVerificationRun == nil)
    }

    @MainActor @Test func interactiveCommandUsesWorkingDirectoryWithoutVerificationEvidence() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let terminal = LocalTerminalSession()
        terminal.start(directory: directory.path)
        defer { terminal.close() }
        // Send actual keystrokes, including backspace and Return, through the PTY.
        terminal.sendInput(Array("printf inspector-test > result.txX\u{7f}t\r".utf8)[...])
        let result = directory.appendingPathComponent("result.txt")
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: result.path) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(try String(contentsOf: result, encoding: .utf8) == "inspector-test")
        #expect(terminal.lastVerificationRun == nil)
        terminal.close()
        #expect(!terminal.submitCommand("pwd"))
    }

    @MainActor @Test func missingProjectDirectoryFailsClosed() {
        let terminal = LocalTerminalSession()
        terminal.start(directory: "/tmp/hermes-terminal-directory-does-not-exist")

        #expect(terminal.state == .failed("Project directory is unavailable."))
        #expect(terminal.workingDirectory == nil)
    }

    @MainActor @Test func closingAnIdleTerminalDoesNotCreateAProcess() {
        let terminal = LocalTerminalSession()
        terminal.close()

        #expect(terminal.state == .idle)
        #expect(terminal.output.isEmpty)
    }

    @Test func verificationExitMarkerParsesOnlyNumericExitCodes() {
        #expect(LocalTerminalSession.verificationExitCode(marker: "MARK", in: "output\nMARK:0\n") == 0)
        #expect(LocalTerminalSession.verificationExitCode(marker: "MARK", in: "MARK:127\n") == 127)
        #expect(LocalTerminalSession.verificationExitCode(marker: "MARK", in: "MARK:error\n") == nil)
    }

    @Test func outputBufferPreservesNewestCompleteLines() {
        var buffer = LocalTerminalSession.OutputBuffer(maxBytes: 40, maxLines: 3)
        buffer.append("one\ntwo\nthree\nfour\n")

        #expect(buffer.text == "two\nthree\nfour\n")
        #expect(buffer.text.utf8.count <= 40)
    }

    @Test func outputBufferNeverSplitsUTF8Characters() {
        var buffer = LocalTerminalSession.OutputBuffer(maxBytes: 12, maxLines: 10)
        buffer.append("prefix\nこんにちは\n")

        #expect(String(decoding: buffer.text.utf8, as: UTF8.self) == buffer.text)
        #expect(buffer.text.utf8.count <= 12)
    }

    @Test func outputBufferClearRemovesAllContent() {
        var buffer = LocalTerminalSession.OutputBuffer()
        buffer.append("output")
        buffer.removeAll()

        #expect(buffer.text.isEmpty)
    }

    @Test func terminalLimitsAreExplicit() {
        #expect(LocalTerminalSession.maxOutputBytes == 256_000)
        #expect(LocalTerminalSession.maxOutputLines == 2_000)
    }

    @Test func arbitraryCommandsCannotBecomeVerificationRecipes() {
        let allowed = VerificationRecipe(id: "test:swift test", title: "Run tests", command: "swift test", kind: .test, workingDirectory: "/tmp", source: "Hermes project facts")
        let arbitrary = VerificationRecipe(id: "arbitrary", title: "No", command: "rm -rf .", kind: .custom, workingDirectory: "/tmp", source: "user input")

        #expect(LocalTerminalSession.acceptedVerificationRecipe(allowed) == allowed)
        #expect(LocalTerminalSession.acceptedVerificationRecipe(arbitrary) == nil)
    }
}
