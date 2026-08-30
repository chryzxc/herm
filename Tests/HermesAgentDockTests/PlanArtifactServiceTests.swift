import Foundation
import Testing
@testable import HermesAgentDock

struct PlanArtifactServiceTests {
    @Test func listsMarkdownArtifactsDeterministicallyAndIgnoresOtherFiles() throws {
        let fixture = try Fixture()
        try fixture.write("one.md", contents: "# One\n")
        try fixture.write("nested/two.markdown", contents: "# Two\n")
        try fixture.write("ignored.txt", contents: "not a plan")
        let service = PlanArtifactService(projectRoot: fixture.root)

        let paths = service.list().map(\.relativePath)

        #expect(paths == ["nested/two.markdown", "one.md"])
        #expect(service.list().allSatisfy { $0.state == .available })
    }

    @Test func missingPlansDirectoryIsAnEmptyProjection() throws {
        let fixture = try Fixture(createPlans: false)
        #expect(PlanArtifactService(projectRoot: fixture.root).list().isEmpty)
    }

    @Test func rejectsTraversalAndAbsolutePaths() throws {
        let fixture = try Fixture()
        let service = PlanArtifactService(projectRoot: fixture.root)
        #expect(throws: PlanArtifactError.invalidPath) { try service.load(relativePath: "../secret.md") }
        #expect(throws: PlanArtifactError.invalidPath) { try service.load(relativePath: "/tmp/secret.md") }
        #expect(throws: PlanArtifactError.invalidPath) { try service.load(relativePath: ".hermes/plans/plan.md") }
    }

    @Test func rejectsSymlinkThatEscapesPlansDirectory() throws {
        let fixture = try Fixture()
        let outside = fixture.root.deletingLastPathComponent().appendingPathComponent("outside.md")
        try Data("# Outside\n".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: fixture.plans.appendingPathComponent("escape.md"), withDestinationURL: outside)
        #expect(throws: PlanArtifactError.unsupportedFile) { try PlanArtifactService(projectRoot: fixture.root).load(relativePath: "escape.md") }
    }

    @Test func boundsOversizedAndInvalidUtf8Artifacts() throws {
        let fixture = try Fixture()
        try fixture.writeData("large.md", data: Data(repeating: 65, count: 20))
        try fixture.writeData("invalid.md", data: Data([0xff, 0xfe]))
        let service = PlanArtifactService(projectRoot: fixture.root, maxArtifactBytes: 10)
        #expect(throws: PlanArtifactError.fileTooLarge) { try service.load(relativePath: "large.md") }
        #expect(throws: PlanArtifactError.invalidUTF8) { try service.load(relativePath: "invalid.md") }
    }

    @Test func savesCommentsAsExplicitReviewArtifactsAndDetectsStaleHash() throws {
        let fixture = try Fixture()
        try fixture.write("plan.md", contents: "# Plan\n\nDo work.\n")
        let service = PlanArtifactService(projectRoot: fixture.root)
        let document = try service.load(relativePath: "plan.md")
        let comment = PlanReviewComment(id: UUID(), planPath: document.relativePath, planSHA256: document.sha256!, anchor: "Do work", body: "Please add a test.", createdAt: Date(timeIntervalSince1970: 1))
        let reviewURL = try service.saveComment(comment)
        #expect(reviewURL.path.contains(".hermes/plans/reviews"))
        #expect(try service.comments(for: document).count == 1)
        #expect(try service.comments(for: document).first?.isStale(comparedWith: document.sha256) == false)
        try fixture.write("plan.md", contents: "# Changed\n")
        let changed = try service.load(relativePath: "plan.md")
        #expect(try service.comments(for: changed).first?.isStale(comparedWith: changed.sha256) == true)
    }

    @Test func revisionDraftAndSavePreserveCanonicalPlan() throws {
        let fixture = try Fixture()
        try fixture.write("plan.md", contents: "# Plan\n")
        let service = PlanArtifactService(projectRoot: fixture.root)
        let document = try service.load(relativePath: "plan.md")
        let original = document.contents
        let draft = service.revisionDraft(for: document, now: Date(timeIntervalSince1970: 1_700_000_000))
        let revisionURL = try service.saveRevision(draft)
        #expect(revisionURL.pathExtension == "md")
        let revisionContents = try String(contentsOf: revisionURL, encoding: .utf8)
        #expect(revisionContents.contains("parent_sha256: \(document.sha256!)"))
        #expect(try service.load(relativePath: document.relativePath).contents == original)
    }

    @Test func rejectsRevisionWriteThroughSymlinkedDirectory() throws {
        let fixture = try Fixture()
        let outside = fixture.root.deletingLastPathComponent().appendingPathComponent("revision-escape-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: fixture.plans.appendingPathComponent("revisions", isDirectory: true), withDestinationURL: outside)
        let draft = PlanRevisionDraft(relativePath: "revisions/escaped.md", parentPlan: "plan.md", parentSHA256: "hash", contents: "escaped")

        #expect(throws: PlanArtifactError.outsidePlansDirectory) {
            try PlanArtifactService(projectRoot: fixture.root).saveRevision(draft)
        }
        #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("escaped.md").path))
    }

    @Test func rejectsCommentWriteThroughSymlinkedReviewsDirectory() throws {
        let fixture = try Fixture()
        let outside = fixture.root.deletingLastPathComponent().appendingPathComponent("reviews-escape-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: fixture.plans.appendingPathComponent("reviews", isDirectory: true), withDestinationURL: outside)
        let comment = PlanReviewComment(id: UUID(), planPath: "plan.md", planSHA256: "hash", anchor: nil, body: "comment", createdAt: .now)

        #expect(throws: PlanArtifactError.outsidePlansDirectory) {
            try PlanArtifactService(projectRoot: fixture.root).saveComment(comment)
        }
        #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("plan.md").path))
    }

    private final class Fixture {
        let root: URL
        let plans: URL

        init(createPlans: Bool = true) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("dock-plan-tests-\(UUID().uuidString)", isDirectory: true)
            plans = root.appendingPathComponent(".hermes/plans", isDirectory: true)
            if createPlans { try FileManager.default.createDirectory(at: plans, withIntermediateDirectories: true) }
        }

        func write(_ path: String, contents: String) throws { try writeData(path, data: Data(contents.utf8)) }
        func writeData(_ path: String, data: Data) throws {
            let url = plans.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }

        deinit { try? FileManager.default.removeItem(at: root) }
    }
}
