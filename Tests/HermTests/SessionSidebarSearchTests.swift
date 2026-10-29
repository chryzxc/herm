import Foundation
import Testing

@testable import Herm

struct SessionSidebarSearchTests {
    private func session(_ id: String, title: String, preview: String = "", time: Double = 0) -> HermesSession {
        HermesSession(
            id: id, title: title, preview: preview, startedAt: nil,
            updatedAt: Date(timeIntervalSince1970: time), messageCount: 1, source: "conversation")
    }

    @Test func searchesTitlesPreviewsAndProjectsIgnoringCaseAndSurroundingWhitespace() {
        let sessions = [
            session("title", title: "Deploy Herm"),
            session("preview", title: "Planning", preview: "Check DEPLOY logs"),
            session("project", title: "Release"),
            session("other", title: "Unrelated"),
        ]
        let matches = SessionSidebarSearch.sessions(
            matching: "  deploy\n", in: sessions, projects: ["project": "deploy-tools"])
        #expect(Set(matches.map(\.id)) == ["title", "preview", "project"])
        #expect(SessionSidebarSearch.sessions(matching: "missing", in: sessions, projects: [:]).isEmpty)
    }

    @Test func includesMatchesBeyondRecentLimitAndDeduplicatesPinsInNewestOrder() {
        let sessions = (0..<15).map { session("\($0)", title: "Chat \($0)", time: Double($0)) }
        let matches = SessionSidebarSearch.sessions(
            matching: "chat", in: sessions + [sessions[0]], projects: [:])
        #expect(matches.count == 15)
        #expect(matches.first?.id == "14")
        #expect(matches.last?.id == "0")
        #expect(SessionSidebarSearch.sessions(matching: " \n", in: sessions, projects: [:]).count == 15)
    }
}
