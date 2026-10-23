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
                SessionSummary(id: "old", title: "Old", state: "idle", preview: nil, updatedAt: date(30, month: 9)),
            ],
            tasks: [
                KanbanTaskSummary(
                    id: "t", title: "Ship it", status: "done", detail: nil, priority: nil, assignee: nil,
                    completedAt: date(3))
            ],
            commits: [WorkCommit(repo: "herm", hash: "abc", subject: "feat: calendar", date: date(3, 9))],
            runs: [
                CronRunSummary(
                    id: "r", status: "failed", jobID: "nightly", source: "cron", claimedAt: "2026-10-03T01:00:00Z",
                    error: nil)
            ],
            usage: [],
            now: date(5),
            calendar: calendar
        )

        let third = index.day(calendar.startOfDay(for: date(3)))
        #expect(third?.sessions.map(\.id) == ["late"])
        #expect(third?.shippedCount == 2)  // task + commit; the failed run is not shipped
        #expect(third?.hasFailedRun == true)
        #expect(third?.heat == 4)
        #expect(index.day(calendar.startOfDay(for: date(4)))?.sessions.map(\.id) == ["early"])
        #expect(index.days.count == 2)
        #expect(index.activeDays == 2)
    }

    @Test func mergedPullRequestCountsStayWithinTheSelectedDay() {
        let repos = ["owner/climateRX", "owner/clipstep", "owner/climateRX", "other/clipstep"]
        var prs = repos.enumerated().map { offset, repo in
            WorkPullRequest(repo: repo, number: offset + 1, title: "Ship it", url: nil, mergedAt: date(3))
        }
        prs.append(
            WorkPullRequest(repo: "owner/clipstep", number: 20, title: "Another day", url: nil, mergedAt: date(4)))
        let index = WorkCalendarIndex.build(
            month: date(1), sessions: [], tasks: [], commits: [], pullRequests: prs,
            runs: [], usage: [], now: date(5), calendar: calendar
        )

        #expect(
            index.day(calendar.startOfDay(for: date(3)))?.pullRequestsByRepository == [
                WorkCount(id: "owner/climateRX", count: 2),
                WorkCount(id: "other/clipstep", count: 1),
                WorkCount(id: "owner/clipstep", count: 1),
            ])
        #expect(
            index.day(calendar.startOfDay(for: date(4)))?.pullRequestsByRepository == [
                WorkCount(id: "owner/clipstep", count: 1)
            ])
        #expect(WorkDay().pullRequestsByRepository.isEmpty)
    }

    @Test func streaksSurviveAnEmptyTodayAndResetOnGaps() {
        let sessions = [1, 2, 3, 6, 7].map {
            SessionSummary(id: "\($0)", title: "S\($0)", state: "idle", preview: nil, updatedAt: date($0))
        }
        let index = WorkCalendarIndex.build(
            month: date(1), sessions: sessions, tasks: [], commits: [], runs: [], usage: [], now: date(8),
            calendar: calendar)
        #expect(index.longestStreak == 3)
        #expect(index.currentStreak == 2)
    }

    @Test func scopesKeepEveryRecordAndSumTheSameDailyData() {
        let recordedDays = [3, 4, 10]
        let index = WorkCalendarIndex.build(
            month: date(1),
            sessions: recordedDays.map {
                SessionSummary(id: "s\($0)", title: "Session", state: "idle", preview: nil, updatedAt: date($0, 9))
            },
            tasks: recordedDays.map {
                KanbanTaskSummary(
                    id: "t\($0)", title: "Task", status: "done", detail: nil, priority: nil, assignee: "forge",
                    completedAt: date($0, 10))
            },
            commits: recordedDays.map {
                WorkCommit(repo: "owner/repo", hash: "c\($0)", subject: "Commit", date: date($0, 11))
            },
            pullRequests: recordedDays.map {
                WorkPullRequest(
                    repo: $0 == 10 ? "owner/other" : "owner/repo", number: $0, title: "PR", url: nil,
                    mergedAt: date($0, 12))
            },
            runs: recordedDays.map {
                CronRunSummary(
                    id: "r\($0)", status: $0 == 4 ? "failed" : "completed", jobID: "nightly", source: "cron",
                    claimedAt: date($0, 13).ISO8601Format(), error: nil)
            },
            usage: recordedDays.map {
                TokenUsageReport.Day(
                    day: date($0), inputTokens: 100, outputTokens: 50, cacheReadTokens: 0, reasoningTokens: 0,
                    estimatedCost: 1.25, sessions: 4, apiCalls: 2)
            },
            now: date(10), calendar: calendar
        )

        // One day, its week, then its month: the records and totals must agree.
        for (from, to, expectedDays) in [(3, 3, [3]), (3, 9, [3, 4]), (1, 31, [3, 4, 10])] {
            let range = index.range(from: date(from), to: date(to), calendar: calendar)
            let newestFirst = expectedDays.reversed()
            #expect(range.sessions.map(\.id) == newestFirst.map { "s\($0)" })
            #expect(range.tasks.map(\.id) == newestFirst.map { "t\($0)" })
            #expect(range.commits.map(\.hash) == newestFirst.map { "c\($0)" })
            #expect(range.pullRequests.map(\.number) == Array(newestFirst))
            #expect(Set(range.runs.map(\.id)) == Set(expectedDays.map { "r\($0)" }))
            #expect(range.runs.filter(\.isFailure).count == (expectedDays.contains(4) ? 1 : 0))
            #expect(range.pullRequestsByRepository.reduce(0) { $0 + $1.count } == expectedDays.count)
            #expect(range.repos == [WorkCount(id: "owner/repo", count: expectedDays.count)])
            #expect(range.assignees == [WorkCount(id: "forge", count: expectedDays.count)])
            #expect(range.tokens == expectedDays.count * 150)
            #expect(range.apiCalls == expectedDays.count * 2)
            #expect(range.usageSessions == expectedDays.count * 4)
            #expect(range.cost == Double(expectedDays.count) * 1.25)
            #expect(range.hasUsage)
            #expect(!range.isEmpty)
            #expect(range.activeDays == expectedDays.count)
            #expect(range.activeHours == expectedDays.count * 5)
            #expect(range.longestStretch == 5)
            #expect(range.hours.reduce(0, +) == expectedDays.count * 5)
            #expect(range.hours[9] == expectedDays.count)
            #expect(range.hours[13] == expectedDays.count)
            #expect(range.shippedItems == expectedDays.count * 2)  // tasks + PRs, without counting their commits twice
        }
        #expect(
            index.range(from: date(1), to: date(31), calendar: calendar).pullRequestsByRepository == [
                WorkCount(id: "owner/repo", count: 2), WorkCount(id: "owner/other", count: 1),
            ])
        let boundaryWeek = index.range(from: date(30, month: 9), to: date(4), calendar: calendar)
        #expect(boundaryWeek.points.first?.date == calendar.startOfDay(for: date(1)))
        #expect(boundaryWeek.points.last?.date == calendar.startOfDay(for: date(4)))
        #expect(boundaryWeek.commits.map(\.hash) == ["c4", "c3"])
    }

    @Test func usageOnlyPeriodsStayVisibleEvenWithNoEventsOrCost() {
        let index = WorkCalendarIndex.build(
            month: date(1), sessions: [], tasks: [], commits: [], runs: [],
            usage: [
                TokenUsageReport.Day(
                    day: date(3), inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, reasoningTokens: 0,
                    estimatedCost: 0, sessions: 0, apiCalls: 0)
            ],
            calendar: calendar
        )
        #expect(index.day(calendar.startOfDay(for: date(3)))?.isEmpty == false)
        for (from, to) in [(3, 3), (1, 7), (1, 31)] {
            let range = index.range(from: date(from), to: date(to), calendar: calendar)
            #expect(range.hasUsage)
            #expect(!range.isEmpty)
        }
        #expect(index.range(from: date(10), to: date(16), calendar: calendar).isEmpty)
    }

    @Test func mergedPullRequestsRemainVisibleWithoutCommitOrSessionEvents() {
        let pr = WorkPullRequest(repo: "owner/repo", number: 7, title: "Merged", url: nil, mergedAt: date(3))
        let index = WorkCalendarIndex.build(
            month: date(1), sessions: [], tasks: [], commits: [], pullRequests: [pr], runs: [], usage: [],
            calendar: calendar
        )
        for (from, to) in [(3, 3), (1, 7), (1, 31)] {
            let range = index.range(from: date(from), to: date(to), calendar: calendar)
            #expect(range.pullRequests == [pr])
            #expect(!range.isEmpty)
            #expect(range.points.reduce(0) { $0 + $1.total } == 0)
            #expect(range.shippedItems == 1)
        }
    }

    @Test func standupListsShippedAndWorkedOn() {
        var day = WorkDay()
        day.doneTasks = [
            KanbanTaskSummary(
                id: "p", title: "Plan: Ship it", status: "done", detail: nil, priority: nil, assignee: "archon",
                completedAt: date(5, 9)),
            KanbanTaskSummary(
                id: "t", title: "Ship it", status: "done", detail: nil, priority: nil, assignee: "forge",
                completedAt: date(5, 10)),
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
        let repo = root.appendingPathComponent("sample-repo")
        let worktree = repo.appendingPathComponent(".worktrees/t_1")
        try FileManager.default.createDirectory(
            at: repo.appendingPathComponent(".git/worktrees/t_1"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: worktree.appendingPathComponent("src"), withIntermediateDirectories: true)
        try "gitdir: \(repo.path)/.git/worktrees/t_1\n".write(
            to: worktree.appendingPathComponent(".git"), atomically: true, encoding: .utf8)

        let resolved = repo.standardizedFileURL.path
        #expect(RepositoryService.repositoryRoot(worktree.appendingPathComponent("src").path) == resolved)
        #expect(RepositoryService.repositoryRoot(repo.appendingPathComponent(".worktrees/t_gone").path) == resolved)
    }
}
