import Foundation
import Testing

@testable import Herm

@MainActor
struct MissionControlNavigationSelectionTests {
    @Test func selectingASurfaceReplacesThePreviousSidebarIdentity() {
        let state = MissionControlNavigationSelectionState()

        state.selectTask(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        state.selectGlobal(.kanban)

        #expect(state.selection == .global(.kanban))
        #expect(!state.isTaskSelected(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!))
        #expect(!state.isSessionSelected("session-a"))
    }

    @Test func activeSessionDoesNotHighlightASecondTaskRow() {
        let state = MissionControlNavigationSelectionState()
        let taskID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

        state.selectSession("session-a")

        #expect(state.isSessionSelected("session-a"))
        #expect(!state.isTaskSelected(taskID, sessionID: "session-a"))
    }

    @Test func clearingSelectionRemovesStaleTaskAndSessionIdentities() {
        let state = MissionControlNavigationSelectionState()
        let taskID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!

        state.selectTask(taskID)
        state.clear()

        #expect(state.selection == nil)
        #expect(!state.isTaskSelected(taskID))
        #expect(!state.isSessionSelected("session-a"))
    }

    @Test func openingASessionFromAnotherSurfaceReplacesThePreviousDestination() {
        let state = MissionControlNavigationState()
        let taskID = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!

        state.selectTask(taskID)
        state.openSession("session-b")

        #expect(state.selection.selection == .session("session-b"))
        #expect(state.selectedTaskID == nil)
        #expect(state.selectedSessionID == "session-b")
    }

    @Test func beginningANewConversationClearsThePreviousDestination() {
        let state = MissionControlNavigationState()

        state.openSession("session-a")
        state.beginNewConversation()

        #expect(state.selection.selection == nil)
        #expect(state.selectedTaskID == nil)
        #expect(state.selectedSessionID == nil)
    }

    @Test func botChatHandoffSelectsTheBotSession() {
        let state = MissionControlNavigationState()
        state.selectGlobal(.kanban)

        state.openBotChat(sessionID: "bot-session")

        #expect(state.selection.selection == .session("bot-session"))
        #expect(state.selectedTaskID == nil)
        #expect(state.selectedSessionID == "bot-session")
    }

    @Test func pullRequestHandoffSelectsTheResolvedSession() {
        let state = MissionControlNavigationState()
        state.selectPullRequests()

        state.openPullRequestChat(sessionID: "review-session")

        #expect(state.selection.selection == .session("review-session"))
        #expect(state.selectedTaskID == nil)
        #expect(state.selectedSessionID == "review-session")
    }

    @Test func issueChatHandoffReplacesThePreviousDestination() {
        let state = MissionControlNavigationState()
        state.selectPullRequests()

        state.openIssueChat(sessionID: "issue-session")

        #expect(state.selection.selection == .session("issue-session"))
        #expect(state.selectedTaskID == nil)
        #expect(state.selectedSessionID == "issue-session")
    }

    @Test func restoredActiveSessionSynchronizesTheSelectionOwner() {
        let state = MissionControlNavigationState()
        state.selectPullRequests()

        state.synchronizeActiveSession("restored-session")

        #expect(state.selection.selection == .session("restored-session"))
        #expect(state.selectedSessionID == "restored-session")
        #expect(state.selectedTaskID == nil)
    }

    @Test func transientActiveSessionClearingPreservesNavigationSelection() {
        let state = MissionControlNavigationState()
        state.synchronizeActiveSession("restored-session")

        state.synchronizeActiveSession(nil)

        #expect(state.selection.selection == .session("restored-session"))
        #expect(state.selectedSessionID == "restored-session")
        #expect(state.selectedTaskID == nil)
    }

    @Test func explicitNewConversationStillClearsSelection() {
        let state = MissionControlNavigationState()
        state.synchronizeActiveSession("restored-session")

        state.beginNewConversation()

        #expect(state.selection.selection == nil)
        #expect(state.selectedSessionID == nil)
    }

    @Test func issueChatHandoffWithoutASessionClearsThePreviousDestination() {
        let state = MissionControlNavigationState()
        state.openSession("stale-session")

        state.openIssueChat(sessionID: nil)

        #expect(state.selection.selection == nil)
        #expect(state.selectedTaskID == nil)
        #expect(state.selectedSessionID == nil)
    }

    @Test func projectSessionHandoffReplacesTheGlobalDestination() {
        let state = MissionControlNavigationState()
        state.selectGlobal(.kanban)

        state.openProjectSession(sessionID: "project-session")

        #expect(state.selection.selection == .session("project-session"))
        #expect(state.selectedTaskID == nil)
        #expect(state.selectedSessionID == "project-session")
    }

    @Test func projectChatHandoffReplacesTheProjectDestination() {
        let state = MissionControlNavigationState()
        state.selectGlobal(.kanban)

        state.beginProjectChat(sessionID: "project-session")

        #expect(state.selection.selection == .session("project-session"))
        #expect(state.selectedTaskID == nil)
        #expect(state.selectedSessionID == "project-session")
    }

    @Test func globalSelectionDoesNotProjectTheActiveSessionIntoProjects() {
        let state = MissionControlNavigationState()

        state.openSession("active-session")
        state.selectGlobal(.kanban)

        #expect(state.selection.selection == .global(.kanban))
        #expect(state.selectedSessionID == nil)
        #expect(state.selectedProjectSessionID == nil)
    }
}
