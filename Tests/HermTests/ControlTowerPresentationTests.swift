import Foundation
import Testing
@testable import Herm

struct ControlTowerPresentationTests {
    @Test func attentionRowsPrioritizeApprovalAndKeepSessionIdentity() {
        let oldFailure = AttentionItem(id: "failure", reference: ControlReference(source: .hermesSession, sourceID: "s1", sessionID: "s1"), kind: .failure, title: "Failure", detail: "failed", createdAt: Date(timeIntervalSince1970: 1), state: .open, actions: [.open])
        let approval = AttentionItem(id: "approval", reference: ControlReference(source: .hermesApproval, sourceID: "a", sessionID: "s2"), kind: .approval, title: "Approval", detail: "needs decision", createdAt: Date(timeIntervalSince1970: 2), state: .open, actions: [.approve])
        let rows = AttentionPresentation.rows([oldFailure, approval])
        #expect(rows.map(\.id) == ["approval", "failure"])
        #expect(rows.first?.sourceLabel == "SESSION")
        #expect(rows.first?.item.reference.sessionID == "s2")
    }

    @Test func dismissedAttentionIsHistoryAndNotActionable() {
        let item = AttentionItem(id: "done", reference: ControlReference(source: .hermesSession, sourceID: "s"), kind: .approval, title: "Done", detail: "", createdAt: .now, state: .dismissed, actions: [.approve])
        let row = AttentionPresentation.rows([item]).first!
        #expect(row.group == .history)
        #expect(row.isActionable == false)
    }

    @Test func verificationDistinguishesTargetedStaleAndBlockedEvidence() {
        let evidence = VerificationEvidenceSummary(command: "swift test", canonicalCommand: "swift test", kind: "test", scope: "targeted", status: "passed", exitCode: 0, outputSummary: nil)
        let passed = VerificationSummary(state: .passed, evidence: evidence)
        #expect(VerificationEvidencePresentation.make(verification: passed, currentFingerprint: "a", evidenceFingerprint: "a", openFailureCount: 0, repositoryDirty: false).state == .targetedOnly)
        #expect(VerificationEvidencePresentation.make(verification: passed, currentFingerprint: "b", evidenceFingerprint: "a", openFailureCount: 0, repositoryDirty: false).state == .stale)
        #expect(VerificationEvidencePresentation.make(verification: passed, currentFingerprint: "a", evidenceFingerprint: "a", openFailureCount: 1, repositoryDirty: false).state == .blocked)
    }

    @Test func passedEvidenceRequiresObservedZeroExitCodeBeforeCurrent() {
        for exitCode in [Int?(nil), 1] {
            let evidence = VerificationEvidenceSummary(command: "swift test", canonicalCommand: "swift test", kind: "test", scope: "repository", status: "passed", exitCode: exitCode, outputSummary: nil)
            let result = VerificationEvidencePresentation.make(
                verification: VerificationSummary(state: .passed, evidence: evidence),
                currentFingerprint: "same", evidenceFingerprint: "same", openFailureCount: 0, repositoryDirty: false
            )

            #expect(result.state == .unavailable)
            #expect(result.nextAction == "Obtain a fresh observed verification result.")
        }
    }

    @Test func invalidParsedStaleReasonWinsWithSafeFallbackAction() {
        let evidence = VerificationEvidenceSummary(command: "swift test", canonicalCommand: "swift test", kind: "test", scope: "repository", status: "passed", exitCode: 0, outputSummary: nil, hasInvalidStaleReason: true)
        let result = VerificationEvidencePresentation.make(
            verification: VerificationSummary(state: .passed, evidence: evidence),
            currentFingerprint: "same", evidenceFingerprint: "same", openFailureCount: 0, repositoryDirty: false
        )

        #expect(result.state == .stale)
        #expect(result.staleReason == nil)
        #expect(result.nextAction == "Refresh verification against the current repository state.")
    }

    @Test func verificationClassifiesCommitAndDiffMismatchesAsStaleAndPreservesReason() {
        let evidence = VerificationEvidenceSummary(command: "swift test", canonicalCommand: "swift test", kind: "test", scope: "repository", status: "passed", exitCode: 0, outputSummary: nil, adapter: "swiftpm", capturedAt: nil, repositoryIdentity: "repo", commitFingerprint: "old-commit", targetFingerprint: "target", diffFingerprint: "old-diff", rulesScopeDetail: "all tests", staleReason: "superseded")
        let result = VerificationEvidencePresentation.make(verification: VerificationSummary(state: .passed, evidence: evidence), currentFingerprint: nil, evidenceFingerprint: nil, currentRepositoryIdentity: "repo", currentCommitFingerprint: "new-commit", currentTargetFingerprint: "target", currentDiffFingerprint: "new-diff", openFailureCount: 0, repositoryDirty: false)
        #expect(result.state == .stale)
        #expect(result.staleReason == "superseded")
        #expect(result.adapter == "swiftpm")
        #expect(result.rulesScopeDetail == "all tests")
    }

    @Test func stalePresentationBoundsMetadataAndUsesSafeFallbackAction() {
        let evidence = VerificationEvidenceSummary(
            command: "swift test", canonicalCommand: "swift test", kind: "test", scope: "repository", status: "passed", exitCode: 0, outputSummary: nil,
            adapter: String(repeating: "x", count: 161), capturedAt: nil, repositoryIdentity: nil,
            commitFingerprint: nil, targetFingerprint: nil, diffFingerprint: nil, rulesScopeDetail: nil,
            staleReason: String(repeating: "unsafe stale reason ", count: 20)
        )
        let result = VerificationEvidencePresentation.make(
            verification: VerificationSummary(state: .passed, evidence: evidence),
            currentFingerprint: "new", evidenceFingerprint: "old", openFailureCount: 0, repositoryDirty: false
        )

        #expect(result.state == .stale)
        #expect(result.adapter == nil)
        #expect(result.staleReason == nil)
        #expect(result.nextAction == "Refresh verification against the current repository state.")
        #expect(result.nextAction.count <= 160)
    }

    @Test func directUnsafeStaleReasonIsNormalizedAndWinsWithMatchingFingerprints() {
        let evidence = VerificationEvidenceSummary(
            command: "swift test", canonicalCommand: "swift test", kind: "test", scope: "repository", status: "passed", exitCode: 0, outputSummary: nil,
            targetFingerprint: "target", diffFingerprint: "diff",
            staleReason: String(repeating: "unsafe stale reason ", count: 20)
        )
        let result = VerificationEvidencePresentation.make(
            verification: VerificationSummary(state: .passed, evidence: evidence),
            currentFingerprint: "same", evidenceFingerprint: "same",
            currentTargetFingerprint: "target", currentDiffFingerprint: "diff",
            openFailureCount: 0, repositoryDirty: false
        )

        #expect(evidence.staleReason == nil)
        #expect(evidence.hasInvalidStaleReason == true)
        #expect(result.state == .stale)
        #expect(result.staleReason == nil)
        #expect(result.nextAction == "Refresh verification against the current repository state.")
    }

    @Test func automationHealthNeverInfersSuccessFromMissingHistory() {
        let job = CronSummary(id: "job", name: "Nightly", schedule: "0 0 * * *", enabled: true, nextRun: "tomorrow")
        let unknown = AutomationHealthPresentation.make(job: job, runs: [], capabilityAvailable: true, mcpErrorObserved: false)
        #expect(unknown.state == .unknown)
        let run = CronRunSummary(id: "run", status: "succeeded", jobID: "job", source: nil, claimedAt: nil, error: nil)
        #expect(AutomationHealthPresentation.make(job: job, runs: [run], capabilityAvailable: true, mcpErrorObserved: false).state == .healthy)
    }

    @Test func operationsRequireObservedStateAndDoNotInventModel() {
        let agent = HermesSubagent(id: "a", goal: "work", status: "completed", model: nil)
        let row = AgentOperationsPresentation.rows(agents: [agent]).first!
        #expect(row.state == .completed)
        #expect(row.model == "unverified")
    }

    @Test func operationsDisplayCanonicalLifecycleAndTruthfulFallbackStatuses() {
        let agents = [
            HermesSubagent(id: "complete", goal: "done", status: "complete"),
            HermesSubagent(id: "queued", goal: "waiting", status: "queued"),
            HermesSubagent(id: "unverified", goal: "unknown", status: "not-reported")
        ]

        let rows = AgentOperationsPresentation.rows(agents: agents)
        #expect(rows.first(where: { $0.id == "complete" })?.state == .completed)
        #expect(rows.first(where: { $0.id == "queued" })?.state == .pending)
        #expect(rows.first(where: { $0.id == "unverified" })?.state == .unverified)
        #expect(AgentOperationsState.unknown.displayLabel == "UNVERIFIED")
        #expect(AgentOperationsState.unverified.displayLabel == "UNVERIFIED")
    }

    @Test func capacityClassifiesOnlyKnownQuotaData() {
        #expect(CapacityRunwayPresentation.make(usedPercent: nil, hasQuotaData: false).state == .unknown)
        #expect(CapacityRunwayPresentation.make(usedPercent: 85, hasQuotaData: true).state == .constrained)
        #expect(CapacityRunwayPresentation.make(usedPercent: 100, hasQuotaData: true).state == .exhausted)
    }
}
