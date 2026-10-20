import Foundation
import Testing

@testable import Herm

struct LocalProjectCommandTests {
    @Test func completionRequiresAFullMatchingMarker() throws {
        let id = UUID()
        let prefix = "\u{1b}]777;herm-action;\(id.uuidString);"
        #expect(LocalProjectCommand.exitCode(id: id, output: prefix + "7") == nil)
        #expect(LocalProjectCommand.exitCode(id: id, output: prefix + "7\u{7}") == 7)
        #expect(LocalProjectCommand.exitCode(id: UUID(), output: prefix + "7\u{7}") == nil)
        let payload = try #require(LocalProjectCommand.payload(command: "printf '%s' '$HOME'", id: id))
        #expect(payload.contains("'\\''"))
        #expect(LocalProjectCommand.payload(command: "bad\0command", id: id) == nil)
    }
    @MainActor @Test func configuredActionReportsExitWithoutVerificationEvidence() async throws {
        let session = LocalTerminalSession()
        defer { session.close() }
        session.start(directory: FileManager.default.temporaryDirectory.path)
        #expect(session.runProjectCommand("exit 7"))
        #expect(!session.runProjectCommand("exit 0"))
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while session.projectCommand?.isRunning == true, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(session.projectCommand?.exitCode == 7)
        #expect(session.lastVerificationRun == nil)
    }
}
