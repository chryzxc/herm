import Foundation
import Testing

@testable import Herm

struct ReviewGuideSourceTests {
    @Test func guideDestinationRetainsTheCapturedSessionProfileIncludingDefault() {
        for profile in [nil, "original"] as [String?] {
            let session = HermesSession(
                id: "source", profileID: profile, title: "Source conversation", preview: "",
                startedAt: nil, messageCount: 0, source: "herm")
            let destination = ReviewGuideCoordinator.ownerDestination(session: session, fallbackProfileID: "other")
            #expect(destination.profileID == profile)
            #expect(destination.sessionID == "source")
        }
        let draft = ReviewGuideCoordinator.ownerDestination(session: nil, fallbackProfileID: "draft-owner")
        #expect(draft.profileID == "draft-owner")
        #expect(draft.sessionID == nil)
    }

    @Test func boundedInputAndReferencesShareExactlyTheCapturedPatch() {
        let first = DiffDocument(path: "first.swift", patch: "@@ -1 +1 @@\n-old\n+new")
        let second = DiffDocument(path: "second.swift", patch: "@@ -1 +1 @@\n-before\n+after")
        let source = ReviewGuideSource.capture([first, second], partial: false, maximumBytes: 60)
        #expect(source.partial)
        #expect(source.text.utf8.count <= 60)
        #expect(source.documents.map(\.path) == ["first.swift"])
        #expect(
            ReviewGuideReferences.valid(in: "first.swift:1 and second.swift:1", documents: source.documents).map(\.path)
                == ["first.swift"])
    }
    @Test func onlyLoadedFileRangesResolveAndInvalidReferencesStayUnresolved() {
        let document = DiffDocument(path: "Sources/Example.swift", patch: "@@ -4,2 +7,2 @@\n-old\n+new\n unchanged")
        let text = "Sources/Example.swift:7–8 Sources/Example.swift:99 Sources/Example.swift:7–99 Other.swift:7"
        let references = ReviewGuideReferences.valid(in: text, documents: [document])
        #expect(references.count == 1)
        #expect(references.first?.side == "RIGHT")
        #expect(references.first?.firstLine == 7)
        #expect(references.first?.lastLine == 8)
    }
}
