import Foundation
import Testing
@testable import Herm

struct ArtifactServiceTests {
    @Test func artifactSelectionPreservesVisibleSelectionOrFallsBackToFirst() {
        #expect(ArtifactSelectionPresentation.reconciledID(current: "b", visibleIDs: ["a", "b"]) == "b")
        #expect(ArtifactSelectionPresentation.reconciledID(current: "z", visibleIDs: ["a", "b"]) == "a")
        #expect(ArtifactSelectionPresentation.reconciledID(current: nil, visibleIDs: []) == nil)
    }

    @Test func artifactActionsExposeContextAwareLocalFileAndSessionCapabilities() {
        let file = ArtifactRecord(value: "/tmp/report.pdf", sessionID: "s1", sessionTitle: "Report", timestamp: .now)
        let link = ArtifactRecord(value: "https://example.com/report", sessionID: "missing", sessionTitle: "Report", timestamp: .now)

        let fileActions = ArtifactActionPresentation.make(record: file, hasSourceSession: true)
        #expect(fileActions.canOpen)
        #expect(fileActions.canCopy)
        #expect(fileActions.canRevealInFinder)
        #expect(fileActions.canOpenSession)

        let linkActions = ArtifactActionPresentation.make(record: link, hasSourceSession: false)
        #expect(linkActions.canOpen)
        #expect(linkActions.canCopy)
        #expect(!linkActions.canRevealInFinder)
        #expect(!linkActions.canOpenSession)
    }

    @Test func extractsImagesDocumentsAndLinksFromSessionMessages() {
        let session = HermesSession(id: "s1", title: "Quarterly report", preview: "", startedAt: nil, messageCount: 3, source: "hermes")
        let messages: [[String: Any]] = [
            ["role": "assistant", "content": "Created [report.docx](/tmp/report.docx) and ![chart](file:///tmp/chart.png) https://example.com/report"],
            ["role": "tool", "name": "docx.create", "content": "Saved to /tmp/report.docx"],
            ["role": "assistant", "content": "MEDIA: /tmp/chart.png"]
        ]

        let records = ArtifactService.extract(session: session, messages: messages).sorted { $0.label < $1.label }

        #expect(records.map(\.kind) == [.image, .link, .file])
        #expect(records.map(\.label) == ["chart.png", "report", "report.docx"])
        #expect(records.map(\.sessionTitle) == ["Quarterly report", "Quarterly report", "Quarterly report"])
    }

    @Test func matchesDesktopRulesForDeliverablesOnly() {
        let session = HermesSession(id: "s1", title: "Files", preview: "", startedAt: nil, messageCount: 5, source: "hermes")
        let messages: [[String: Any]] = [
            // Code edits and bare source paths are not deliverables.
            ["role": "assistant", "content": "Patched /tmp/app.swift and `/tmp/plan.md`", "timestamp": 100.0,
             "tool_calls": #"[{"function":{"name":"patch","arguments":"{\"path\":\"/tmp/app.swift\"}"}}]"#],
            ["role": "tool", "tool_name": "terminal", "content": #"{"output": "/tmp/unrelated.txt"}"#],
            ["role": "tool", "tool_name": "image_generate", "content": #"{"image_path": "/tmp/cat.png", "note": "/tmp/skip.pdf"}"#, "timestamp": 200.0],
            ["role": "tool", "tool_name": "text_to_speech", "content": "MEDIA:/tmp/voice", "timestamp": 250.0],
            ["role": "assistant", "content": "See [anchor](#top) and [src](./Sources/App.swift)", "timestamp": 300.0]
        ]

        let records = ArtifactService.extract(session: session, messages: messages)

        #expect(records.map(\.value) == ["/tmp/voice", "/tmp/cat.png", "/tmp/plan.md"])
        #expect(records.map(\.origin) == [.generated, .generated, .shared])
        #expect(records.map(\.kind) == [.file, .image, .file])
    }

    @Test func groupsRecordsByDay() {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let records = [0.0, 3_600, 86_400 * 1.2, 86_400 * 40].map {
            ArtifactRecord(value: "/tmp/\($0)", sessionID: "s", sessionTitle: "S", timestamp: now.addingTimeInterval(-$0))
        }
        let sections = ArtifactDaySection.group(records, now: now, calendar: calendar)
        #expect(sections.first?.title == "Today")
        #expect(sections.first?.records.count == 2)
        #expect(sections.count == 3)
    }

    @Test func filtersSearchAcrossLabelsPathsAndSessionTitles() {
        let records = [
            ArtifactRecord(value: "/tmp/report.pdf", sessionID: "s1", sessionTitle: "Quarterly report", timestamp: .now),
            ArtifactRecord(value: "https://example.com/guide", sessionID: "s2", sessionTitle: "Travel notes", timestamp: .now)
        ]

        #expect(ArtifactService.filter(records, query: "quarterly").count == 1)
        #expect(ArtifactService.filter(records, query: "guide").count == 1)
        #expect(ArtifactService.filter(records, kind: .file).count == 1)
    }
}
