import Foundation
import Testing

@testable import Herm

@MainActor
private final class ArtifactProgressProbe {
    var reads = 0
    var first: ArtifactIndexLoader.SessionProgress?
    var second: ArtifactIndexLoader.SessionProgress?
    var resume: CheckedContinuation<Void, Never>?
}

struct ArtifactServiceTests {
    @Test func artifactSelectionPreservesVisibleSelectionOrFallsBackToFirst() {
        #expect(ArtifactSelectionPresentation.reconciledID(current: "b", visibleIDs: ["a", "b"]) == "b")
        #expect(ArtifactSelectionPresentation.reconciledID(current: "z", visibleIDs: ["a", "b"]) == "a")
        #expect(ArtifactSelectionPresentation.reconciledID(current: nil, visibleIDs: []) == nil)
    }

    @Test func artifactActionsExposeContextAwareLocalFileAndSessionCapabilities() {
        let file = ArtifactRecord(value: "/tmp/report.pdf", sessionID: "s1", sessionTitle: "Report", timestamp: .now)
        let link = ArtifactRecord(
            value: "https://example.com/report", sessionID: "missing", sessionTitle: "Report", timestamp: .now)

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
        let session = HermesSession(
            id: "s1", title: "Quarterly report", preview: "", startedAt: nil, messageCount: 3, source: "hermes")
        let messages: [[String: Any]] = [
            [
                "role": "assistant",
                "content":
                    "Created [report.docx](/tmp/report.docx) and ![chart](file:///tmp/chart.png) https://example.com/report",
            ],
            ["role": "tool", "name": "docx.create", "content": "Saved to /tmp/report.docx"],
            ["role": "assistant", "content": "MEDIA: /tmp/chart.png"],
        ]

        let records = ArtifactService.extract(session: session, messages: messages).sorted { $0.label < $1.label }

        // Match Desktop: assistant links are included alongside document and image outputs.
        #expect(records.map(\.kind) == [.image, .link, .file])
        #expect(records.map(\.label) == ["chart.png", "report", "report.docx"])
        #expect(records.allSatisfy { $0.sessionTitle == "Quarterly report" })
    }

    @Test func matchesDesktopRulesForDeliverablesOnly() {
        let session = HermesSession(
            id: "s1", title: "Files", preview: "", startedAt: nil, messageCount: 5, source: "hermes")
        let messages: [[String: Any]] = [
            // Code edits and bare source paths are not deliverables.
            [
                "role": "assistant", "content": "Patched /tmp/app.swift and `/tmp/plan.md`", "timestamp": 100.0,
                "tool_calls": #"[{"function":{"name":"patch","arguments":"{\"path\":\"/tmp/app.swift\"}"}}]"#,
            ],
            [
                "role": "tool", "tool_name": "terminal", "content": #"{"output": "/tmp/unrelated.txt"}"#,
                "timestamp": 150.0,
            ],
            [
                "role": "tool", "tool_name": "image_generate",
                "content": #"{"image_path": "/tmp/cat.png", "note": "/tmp/skip.swift"}"#, "timestamp": 200.0,
            ],
            ["role": "tool", "tool_name": "text_to_speech", "content": "MEDIA:/tmp/voice", "timestamp": 250.0],
            ["role": "assistant", "content": "See [anchor](#top) and [src](./Sources/App.swift)", "timestamp": 300.0],
        ]

        let records = ArtifactService.extract(session: session, messages: messages)

        #expect(records.map(\.value) == ["/tmp/voice", "/tmp/cat.png", "/tmp/unrelated.txt", "/tmp/plan.md"])
        #expect(records.map(\.origin) == [.generated, .generated, .generated, .shared])
        #expect(records.map(\.kind) == [.file, .image, .file, .file])
    }

    @Test func groupsRecordsByDay() {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let records = [0.0, 3_600, 86_400 * 1.2, 86_400 * 40].map {
            ArtifactRecord(
                value: "/tmp/\($0)", sessionID: "s", sessionTitle: "S", timestamp: now.addingTimeInterval(-$0))
        }
        let sections = ArtifactDaySection.group(records, now: now, calendar: calendar)
        #expect(sections.first?.title == "Today")
        #expect(sections.first?.records.count == 2)
        #expect(sections.count == 3)
    }

    @Test func filtersSearchAcrossLabelsPathsAndSessionTitles() {
        let records = [
            ArtifactRecord(
                value: "/tmp/report.pdf", sessionID: "s1", sessionTitle: "Quarterly report", timestamp: .now),
            ArtifactRecord(
                value: "https://example.com/guide", sessionID: "s2", sessionTitle: "Travel notes", timestamp: .now),
        ]

        #expect(ArtifactService.filter(records, query: "quarterly").count == 1)
        #expect(ArtifactService.filter(records, query: "guide").count == 1)
        #expect(ArtifactService.filter(records, kind: .file).count == 1)
    }
}

@MainActor
struct ArtifactIndexLoaderTests {
    private let session = HermesSession(
        id: "s", profileID: "work", title: "Archive", preview: "", startedAt: nil,
        updatedAt: Date(timeIntervalSince1970: 100), messageCount: 650, source: "hermes")

    @Test func sharedProgressReplaysToLateConsumersAndFailureDoesNotCache() async throws {
        let index = ArtifactIndexStore()
        let owner = NSObject()
        let probe = ArtifactProgressProbe()
        let read: @MainActor @Sendable (HermesSession, Int) async throws -> [String: Any] = { _, offset in
            probe.reads += 1
            if offset > 0 {
                await withCheckedContinuation { probe.resume = $0 }
                throw HermesGateway.GatewayError.malformedResponse
            }
            return [
                "messages": [["role": "assistant", "content": "MEDIA: /tmp/first.png"]], "pagination": ["limit": 1],
            ]
        }
        let session = session
        let ownerID = ObjectIdentifier(owner)
        let first = Task {
            await ArtifactIndexLoader.load(
                sessions: [session], index: index, owner: ownerID,
                onProgress: { probe.first = $0 }, messages: read)
        }
        defer {
            probe.resume?.resume()
            first.cancel()
        }
        for _ in 0..<200 where probe.resume == nil { try await Task.sleep(for: .milliseconds(5)) }
        _ = try #require(probe.resume)
        #expect(probe.first?.records.map(\.value) == ["/tmp/first.png"])
        let second = Task {
            await ArtifactIndexLoader.load(
                sessions: [session], index: index, owner: ownerID,
                onProgress: { probe.second = $0 }, messages: read)
        }
        defer { second.cancel() }
        for _ in 0..<200 where probe.second == nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(try #require(probe.second).pagesRead == 1)
        first.cancel()
        try await Task.sleep(for: .milliseconds(20))
        probe.resume?.resume()
        probe.resume = nil
        #expect(await second.value.first?.error != nil)
        _ = await first.value
        let readsBeforeRetry = probe.reads
        let retry = await ArtifactIndexLoader.load(sessions: [session], index: index, owner: ownerID) { _, _ in
            probe.reads += 1
            return ["data": []]
        }
        #expect(probe.reads == readsBeforeRetry + 1)
        #expect(retry.first?.error == nil)
    }

    @Test func publishesCompletedSessionsBeforeStartingQueuedReads() async {
        let sessions = (0..<5).map {
            HermesSession(
                id: String($0), title: "Outputs", preview: "", startedAt: nil,
                messageCount: 1, source: "test")
        }
        var published: [String] = []
        let results = await ArtifactIndexLoader.load(
            sessions: sessions,
            onSession: { result in
                published.append(result.sessionID)
            },
            messages: { session, _ in
                if session.id == "4" { #expect(!published.isEmpty) }
                return ["data": [["role": "assistant", "content": "MEDIA: /tmp/output.pdf"]]]
            })
        #expect(Set(published) == Set(sessions.map(\.id)))
        #expect(results.count == 5)
    }

    @Test func readsEveryMessagePageAndKeepsFirstMention() async {
        var offsets: [Int] = []
        let results = await ArtifactIndexLoader.load(sessions: [session]) { _, offset in
            offsets.append(offset)
            let messages: [[String: Any]] = (offset..<min(offset + 100, 650)).map { index in
                [
                    "role": "assistant", "content": "MEDIA: /tmp/\(index == 600 ? 0 : index).png",
                    "timestamp": Double(index + 1),
                ]
            }
            return ["messages": messages, "pagination": ["limit": 100]]
        }
        #expect(offsets == [0, 100, 200, 300, 400, 500, 600])
        #expect(results.first?.records.count == 649)
        #expect(results.first?.records.first { $0.value == "/tmp/0.png" }?.timestamp == Date(timeIntervalSince1970: 1))
        #expect(results.first?.records.contains { $0.value == "/tmp/649.png" } == true)
        #expect(results.first?.records.allSatisfy { $0.profileID == "work" } == true)
    }

    @Test func unchangedSessionsReuseOnlyArtifactRecordsWithoutReadingTranscripts() async {
        let cachedRecord = ArtifactRecord(
            value: "/tmp/cached.pdf", sessionID: session.id,
            sessionTitle: session.displayTitle, timestamp: .now, profileID: session.profileID)
        let cache = [session.scopedID: ArtifactIndexLoader.CachedSession(session: session, records: [cachedRecord])]
        var reads = 0
        let results = await ArtifactIndexLoader.load(sessions: [session], cache: cache) { _, _ in
            reads += 1
            return ["data": []]
        }
        #expect(reads == 0)
        #expect(results.first?.records == [cachedRecord])

        let changedSessions = [
            HermesSession(
                id: "s", profileID: "work", title: "Archive", preview: "", startedAt: nil,
                updatedAt: Date(timeIntervalSince1970: 101), messageCount: 650, source: "hermes"),
            HermesSession(
                id: "s", profileID: "work", title: "Archive", preview: "", startedAt: nil,
                updatedAt: Date(timeIntervalSince1970: 100), messageCount: 651, source: "hermes"),
            HermesSession(
                id: "s", profileID: "work", title: "Renamed", preview: "", startedAt: nil,
                updatedAt: Date(timeIntervalSince1970: 100), messageCount: 650, source: "hermes"),
            HermesSession(
                id: "s", profileID: "personal", title: "Archive", preview: "", startedAt: nil,
                updatedAt: Date(timeIntervalSince1970: 100), messageCount: 650, source: "hermes"),
        ]
        for changed in changedSessions {
            let refreshed = await ArtifactIndexLoader.load(sessions: [changed], cache: cache) { _, _ in
                reads += 1
                return ["data": []]
            }
            #expect(refreshed.first?.records.isEmpty == true)
        }
        #expect(reads == 4)
    }

    @Test func laterPageFailureDoesNotPublishIncompleteSession() async {
        let results = await ArtifactIndexLoader.load(sessions: [session]) { _, offset in
            if offset > 0 { throw HermesGateway.GatewayError.malformedResponse }
            return [
                "messages": [["role": "assistant", "content": "MEDIA: /tmp/first.png"]], "pagination": ["limit": 1],
            ]
        }
        #expect(results.first?.error != nil)
        #expect(results.first?.records.isEmpty == true)
    }

    @Test func legacyTranscriptWithoutPaginationStopsAfterOneRead() async {
        var reads = 0
        let results = await ArtifactIndexLoader.load(sessions: [session]) { _, _ in
            reads += 1
            return ["data": [["role": "assistant", "content": "MEDIA: /tmp/legacy.pdf"]]]
        }
        #expect(reads == 1)
        #expect(results.first?.records.count == 1)
    }

    @Test func malformedTranscriptIsAFailureRatherThanAnEmptyArchive() async {
        let results = await ArtifactIndexLoader.load(sessions: [session]) { _, _ in [:] }
        #expect(results.first?.error != nil)
    }
}

extension ArtifactServiceTests {
    @Test func extractsDesktopTerminalProducerAndEncodedMediaOutputs() {
        let session = HermesSession(
            id: "s", title: "Outputs", preview: "", startedAt: nil, messageCount: 5, source: "hermes")
        let messages: [[String: Any]] = [
            [
                "role": "assistant",
                "content": "[report](#media:%2Ftmp%2Freport%20final.pdf) and https://example.com/result",
            ],
            [
                "role": "tool", "name": "terminal",
                "content": ["outputs": [["stdout": "Saved /tmp/chart.png and MEDIA: /tmp/delivery"]]],
            ],
            ["role": "tool", "name": "document_create", "content": "Saved /tmp/summary.docx"],
            ["role": "tool", "name": "browser_vision", "content": "Screenshot path: /tmp/screenshot.png"],
            ["role": "user", "content": "MEDIA: /tmp/input.png"],
        ]
        let values = Set(ArtifactService.extract(session: session, messages: messages).map(\.value))
        #expect(
            values == [
                "/tmp/report final.pdf", "https://example.com/result", "/tmp/chart.png", "/tmp/delivery",
                "/tmp/summary.docx", "/tmp/screenshot.png",
            ])
    }

    @Test func ignoresPackageDownloadsButKeepsExplicitDeliveries() {
        let session = HermesSession(
            id: "s", title: "Outputs", preview: "", startedAt: nil, messageCount: 1, source: "hermes")
        let records = ArtifactService.extract(
            session: session,
            messages: [
                [
                    "role": "tool", "name": "terminal",
                    "content":
                        "Downloading https://example.com/packages/a/dependency.zip /home/test/.cache/pip/cache.json MEDIA: /tmp/delivered.whl",
                ]
            ])
        #expect(records.map(\.value) == ["/tmp/delivered.whl"])
    }

    @Test func profileOwnershipKeepsMatchingSessionPathsDistinct() {
        let messages: [[String: Any]] = [["role": "assistant", "content": "MEDIA: /tmp/chart.png"]]
        let records = ["work", "personal"].flatMap { profile in
            ArtifactService.extract(
                session: HermesSession(
                    id: "s", profileID: profile, title: profile, preview: "", startedAt: nil, messageCount: 1,
                    source: "hermes"), messages: messages)
        }
        #expect(Set(records.map(\.id)).count == 2)
    }
}
