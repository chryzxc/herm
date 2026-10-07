import Foundation
import Testing
@testable import Herm

struct WorkCalendarIndexTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Manila")!
        return calendar
    }

    private func date(_ day: Int, _ hour: Int = 12, month: Int = 10) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }

    @Test func bucketsByLocalDayAndDropsOtherMonths() {
        let index = WorkCalendarIndex.build(
            month: date(15),
            sessions: [
                SessionSummary(id: "late", title: "Late", state: "idle", preview: nil, updatedAt: date(3, 23)),
                SessionSummary(id: "early", title: "Early", state: "idle", preview: nil, updatedAt: date(4, 0)),
                SessionSummary(id: "old", title: "Old", state: "idle", preview: nil, updatedAt: date(30, month: 9))
            ],
            tasks: [KanbanTaskSummary(id: "t", title: "Ship it", status: "done", detail: nil, priority: nil, assignee: nil, completedAt: date(3))],
            commits: [WorkCommit(repo: "herm", hash: "abc", subject: "feat: calendar", date: date(3, 9))],
            runs: [CronRunSummary(id: "r", status: "failed", jobID: "nightly", source: "cron", claimedAt: "2026-10-03T01:00:00Z", error: nil)],
            usage: [],
            now: date(5),
            calendar: calendar
        )

        let third = index.day(calendar.startOfDay(for: date(3)))
        #expect(third?.sessions.map(\.id) == ["late"])
        #expect(third?.shippedCount == 2) // task + commit; the failed run is not shipped
        #expect(third?.hasFailedRun == true)
        #expect(third?.heat == 4)
        #expect(index.day(calendar.startOfDay(for: date(4)))?.sessions.map(\.id) == ["early"])
        #expect(index.days.count == 2)
        #expect(index.activeDays == 2)
    }

    @Test func streaksSurviveAnEmptyTodayAndResetOnGaps() {
        let sessions = [1, 2, 3, 6, 7].map {
            SessionSummary(id: "\($0)", title: "S\($0)", state: "idle", preview: nil, updatedAt: date($0))
        }
        let index = WorkCalendarIndex.build(month: date(1), sessions: sessions, tasks: [], commits: [], runs: [], usage: [], now: date(8), calendar: calendar)
        #expect(index.longestStreak == 3)
        #expect(index.currentStreak == 2)
    }

    @Test func standupListsShippedAndWorkedOn() {
        var day = WorkDay()
        day.doneTasks = [
            KanbanTaskSummary(id: "p", title: "Plan: Ship it", status: "done", detail: nil, priority: nil, assignee: "archon", completedAt: date(5, 9)),
            KanbanTaskSummary(id: "t", title: "Ship it", status: "done", detail: nil, priority: nil, assignee: "forge", completedAt: date(5, 10))
        ]
        day.sessions = [SessionSummary(id: "s", title: "Calendar tab", state: "idle", preview: nil)]
        let text = WorkCalendarIndex.standupMarkdown(for: date(5), day: day)
        #expect(text.contains("**Shipped**\n- Plan: Ship it (archon)\n- Ship it (forge)"))
        #expect(text.contains("**Worked on**\n- Calendar tab"))
        #expect(!text.contains("Automations"))
    }

    @Test func worktreesResolveToTheirMainCheckout() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("climateRX")
        let worktree = repo.appendingPathComponent(".worktrees/t_1")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git/worktrees/t_1"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: worktree.appendingPathComponent("src"), withIntermediateDirectories: true)
        try "gitdir: \(repo.path)/.git/worktrees/t_1\n".write(to: worktree.appendingPathComponent(".git"), atomically: true, encoding: .utf8)

        let resolved = repo.standardizedFileURL.path
        #expect(RepositoryService.repositoryRoot(worktree.appendingPathComponent("src").path) == resolved)
        #expect(RepositoryService.repositoryRoot(repo.appendingPathComponent(".worktrees/t_gone").path) == resolved)
    }
}
