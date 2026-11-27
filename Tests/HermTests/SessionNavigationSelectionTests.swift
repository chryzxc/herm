import Combine
import Foundation
import Testing

@testable import Herm

@MainActor
struct SessionNavigationSelectionTests {
    @Test func repeatedSidebarTogglesDoNotPublishWorkspaceNavigationChanges() {
        let navigation = SessionNavigationState()
        navigation.openSession("session-a")
        let disclosure = navigation.sidebarDisclosure
        var navigationUpdates = 0
        var sidebarUpdates = 0
        let navigationObserver = navigation.objectWillChange.sink { navigationUpdates += 1 }
        let sidebarObserver = disclosure.objectWillChange.sink { sidebarUpdates += 1 }
        defer {
            navigationObserver.cancel()
            sidebarObserver.cancel()
        }

        #expect(disclosure.expandedSections == [.pinned, .recents, .automations])

        let toggles: [SessionRailSection] = [
            .pinned, .pinned, .pinned, .pinned, .pinned, .recents, .automations, .archived,
        ]
        for section in toggles {
            disclosure.binding(for: section, rendered: disclosure.expandedSections.contains(section)).wrappedValue
                .toggle()
        }
        #expect(sidebarUpdates == 8)
        #expect(navigationUpdates == 0)
        #expect(navigation.selection.selection == .session("session-a"))

        navigation.selectGlobal(.kanban)
        #expect(navigationUpdates > 0)
        #expect(navigation.sidebarDisclosure === disclosure)
        #expect(disclosure.expandedSections == [.archived])
    }

    @Test func gitHubNavigationRemembersTheLastSectionAcrossOtherDestinations() {
        let state = SessionNavigationState()
        #expect(state.selectedGitHubSection == .pullRequests)

        state.selectIssues()
        #expect(state.selection.selection == .issues)
        state.openSession("session-a")
        #expect(state.selectedGitHubSection == .issues)

        state.selectPullRequests()
        #expect(state.selection.selection == .pullRequests)
        state.selectGlobal(.kanban)
        #expect(state.selectedGitHubSection == .pullRequests)
    }

    @Test func selectingASurfaceReplacesThePreviousSidebarIdentity() {
        let state = SessionNavigationSelectionState()

        state.selectTask(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        state.selectGlobal(.kanban)

        #expect(state.selection == .global(.kanban))
        #expect(!state.isTaskSelected(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!))
        #expect(!state.isSessionSelected("session-a"))
    }

    @Test func activeSessionDoesNotHighlightASecondTaskRow() {
        let state = SessionNavigationSelectionState()
        let taskID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

        state.selectSession("session-a")

        #expect(state.isSessionSelected("session-a"))
        #expect(!state.isTaskSelected(taskID, sessionID: "session-a"))
    }

    @Test func clearingSelectionRemovesStaleTaskAndSessionIdentities() {
        let state = SessionNavigationSelectionState()
        let taskID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!

        state.selectTask(taskID)
        state.clear()

        #expect(state.selection == nil)
        #expect(!state.isTaskSelected(taskID))
        #expect(!state.isSessionSelected("session-a"))
    }

    @Test func openingASessionFromAnotherSurfaceReplacesThePreviousDestination() {
        let state = SessionNavigationState()
        let taskID = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!

        state.selectTask(taskID)
        state.openSession("session-b")

        #expect(state.selection.selection == .session("session-b"))
        #expect(state.selectedTaskID == nil)
        #expect(state.selectedSessionID == "session-b")
    }

    @Test func beginningANewConversationClearsThePreviousDestination() {
        let state = SessionNavigationState()

        state.openSession("session-a")
        state.beginNewConversation()

        #expect(state.selection.selection == nil)
        #expect(state.selectedTaskID == nil)
        #expect(state.selectedSessionID == nil)
    }

    @Test func botChatHandoffSelectsTheBotSession() {
        let state = SessionNavigationState()
        state.selectGlobal(.kanban)

        state.openBotChat(sessionID: "bot-session")

        #expect(state.selection.selection == .session("bot-session"))
        #expect(state.selectedTaskID == nil)
        #expect(state.selectedSessionID == "bot-session")
    }

    @Test func botRosterAndBotConversationsKeepIndependentSelections() {
        let state = SessionNavigationState()
        let taskID = UUID(uuidString: "00000000-0000-0000-0000-000000000005")!
        state.selectTask(taskID)
        state.selectGlobal(.bots)
        #expect(state.selection.selection == .global(.bots))
        #expect(state.selectedTaskID == nil && state.selectedSessionID == nil)
        #expect(!state.selection.isTaskSelected(taskID))

        state.openBotChat(sessionID: "bot-session")
        #expect(state.selection.selection == .session("bot-session"))
        #expect(state.selectedTaskID == nil && state.selectedSessionID == "bot-session")
        #expect(!state.selection.isGlobalSelected(.bots))

        state.selectGlobal(.bots)
        #expect(state.selection.selection == .global(.bots))
        #expect(state.selectedTaskID == nil && state.selectedSessionID == nil)
        #expect(!state.selection.isSessionSelected("bot-session"))

        state.selectBots()
        #expect(state.selection.selection == .bots)
        #expect(state.selectedTaskID == nil && state.selectedSessionID == nil)
        #expect(!state.selection.isGlobalSelected(.bots))

        state.openSession("other-session")
        #expect(state.selection.selection == .session("other-session"))
        #expect(state.selectedTaskID == nil && state.selectedSessionID == "other-session")
        #expect(!state.selection.isSessionSelected("bot-session"))
    }

    @Test func pullRequestHandoffSelectsTheResolvedSession() {
        let state = SessionNavigationState()
        state.selectPullRequests()

        state.openPullRequestChat(sessionID: "review-session")

        #expect(state.selection.selection == .session("review-session"))
        #expect(state.selectedTaskID == nil)
        #expect(state.selectedSessionID == "review-session")
    }

    @Test func issueChatHandoffReplacesThePreviousDestination() {
        let state = SessionNavigationState()
        state.selectPullRequests()

        state.openIssueChat(sessionID: "issue-session")

        #expect(state.selection.selection == .session("issue-session"))
        #expect(state.selectedTaskID == nil)
        #expect(state.selectedSessionID == "issue-session")
    }

    @Test func restoredActiveSessionSynchronizesTheSelectionOwner() {
        let state = SessionNavigationState()
        state.selectPullRequests()

        state.synchronizeActiveSession("restored-session")

        #expect(state.selection.selection == .session("restored-session"))
        #expect(state.selectedSessionID == "restored-session")
        #expect(state.selectedTaskID == nil)
    }

    @Test func transientActiveSessionClearingPreservesNavigationSelection() {
        let state = SessionNavigationState()
        state.synchronizeActiveSession("restored-session")

        state.synchronizeActiveSession(nil)

        #expect(state.selection.selection == .session("restored-session"))
        #expect(state.selectedSessionID == "restored-session")
        #expect(state.selectedTaskID == nil)
    }

    @Test func explicitNewConversationStillClearsSelection() {
        let state = SessionNavigationState()
        state.synchronizeActiveSession("restored-session")

        state.beginNewConversation()

        #expect(state.selection.selection == nil)
        #expect(state.selectedSessionID == nil)
    }

    @Test func issueChatHandoffWithoutASessionClearsThePreviousDestination() {
        let state = SessionNavigationState()
        state.openSession("stale-session")

        state.openIssueChat(sessionID: nil)

        #expect(state.selection.selection == nil)
        #expect(state.selectedTaskID == nil)
        #expect(state.selectedSessionID == nil)
    }

    @Test func projectSessionHandoffReplacesTheGlobalDestination() {
        let state = SessionNavigationState()
        state.selectGlobal(.kanban)

        state.openProjectSession(sessionID: "project-session")

        #expect(state.selection.selection == .session("project-session"))
        #expect(state.selectedTaskID == nil)
        #expect(state.selectedSessionID == "project-session")
    }

    @Test func projectChatHandoffReplacesTheProjectDestination() {
        let state = SessionNavigationState()
        state.selectGlobal(.kanban)

        state.beginProjectChat(sessionID: "project-session")

        #expect(state.selection.selection == .session("project-session"))
        #expect(state.selectedTaskID == nil)
        #expect(state.selectedSessionID == "project-session")
    }

    @Test func globalSelectionDoesNotProjectTheActiveSessionIntoProjects() {
        let state = SessionNavigationState()

        state.openSession("active-session")
        state.selectGlobal(.kanban)

        #expect(state.selection.selection == .global(.kanban))
        #expect(state.selectedSessionID == nil)
        #expect(state.selectedProjectSessionID == nil)
    }
}
