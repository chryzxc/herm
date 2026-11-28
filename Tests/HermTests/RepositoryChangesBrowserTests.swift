import Combine
import Foundation
import SwiftUI
import Testing

@testable import Herm

@MainActor
struct RepositoryChangesBrowserTests {
    @Test func sourceControlViewsDoNotObserveTheChatModel() {
        let model = DockModel(initialSessionID: "source-control-selected")
        let workflow = DeveloperWorkflowModel()
        let foreignID = "source-control-background"
        let earlier = Date(timeIntervalSince1970: 1)
        model.sessions = [
            HermesSession(
                id: foreignID, profileID: nil, title: "Background", preview: "", startedAt: earlier,
                updatedAt: earlier, messageCount: 0, source: "conversation")
        ]
        let identity = WorkspaceIdentity.session(model)
        let browser = RepositoryChangesBrowser(
            model: model, sessionIdentity: identity, workflow: workflow, projectPath: nil, onRefresh: {})
        let surface = SessionSourceControlSurface(
            model: model, sessionIdentity: identity, workflow: workflow, scope: nil, onRefresh: {},
            onSelectFile: { _ in }, selectedFilePath: nil)
        var publications = 0
        let subscription = model.objectWillChange.sink { publications += 1 }
        defer { subscription.cancel() }

        let later = earlier.addingTimeInterval(1)
        model.touchSession(sessionID: foreignID, at: later)
        #expect(model.sessions.first?.lastUpdatedAt == later)
        #expect(publications > 0)
        #expect(WorkspaceIdentity.session(model) == identity)

        for view in [browser as Any, surface as Any] {
            let stored = Mirror(reflecting: view).children.first { $0.label == "model" || $0.label == "_model" }
            #expect(stored?.label == "model")
            #expect((stored?.value as? DockModel) === model)
        }
        let observedWorkflow = Mirror(reflecting: browser).children.first { $0.label == "_workflow" }
        #expect(observedWorkflow?.value is ObservedObject<DeveloperWorkflowModel>)
    }

    @Test func displayLinesDropGitPreambleAndNoNewlineMarker() {
        let patch =
            "diff --git a/x b/x\nnew file mode 100644\nindex 0..1\n--- /dev/null\n+++ b/x\n@@ -0,0 +1,2 @@\n+# Title\n-old\n\\ No newline at end of file"
        let lines = RepositoryChangesBrowser.displayLines(patch)
        #expect(lines.map(\.text) == ["@@ -0,0 +1,2 @@", "+# Title", "-old"])
        #expect(lines.map(\.kind) == [.hunk, .addition, .deletion])
        #expect(RepositoryChangesBrowser.displayLines("Binary files differ").isEmpty)
    }

    @Test func expandedDiffsKeepUnchangedRowsAndBoundConcurrentReads() async throws {
        var started: [String] = []
        var active = 0
        var peak = 0
        let reads = RepositoryInlineDiffReads { _, file in
            started.append(file.id)
            active += 1
            peak = max(peak, active)
            defer { active -= 1 }
            do { try await Task.sleep(for: .milliseconds(25)) } catch { return nil }
            return .init(path: file.path, text: "patch", isTruncated: false, isStaged: file.isStaged)
        }
        let files = ["a", "b", "c", "d"].map {
            RepositoryFileChange(path: $0, status: .modified, isStaged: false, renameSource: nil)
        }
        let changes = RepositoryChangeSnapshot(
            repositoryID: "repo", headRevision: "head", branch: "main", files: files, refreshedAt: .now)
        var identities = Dictionary(uniqueKeysWithValues: files.map { ($0.id, "original") })
        func input(_ fingerprint: String, _ expanded: [RepositoryFileChange]) -> RepositoryInlineDiffReads.Input {
            .init(
                path: "/repo", changes: changes,
                revision: .init(fingerprint: fingerprint, fileIdentities: identities),
                expandedIDs: Set(expanded.map(\.id)))
        }
        func settle() async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while reads.states.values.contains(.loading), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(!reads.states.values.contains(.loading))
        }
        reads.update(input("first", files))
        try await settle()
        #expect(peak == 2)
        #expect(Set(started) == Set(files.map(\.id)))
        let unaffected = reads.states[files[1].id]

        identities[files[0].id] = "changed"
        reads.update(input("second", files))
        #expect(reads.states[files[1].id] == unaffected)
        try await settle()
        #expect(Array(started.dropFirst(files.count)) == [files[0].id])
        reads.update(nil)
        #expect(reads.states.isEmpty)
    }
}
