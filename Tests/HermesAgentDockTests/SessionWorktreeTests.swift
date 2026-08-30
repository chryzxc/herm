import Foundation
import Testing
@testable import HermesAgentDock

struct SessionWorktreeTests {
    @Test func parsesSecretFreeStructuredSummaries() throws {
        let data = Data(#"{"session_id":"session-1","export":{"format":"jsonl","record_count":3},"history":{"event_count":4,"latest_at":"2026-08-29T12:00:00Z"},"worktree":{"id":"tree-1","session_id":"session-1","state":"ready"}}"#.utf8)

        let projection = try #require(WorktreeService.parse(data: data, forSessionID: "session-1"))

        #expect(projection.state == .ready)
        #expect(projection.export?.recordCount == 3)
        #expect(projection.history?.eventCount == 4)
        #expect(projection.worktree?.sessionID == "session-1")
        #expect(projection.worktree?.path == nil)
    }

    @Test func rejectsHumanTablesTranscriptsPromptsAndPaths() {
        let table = Data("SESSION ID  MESSAGES\nsession-1  4".utf8)
        #expect(WorktreeService.parse(data: table, forSessionID: "session-1") == nil)

        let unsafe = Data(#"{"session_id":"session-1","export":{"format":"md","prompt":"secret prompt","transcript":"raw transcript","path":"/Users/me/project"}}"#.utf8)
        #expect(WorktreeService.parse(data: unsafe, forSessionID: "session-1") == nil)
    }

    @Test func reportsMalformedUnsupportedUnavailableAndStaleStates() throws {
        let malformed = Data(#"{"session_id":"session-1","export":{"format":"yaml","record_count":1}}"#.utf8)
        #expect(WorktreeService.parse(data: malformed, forSessionID: "session-1")?.state == .malformed)

        let unsupported = Data(#"{"session_id":"session-1","export":{"format":"trace","record_count":1}}"#.utf8)
        #expect(WorktreeService.parse(data: unsupported, forSessionID: "session-1")?.state == .unsupported)

        let unavailable = Data(#"{"session_id":"session-1","status":"unavailable"}"#.utf8)
        #expect(WorktreeService.parse(data: unavailable, forSessionID: "session-1")?.state == .unavailable)

        let stale = Data(#"{"session_id":"session-1","status":"stale","export":{"format":"jsonl","record_count":1}}"#.utf8)
        #expect(WorktreeService.parse(data: stale, forSessionID: "session-1")?.state == .stale)
    }

    @Test func worktreeContextCannotTransferBetweenSessionIDs() throws {
        let data = Data(#"{"session_id":"session-1","worktree":{"id":"tree-1","session_id":"session-1","state":"ready"}}"#.utf8)

        #expect(WorktreeService.parse(data: data, forSessionID: "session-2")?.state == .malformed)
        #expect(WorktreeService.parse(data: data, forSessionID: "session-2")?.worktree == nil)
    }

    @Test func availabilityProjectionIsReadOnlyAndExplicit() {
        let projection = SessionWorkspaceAvailability(sessionID: "session-1", export: .ready, history: .unsupported, worktree: .unavailable)
        #expect(projection.sessionID == "session-1")
        #expect(projection.export == .ready)
        #expect(projection.history == .unsupported)
        #expect(projection.worktree == .unavailable)
    }
}
