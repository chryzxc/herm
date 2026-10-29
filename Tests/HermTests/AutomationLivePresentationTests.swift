import Foundation
import Testing

@testable import Herm

@MainActor
struct AutomationLivePresentationTests {
    @Test func newestExecutionEvidenceControlsRunningState() {
        let cases: [(Bool, String?, String?, String, String?, AutomationWorkspaceRowPresentation.Result)] = [
            (true, "running", "2026-10-29T09:00:00Z", "completed", "2026-10-28T09:00:00Z", .running),
            (true, "completed", "2026-10-30T09:00:00Z", "running", "2026-10-29T09:00:00Z", .succeeded),
            (true, "pending", "2026-10-29T09:00:00Z", "completed", "2026-10-29T09:00:00Z", .running),
            (false, "claimed", nil, "completed", nil, .running),
            (false, "completed", nil, "running", nil, .running),
            (false, "completed", nil, "completed", nil, .paused),
            (true, "finished", nil, "finished", nil, .unknown),
        ]
        for (enabled, status, jobDate, runStatus, runDate, expected) in cases {
            let job = CronSummary(
                id: "job", name: "Review", schedule: "daily", enabled: enabled, nextRun: nil,
                lastRunAt: jobDate, lastStatus: status)
            let run = CronRunSummary(
                id: "run", status: runStatus, jobID: job.id, source: "cron", claimedAt: runDate, error: nil)
            #expect(AutomationWorkspaceRowPresentation.make(job: job, latestRun: run).result == expected)
            #expect(RoutineReference(profileID: nil, job: job, run: run).running == (expected == .running))
            #expect(
                EdgeRoutinePreview.executionLabel(for: RoutineReference(profileID: nil, job: job, run: run))
                    == expected.title)
        }
    }

    @Test func announcementsDeduplicateAndDoNotAnnounceSelectionChanges() {
        var tracker = AutomationStatusAnnouncementTracker()
        #expect(tracker.update(id: "one", name: "Review", status: "Starting") == nil)
        #expect(tracker.update(id: "one", name: "Review", status: "Starting") == nil)
        #expect(tracker.update(id: "one", name: "Review", status: "Running") == "Review: Running")
        #expect(tracker.update(id: "one", name: "Review", status: "Running") == nil)
        #expect(tracker.update(id: "one", name: "Review", status: "Succeeded") == "Review: Succeeded")
        #expect(tracker.update(id: "two", name: "Other", status: "Running") == nil)
    }
}
