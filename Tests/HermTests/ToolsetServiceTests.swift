import Foundation
import Testing
@testable import Herm

struct ToolsetServiceTests {
    @Test func parsesToolsetsWithoutClaimingUnverifiedBackends() {
        let snapshot = ToolsetService.snapshot(from: [
            "toolsets": ["terminal": ["enabled": true]],
            "terminal_backend": ["available": true],
            "browser": ["configured": false]
        ])

        #expect(snapshot.toolsets.first?.id == "terminal")
        #expect(snapshot.toolsets.first?.isEnabled == true)
        #expect(snapshot.backend(.terminal)?.state == .available)
        #expect(snapshot.backend(.browser)?.state == .requiresSetup)
        #expect(snapshot.backend(.computerUse)?.state == .unavailable)
        #expect(snapshot.backend(.lsp)?.state == .unavailable)
    }

    @Test func malformedOrMissingDataFailsClosed() {
        let snapshot = ToolsetService.snapshot(from: [:])

        #expect(snapshot.toolsets.isEmpty)
        #expect(snapshot.backend(.terminal)?.state == .unavailable)
        #expect(snapshot.backend(.browser)?.state == .unavailable)
        #expect(snapshot.backend(.computerUse)?.state == .unavailable)
        #expect(snapshot.backend(.lsp)?.state == .unavailable)
    }

    @Test func toolsetMutationIsRestartRequiredAndCannotTouchActiveSession() {
        let snapshot = ToolsetService.snapshot(from: [
            "toolsets": ["terminal": ["enabled": false]],
            "active_session_id": "session-1"
        ])

        #expect(snapshot.restartRequired)
        #expect(snapshot.activeSessionID == "session-1")
        #expect(ToolsetService.requestChange(.enable, toolset: .terminal, snapshot: snapshot) == .unavailable("Toolset changes apply to the next session; the active conversation is unchanged."))
    }

    @Test func browserAndComputerUseExposeSetupGuidanceOnly() {
        let snapshot = ToolsetService.snapshot(from: [
            "browser": ["configured": false, "detail": "Install browser provider"],
            "computer_use": ["configured": true, "authorized": false]
        ])

        #expect(snapshot.backend(.browser)?.detail == "Install browser provider")
        #expect(snapshot.backend(.computerUse)?.state == .requiresSetup)
        #expect(snapshot.backend(.computerUse)?.detail == "Browser/computer-use authorization is required.")
    }
}
