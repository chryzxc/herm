import Testing

@testable import Herm

struct OfficeLiveActivityTests {
    @MainActor @Test func blockedSessionDoesNotStopCurrentKanbanWork() throws {
        let bots = [bot("atlas")]
        let tasks = [
            KanbanTaskSummary(
                id: "card", title: "Deploy", status: "running", detail: nil, priority: nil,
                assignee: "atlas")
        ]
        let work = live([row(phase: .attention)])
        let simulation = OfficePreviewSimulation(bots: bots, tasks: tasks, liveWork: work)
        let current = try #require(simulation.agents.first)
        #expect(OfficeAgentStatus(agent: current, isDataCurrent: true) == .blocked)
        #expect(current.isAtWork)
        #expect(current.phase == .implementing)

        simulation.update(bots: bots, tasks: tasks, liveWork: work, kanbanCurrent: false)
        let stale = try #require(simulation.agents.first)
        #expect(OfficeAgentStatus(agent: stale, isDataCurrent: false) == .blocked)
        #expect(!stale.isAtWork)
    }

    @MainActor @Test func notchStepsDriveTheSameBotThroughWorkAttentionAndCompletion() throws {
        let bots = [bot("atlas"), bot("nova")]
        let simulation = OfficePreviewSimulation(bots: bots)
        let session = HermesSession(
            id: "chat", profileID: "atlas", title: "Check the deployment", preview: "", startedAt: nil,
            messageCount: 1, source: HermesFeatureIDs.sessionSource, isWorking: true)
        let rows = EdgeNotchTask.build(
            current: nil, sessions: [session], activity: ["chat": "Running tests · swift test"],
            currentSessionIDs: [], isOnline: true
        )
        simulation.update(bots: bots, tasks: [], liveWork: live(rows), kanbanCurrent: false)

        let atlas = try #require(simulation.agents.first)
        #expect(atlas.id == "atlas")
        #expect(OfficeAgentStatus(agent: atlas, isDataCurrent: false) == .working)
        #expect(atlas.monitorTitle == "Check the deployment")
        #expect(atlas.monitorDetail == "Running tests · swift test")
        #expect(atlas.location == .desk)
        #expect(!atlas.canWander)
        #expect(simulation.agents.last?.canWander == true)

        let attention = row(phase: .attention, detail: "Approve the next command")
        var blockedWork = try #require(live([attention]).first)
        blockedWork.sessionID = session.id
        simulation.update(bots: bots, tasks: [], liveWork: [blockedWork] + live(rows))
        let blocked = try #require(simulation.agents.first)
        #expect(blocked.id == atlas.id)
        #expect(OfficeAgentStatus(agent: blocked, isDataCurrent: true) == .blocked)
        #expect(blocked.monitorDetail == "Approve the next command")
        #expect(blocked.phase == .waiting)

        simulation.update(bots: bots, tasks: [], liveWork: live([row(phase: .finished)]))
        #expect(simulation.agents.first?.canWander == true)
        #expect(simulation.agents.first?.monitorDetail == nil)
    }

    @MainActor @Test func statusOnlyWorkDoesNotBorrowDetailsFromAnotherTask() throws {
        let bots = [bot("atlas")]
        let board = BotActivityBoard.resolve(
            roster: bots, live: ["chat": .working],
            signals: BotActivitySignals(sessions: [.init(id: "chat", profileID: "atlas")]))
        let card = KanbanTaskSummary(
            id: "card", title: "Kanban deploy", status: "running", detail: nil, priority: nil,
            assignee: "atlas", startedAt: nil, currentStepKey: "deploy")
        let simulation = OfficePreviewSimulation(bots: bots, tasks: [card], botActivity: board)
        let kanban = try #require(simulation.agents.first)
        #expect(kanban.monitorTitle == "Kanban deploy")
        #expect(kanban.location == .desk)

        simulation.update(bots: bots, tasks: [card], botActivity: board, kanbanCurrent: false)
        let fallback = try #require(simulation.agents.first)
        #expect(OfficeAgentStatus(agent: fallback, isDataCurrent: false) == .working)
        #expect(fallback.monitorDetail == nil)
        #expect(fallback.liveWork?.title == nil)
        #expect(fallback.taskData?.id == card.id)
        #expect(fallback.location == .desk)

        simulation.update(bots: bots, tasks: [card], liveWork: live([row(phase: .working)]), botActivity: board)
        #expect(simulation.agents.first?.monitorTitle == "Direct request")
        #expect(simulation.agents.first?.taskData?.id == card.id)
    }

    @MainActor @Test func concurrentDefaultSessionsUseOneCharacterAndKeepTheirOwnStatus() throws {
        let bots = [bot("atlas", isDefault: true)]
        let session = OfficeMainSession(id: "chat", title: "Chat", state: "unknown", isCurrent: true, activities: [])
        let other = OfficeMainSession(
            id: "other", title: "Deploy", state: "needs_approval", isCurrent: false, activities: [])
        let row = EdgeNotchTask(
            id: "runtime-alias", title: "Chat", phase: .working, statusLabel: "Working", detail: "Reading files",
            updatedAt: nil, isCurrent: true, isStatusCurrent: true, session: nil, profileID: "atlas")
        let simulation = OfficePreviewSimulation(bots: bots, sessions: [session, other], liveWork: live([row]))
        #expect(simulation.agents.map(\.id) == ["atlas"])
        let main = try #require(simulation.agents.first)
        #expect(OfficeAgentStatus(agent: main, isDataCurrent: false) == .blocked)
        #expect(main.reportedWork.map(\.sessionID) == ["other", "chat"])
        #expect(main.reportedWork.map(\.status) == [.blocked, .working])
        #expect(main.reportedWork.last?.detail == "Reading files")
        #expect(main.isAtWork)
        #expect(main.location == .desk)
        #expect(main.phase == .implementing)
    }

    @MainActor @Test func botKeepsBothSessionsAndDoesNotCountAHandoffTwice() throws {
        let work = [
            BotLiveWork(profileID: "atlas", sessionID: "one", status: .working, title: "Check tests"),
            BotLiveWork(profileID: "atlas", sessionID: "two", status: .working, title: "Read logs"),
            BotLiveWork(
                profileID: "atlas", sessionID: "one", status: .blocked, title: "Check tests", originSessionID: "sender"),
        ]
        let simulation = OfficePreviewSimulation(bots: [bot("atlas")], liveWork: work)
        let atlas = try #require(simulation.agents.first)
        #expect(atlas.reportedWork.map(\.sessionID) == ["one", "two"])
        #expect(atlas.reportedWork.first?.originSessionID == "sender")
        #expect(atlas.reportedWork.map(\.status) == [.blocked, .working])
    }

    @MainActor @Test func theDeskGroupsAMixedBotOnlyOnceAndKeepsIdleBotsOutOfWork() {
        let work = [
            BotLiveWork(profileID: "atlas", sessionID: "one", status: .working),
            BotLiveWork(profileID: "atlas", sessionID: "two", status: .blocked),
            BotLiveWork(profileID: "nova", sessionID: "other", status: .working),
        ]
        let simulation = OfficePreviewSimulation(bots: [bot("atlas"), bot("nova"), bot("idle")], liveWork: work)
        let desk = OfficeDeskWorkGroups(agents: simulation.agents, kanbanCurrent: false)
        #expect(desk.attention.map(\.id) == ["atlas"])
        #expect(desk.working.map(\.id) == ["nova"])
        #expect(desk.board.isEmpty)
    }

    @Test func staleQueuedAndNonBotNotchRowsAreNotLiveSessionWork() {
        var queued = row(phase: .working)
        queued.isQueued = true
        let unrelated = EdgeNotchTask(
            id: "other", title: "Other work", phase: .working, statusLabel: "Working", detail: nil,
            updatedAt: nil, isCurrent: false, isStatusCurrent: true, session: nil)
        #expect(live([queued, unrelated, row(phase: .working, current: false)]).isEmpty)
    }

    private func bot(_ id: String, isDefault: Bool = false) -> BotSummary {
        BotSummary(
            id: id, name: id, title: nil, description: nil, model: nil, isActive: false,
            chat: nil, avatarURL: nil, preview: nil, lastActive: nil, isHidden: false,
            hasAvatar: false, isDefault: isDefault)
    }

    private func row(phase: EdgeNotchTask.Phase, detail: String? = nil, current: Bool = true) -> EdgeNotchTask {
        EdgeNotchTask(
            id: "dispatch", title: "Direct request", phase: phase, statusLabel: "Work", detail: detail,
            updatedAt: nil, isCurrent: false, isStatusCurrent: current, session: nil, profileID: "atlas")
    }

    private func live(_ rows: [EdgeNotchTask]) -> [BotLiveWork] {
        rows.compactMap { $0.liveBotWork(scopeProfileID: "atlas", currentSessionID: "chat") }
    }
}
