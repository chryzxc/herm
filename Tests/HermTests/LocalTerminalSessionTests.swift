import Combine
import Foundation
import Testing

@testable import Herm

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
        // Wait for the login shell to execute input before testing its line editor.
        // Octal escapes ensure the marker cannot be satisfied by PTY input echo.
        #expect(terminal.submitCommand("printf '\\110\\105\\122\\115\\137\\122\\105\\101\\104\\131'"))
        for _ in 0..<100 {
            if terminal.output.contains("HERM_READY") { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(terminal.output.contains("HERM_READY"))
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

    @MainActor @Test func terminalOutputDoesNotRebuildTheSwiftUIWorkspace() async throws {
        let terminal = LocalTerminalSession()
        terminal.start(directory: FileManager.default.temporaryDirectory.path)
        #expect(terminal.submitCommand("printf '__HERM_OUTPUT_TEST__\\n'"))
        var publications = 0
        let subscription = terminal.objectWillChange.sink { publications += 1 }
        defer {
            subscription.cancel()
            terminal.close()
        }
        for _ in 0..<100 {
            if terminal.output.contains("__HERM_OUTPUT_TEST__") { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(terminal.output.contains("__HERM_OUTPUT_TEST__"))
        #expect(publications == 0)
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
        #expect(!buffer.text.contains("\u{FFFD}"))
    }

    @Test func outputBufferPreservesBlankLinesAndSplitChunks() {
        var buffer = LocalTerminalSession.OutputBuffer(maxBytes: 100, maxLines: 4)
        buffer.append("one\n\n")
        buffer.append("tw")
        buffer.append("o\n\nthree")
        #expect(buffer.text == "\ntwo\n\nthree")
        buffer.removeAll()
        buffer.append("fresh\n\n")
        #expect(buffer.text == "fresh\n\n")
    }

    @Test func oversizedSingleLineRetainsAValidUnicodeSuffix() {
        var buffer = LocalTerminalSession.OutputBuffer(maxBytes: 7, maxLines: 4)
        buffer.append("aこんにちは")
        #expect(buffer.text == "ちは")
        #expect(buffer.text.utf8.count <= 7)
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
        let allowed = VerificationRecipe(
            id: "test:swift test", title: "Run tests", command: "swift test", kind: .test, workingDirectory: "/tmp",
            source: "Hermes project facts")
        let arbitrary = VerificationRecipe(
            id: "arbitrary", title: "No", command: "rm -rf .", kind: .custom, workingDirectory: "/tmp",
            source: "user input")

        #expect(LocalTerminalSession.acceptedVerificationRecipe(allowed) == allowed)
        #expect(LocalTerminalSession.acceptedVerificationRecipe(arbitrary) == nil)
    }
}
