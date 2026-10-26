import Foundation
import Testing

@testable import Herm

@MainActor
struct SessionBotParticipantTests {
    @Test func attributedRepliesAndCallsShareOneParticipantWithoutGuessingMentions() {
        let request = ChatMessage(role: .user, text: "Ask Archon and Sentry")
        let reply = ChatMessage(role: .hermes, text: "Review", botProfileID: "sentry", botDisplayName: "Sentry")
        let second = ChatMessage(role: .hermes, text: "Done", botProfileID: "sentry", botDisplayName: "Sentry")
        let direct = BotActivityRecord(
            id: "job", originSessionID: "session", botID: "archon", botName: "Archon", summary: "Check")
        let bots = SessionBotParticipants.collect(messages: [request, reply, second], records: [direct, direct])
        #expect(bots.map(\.id) == ["sentry", "archon"])
        #expect(bots[0].messageIDs == [reply.id, second.id])
        #expect(bots[0].requestIDs == [request.id.uuidString])
        #expect(bots[1].dispatchIDs == ["job"])
        #expect(SessionBotParticipants.collect(messages: [request]).isEmpty)
    }

    @Test func chatAttributionAndSessionLookupAgree() {
        let message = ChatMessage(role: .hermes, text: "Reply")
        #expect(SessionBotParticipants.authorID(message, activeProfileID: "archon") == "archon")
        #expect(SessionBotParticipants.collect(messages: [message], activeProfileID: "archon").first?.id == "archon")
        #expect(
            SessionBotParticipants.authorID(ChatMessage(role: .user, text: "hello"), activeProfileID: "archon") == nil)
    }

    @Test func timelineIncludesTranscriptBotsAcrossRequestsAndKeepsDelegatesSeparate() {
        let model = DockModel(initialSessionID: "participants-fixture")
        model.messages = [
            ChatMessage(role: .user, text: "Review"),
            ChatMessage(role: .hermes, text: "Checked", botProfileID: "archon", botDisplayName: "Archon"),
            ChatMessage(role: .user, text: "Check again"),
            ChatMessage(role: .hermes, text: "Approved", botProfileID: "sentry", botDisplayName: "Sentry"),
            ChatMessage(role: .hermes, text: "Also checked", botProfileID: "archon", botDisplayName: "Archon"),
        ]
        let trace = SessionTraceModel()
        trace.update(model)
        let rows = trace.turns.flatMap(\.rows)
        let crew = SessionCrewProjection(rows: rows)
        #expect(Set(crew.bots.map(\.identity)) == ["archon", "sentry"])
        #expect(crew.bots.count == 2)
        #expect(crew.bots.allSatisfy { $0.row.timing == .unavailable })
        #expect(SessionSubagentFilter.rows(rows, matching: .all).isEmpty)
        #expect(trace.turns.last?.rows.contains { $0.crewProfileID == "sentry" } == true)
    }

    @Test func subagentFiltersExcludeConfiguredBots() {
        let rows = [
            SessionTraceRow(id: "worker", kind: .agent, title: "Worker", timing: .unavailable, active: true),
            SessionTraceRow(
                id: "failure", kind: .agent, title: "Failed worker", timing: .unavailable, outcome: "Failed"),
            SessionTraceRow(
                id: "bot", kind: .agent, title: "Bot", timing: .unavailable, active: true, crewProfileID: "archon"),
        ]
        #expect(SessionSubagentFilter.rows(rows, matching: .all).map(\.id) == ["worker", "failure"])
        #expect(SessionSubagentFilter.rows(rows, matching: .running).map(\.id) == ["worker"])
        #expect(SessionSubagentFilter.rows(rows, matching: .failed).map(\.id) == ["failure"])
    }
}
