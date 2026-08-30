import Testing
@testable import HermesAgentDock

struct LocalTerminalSessionTests {
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
}
