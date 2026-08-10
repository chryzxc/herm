import Combine
import Foundation
import Testing
@testable import HermesAgentDock

struct CommandCenterModelsTests {
    @Test func missionPrioritizesAttentionAndDoesNotUpgradeTargetedEvidence() {
        let approval = attention("approval", .approval)
        let reminder = attention("reminder", .reminder)
        let snapshot = MissionControlSnapshotBuilder.make(
            sessionTitle: "Work", repository: repository(changed: 0), model: "model", context: nil,
            attention: [reminder, approval], sessions: [], activeSessionID: nil, agents: [], processes: [], backgroundTasks: [], activities: [], cronRuns: [],
            verification: VerificationSummary(state: .passed, evidence: VerificationEvidenceSummary(command: nil, canonicalCommand: nil, kind: nil, scope: "targeted", status: "passed", exitCode: 0, outputSummary: nil))
        )
        #expect(snapshot.needsMe.first?.id == "attention:approval")
        #expect(snapshot.readiness.state == .needsReview)
    }

    @Test func missionBlocksFailuresAndRequiresCleanRepositoryForReady() {
        let failed = MissionControlSnapshotBuilder.make(sessionTitle: nil, repository: repository(changed: 0), model: nil, context: nil, attention: [], sessions: [], activeSessionID: nil, agents: [], processes: [], backgroundTasks: [], activities: [], cronRuns: [], verification: VerificationSummary(state: .failed, evidence: nil))
        #expect(failed.readiness.state == .blocked)
        let ready = MissionControlSnapshotBuilder.make(sessionTitle: nil, repository: repository(changed: 0), model: nil, context: nil, attention: [], sessions: [], activeSessionID: nil, agents: [], processes: [], backgroundTasks: [], activities: [], cronRuns: [], verification: VerificationSummary(state: .passed, evidence: VerificationEvidenceSummary(command: nil, canonicalCommand: nil, kind: nil, scope: "repository", status: "passed", exitCode: 0, outputSummary: nil)))
        #expect(ready.readiness.state == .ready)
    }

    @Test func paletteRanksAvailablePrefixMatchAndRetainsUnavailableActions() {
        let descriptors = DockActionRegistry.make(repositoryAvailable: false, isWorking: false)
        let results = DockActionRegistry.search("preflight", descriptors: descriptors, recentIDs: [])
        #expect(results.first?.title == "Preflight")
        #expect(results.first?.isAvailable == false)
        let refresh = DockActionRegistry.search("refresh", descriptors: descriptors, recentIDs: [])
        #expect(refresh.first?.action == .refresh)
    }

    @Test func porcelainParserSeparatesStagedUnstagedAndUntrackedFiles() {
        let files = RepositoryService.parsePorcelainV1("M  staged.swift\0 M worktree.swift\0?? new.swift\0")
        #expect(files.count == 3)
        #expect(files.contains { $0.path == "staged.swift" && $0.isStaged })
        #expect(files.contains { $0.path == "worktree.swift" && !$0.isStaged })
        #expect(files.contains { $0.path == "new.swift" && $0.status == .untracked })
    }

    @Test func diffBoundReportsTruncation() {
        let input = Array(repeating: "line", count: 1_000).joined(separator: "\n")
        let result = RepositoryService.boundDiff(input)
        #expect(result.isTruncated)
        #expect(result.text.split(separator: "\n").count <= 900)
    }

    @Test func untrackedFilesUseReadOnlyNoIndexDiffAndAcceptDifferenceExitCode() {
        let file = RepositoryFileChange(path: "Sources/New.swift", status: .untracked, isStaged: false, renameSource: nil)

        let command = RepositoryService.diffCommand(for: file)

        #expect(command.arguments == ["diff", "--no-index", "--no-ext-diff", "--unified=3", "--", "/dev/null", "Sources/New.swift"])
        #expect(command.successCodes == [0, 1])
    }

    @Test func localDiffAuditFlagsAddedPreCommitSignalsWithoutReturningSecretText() {
        let diff = RepositoryDiff(path: "Sources/App.swift", text: """
        diff --git a/Sources/App.swift b/Sources/App.swift
        --- a/Sources/App.swift
        +++ b/Sources/App.swift
        @@ -8,2 +8,5 @@
         let stable = true
        +let api_key = "do-not-display"
        +print("debug")
        +// TODO: remove fallback
        +<<<<<<< HEAD
        """, isTruncated: false, isStaged: false)

        let findings = RepositoryDiffAuditor.audit(diff)

        #expect(findings.map(\.ruleID) == ["credential-assignment", "debug-statement", "unfinished-marker", "conflict-marker"])
        #expect(findings.map(\.line) == [9, 10, 11, 12])
        #expect(!String(describing: findings).contains("do-not-display"))
    }

    @Test func localDiffAuditIgnoresRemovedSignalsAndFindsBareExcept() {
        let diff = RepositoryDiff(path: "worker.py", text: """
        @@ -4,3 +4,3 @@
        -print("old debug")
        +except:
             pass
        """, isTruncated: false, isStaged: true)

        let findings = RepositoryDiffAuditor.audit(diff)

        #expect(findings.count == 1)
        #expect(findings.first?.ruleID == "bare-except")
        #expect(findings.first?.line == 4)
    }

    @Test func contextPressureUsesOnlyHermesReportedThresholds() {
        #expect(SessionContextPressure.make(percent: nil) == .unavailable)
        #expect(SessionContextPressure.make(percent: 79.99) == .normal)
        #expect(SessionContextPressure.make(percent: 80) == .warning)
        #expect(SessionContextPressure.make(percent: 89.99) == .warning)
        #expect(SessionContextPressure.make(percent: 90) == .critical)
    }

    @Test func reviewBaselinePersistsOnlyStableReferences() {
        let baseline = RepositoryReviewBaseline(repositoryID: "repo-id", headRevision: "abc", fingerprint: "fingerprint", acknowledgedFindingIDs: Array(repeating: "finding", count: 600))
        let restored = RepositoryReviewBaseline(dictionary: baseline.dictionary)

        #expect(restored?.repositoryID == "repo-id")
        #expect(restored?.headRevision == "abc")
        #expect(restored?.acknowledgedFindingIDs.count == 500)
        #expect(!baseline.dictionary.keys.contains("diff"))
        #expect(!baseline.dictionary.keys.contains("output"))
    }

    @Test func reviewBaselineIsStaleForAnyFingerprintChangeAndRequiresCompleteCoverage() {
        let complete = RepositoryReviewBaseline(repositoryID: "repo", headRevision: "abc", fingerprint: "one", acknowledgedFindingIDs: [], completeness: .complete)
        #expect(RepositoryReviewBaselineStatus.make(baseline: complete, fingerprint: "one") == .current(complete.reviewedAt))
        #expect(RepositoryReviewBaselineStatus.make(baseline: complete, fingerprint: "two") == .stale(complete.reviewedAt))

        let legacy = RepositoryReviewBaseline(repositoryID: "repo", headRevision: "abc", fingerprint: "one", acknowledgedFindingIDs: [])
        #expect(RepositoryReviewBaselineStatus.make(baseline: legacy, fingerprint: "one") == .partial(legacy.reviewedAt))
        #expect(RepositoryReviewBaselineStatus.make(baseline: legacy, fingerprint: "two") == .stale(legacy.reviewedAt))
    }

    @Test func worktreeInspectionConcurrencyHasAnExplicitBound() {
        #expect(RepositoryService.maxConcurrentWorktreeInspections == 8)
    }

    @MainActor
    @Test func markingAReviewFilePublishesAndAllowsPartialAcknowledgement() {
        let change = RepositoryFileChange(path: "Sources/App.swift", status: .modified, isStaged: false, renameSource: nil)
        let file = RepositoryReviewFile(change: change, findings: [], isTruncated: true, isBinary: false, isReadable: true, contentIdentity: "hash")
        let review = RepositoryReviewSnapshot(repositoryID: "repo", headRevision: "abc", fingerprint: "fingerprint", files: [file], completeness: .partial, refreshedAt: .now, omittedFileCount: 0)
        let model = DeveloperWorkflowModel()
        var publications = 0
        let cancellable = model.objectWillChange.sink { publications += 1 }

        model.toggleReviewed(change)

        #expect(publications == 1)
        #expect(model.reviewedFileIDs == Set([change.id]))
        #expect(DeveloperWorkflowModel.canSaveBaseline(review: review, reviewedFileIDs: model.reviewedFileIDs))
        _ = cancellable
    }

    private func repository(changed: Int) -> RepositorySnapshot {
        RepositorySnapshot(path: "/work/project", branch: "main", changedFiles: changed, latestCommit: "abc test", isGitRepository: true)
    }

    private func attention(_ id: String, _ kind: AttentionKind) -> AttentionItem {
        AttentionItem(id: id, reference: ControlReference(source: .hermesSession, sourceID: id), kind: kind, title: id, detail: id, createdAt: .now, state: .open, actions: [])
    }
}
