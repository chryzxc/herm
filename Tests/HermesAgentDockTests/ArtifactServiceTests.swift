import Foundation
import Testing
@testable import HermesAgentDock

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

        let records = ArtifactService.extract(session: session, messages: messages)

        #expect(records.map(\.kind) == [.image, .link, .file])
        #expect(records.map(\.label) == ["chart.png", "report", "report.docx"])
        #expect(records.map(\.sessionTitle) == ["Quarterly report", "Quarterly report", "Quarterly report"])
    }

    @Test func deduplicatesSameArtifactWithinSessionAndClassifiesDocumentExtensions() {
        let session = HermesSession(id: "s1", title: "Files", preview: "", startedAt: nil, messageCount: 2, source: "hermes")
        let messages: [[String: Any]] = [
            ["role": "assistant", "content": "Written /tmp/report.xlsx and /tmp/report.xlsx"],
            ["role": "tool", "name": "files_written", "content": ["path": "/tmp/report.xlsx"]]
        ]

        let records = ArtifactService.extract(session: session, messages: messages)

        #expect(records.count == 1)
        #expect(records.first?.kind == .file)
        #expect(records.first?.value == "/tmp/report.xlsx")
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
