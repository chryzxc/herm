import Foundation
import Testing

@testable import Herm

struct SessionAgentStateRetentionTests {
    private func state(eventAt seconds: TimeInterval?, callAt callSeconds: TimeInterval? = nil) -> SessionAgentState {
        let events = seconds.map {
            [AgentEvent(id: UUID(), type: "tool", detail: "", timestamp: Date(timeIntervalSince1970: $0))]
        }
        let calls = callSeconds.map {
            [
                ActiveToolCall(
                    id: "call", name: "patch", input: "", context: "",
                    startedAt: Date(timeIntervalSince1970: $0), isComplete: false)
            ]
        }
        return SessionAgentState(
            activeToolCalls: calls ?? [], recentEvents: events ?? [], sessionAgents: [],
            activeSubagents: [], agentActivities: [], synthesizedSubagentIDs: [])
    }

    @Test func lastActivityUsesTheNewestToolCallOrEvent() {
        #expect(SessionAgentStateRetention.lastActivity(state(eventAt: nil)) == .distantPast)
        #expect(
            SessionAgentStateRetention.lastActivity(state(eventAt: 10, callAt: 40))
                == Date(timeIntervalSince1970: 40))
        #expect(
            SessionAgentStateRetention.lastActivity(state(eventAt: 50, callAt: 40))
                == Date(timeIntervalSince1970: 50))
    }

    @Test func pruningKeepsTheMostRecentlyActiveSessions() {
        let states = ["old": state(eventAt: 1), "mid": state(eventAt: 5), "new": state(eventAt: 9)]
        #expect(SessionAgentStateRetention.pruned(states, limit: 3) == states)
        #expect(Set(SessionAgentStateRetention.pruned(states, limit: 2).keys) == ["mid", "new"])
    }

    @Test func pruningBreaksActivityTiesDeterministically() {
        let states = ["b": state(eventAt: nil), "a": state(eventAt: nil), "c": state(eventAt: nil)]
        #expect(Set(SessionAgentStateRetention.pruned(states, limit: 2).keys) == ["a", "b"])
    }

    @Test func storeLoadAppliesRetention() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-agent-state-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let limit = SessionAgentStateRetention.maximumSessionCount
        var states: [String: SessionAgentState] = [:]
        for index in 0...limit { states["s\(index)"] = state(eventAt: TimeInterval(index)) }
        let store = SessionAgentStateStore(fileURL: url)
        store.save(states)

        let loaded = store.load()
        #expect(loaded.count == limit)
        #expect(loaded["s0"] == nil)
        #expect(loaded["s\(limit)"] != nil)
    }

    @Test func incrementalWritesKeepTheExistingArchiveReadable() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = SessionAgentStateStore(fileURL: directory.appendingPathComponent("agents.json"))
        defer { try? FileManager.default.removeItem(at: directory) }
        let unusualID = "old/\"profile\"\n☀️"
        let unchanged = state(eventAt: 7)
        let original = [unusualID: unchanged, "new": state(eventAt: 3)]
        store.save(original)
        #expect(store.load() == original)

        let writer = SessionAgentStateWriter(store: store)
        await writer.commitNow(original)
        let new = state(eventAt: 20)
        let updated = [unusualID: unchanged, "new": new]
        await writer.commitNow(updated)
        #expect(store.load() == updated)

        await writer.commitNow(["new": new])
        #expect(store.load() == updated.filter { $0.key == "new" })
    }

    @Test func staleTemporaryFilesAreRemovedAndFreshOnesKept() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-state-temp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("session-agent-state-v1.json")
        let stale = directory.appendingPathComponent("session-agent-state-v1.json.sb-old")
        let fresh = directory.appendingPathComponent("session-agent-state-v1.json.sb-new")
        let unrelated = directory.appendingPathComponent("message-pins-v1.json.sb-old")
        for file in [url, stale, fresh, unrelated] { try Data("{}".utf8).write(to: file) }
        let now = Date()
        for file in [stale, unrelated] {
            try FileManager.default.setAttributes(
                [.modificationDate: now.addingTimeInterval(-7200)], ofItemAtPath: file.path)
        }

        SessionAgentStateStore(fileURL: url).removeStaleTemporaryFiles(now: now)

        let fileManager = FileManager.default
        #expect(!fileManager.fileExists(atPath: stale.path))
        #expect(fileManager.fileExists(atPath: fresh.path))
        #expect(fileManager.fileExists(atPath: unrelated.path))
        #expect(fileManager.fileExists(atPath: url.path))
    }
}
