import Foundation
import Testing

@testable import Herm

@MainActor
struct SessionReadTests {
    @Test func marksAllLoadedRecentsAndPinnedCopiesReadWithoutChangingOtherProfiles() {
        let suite = "SessionReadTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = DockModel(defaults: defaults)
        model.profileScopeID = "bot"
        let seenStore = SidebarSessionSeenStore(defaults: defaults)
        let recents = (0..<12).map { session(id: "recent-\($0)") }
        let otherProfile = session(id: "recent-0", profileID: "other")
        model.sessions = recents + [otherProfile]
        model.pinnedSessions = [recents[0], otherProfile]
        defaults.set(recents.map(\.id) + ["unlisted"], forKey: model.unreadSessionIDsKey)
        seenStore.baseline(profileID: "bot", sessions: [])

        model.markSessionsRead(recents, seenStore: seenStore)

        #expect(model.sessions.prefix(12).allSatisfy { !$0.hasUnreadUpdate })
        #expect(model.sessions.prefix(12).allSatisfy { resolve($0, seenStore: seenStore) == .none })
        #expect(model.sessions.last == otherProfile)
        #expect(model.pinnedSessions[0].hasUnreadUpdate == false)
        #expect(model.pinnedSessions[1] == otherProfile)
        #expect(defaults.stringArray(forKey: model.unreadSessionIDsKey) == ["unlisted"])
        let restored = SidebarSessionSeenStore(defaults: defaults)
        for session in recents {
            #expect(restored.seenAt(profileID: "bot", sessionID: session.id) == session.lastUpdatedAt)
            #expect(restored.seenAt(profileID: "other", sessionID: session.id) == nil)
        }
        #expect(model.applyPersistedUnreadState(model.sessions).prefix(12).allSatisfy { !$0.hasUnreadUpdate })
    }

    @Test func preservesWorkingAndAttentionAndAllowsLaterUpdatesToBecomeUnread() {
        let suite = "SessionReadTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = DockModel(defaults: defaults)
        let seenStore = SidebarSessionSeenStore(defaults: defaults)
        let working = session(id: "working", isWorking: true)
        model.sessions = [working]
        seenStore.baseline(profileID: "bot", sessions: [])

        model.markSessionsRead([working], seenStore: seenStore)

        let read = model.sessions[0]
        #expect(read.isWorking)
        #expect(!read.hasUnreadUpdate)
        #expect(resolve(read, seenStore: seenStore) == .working)
        #expect(resolve(read, attention: .warning, seenStore: seenStore) == .needsApproval)
        #expect(resolve(read, attention: .clarification, seenStore: seenStore) == .needsClarification)
        let later = session(id: "working", hasUnreadUpdate: false, updatedAt: Date(timeIntervalSince1970: 200))
        #expect(resolve(later, seenStore: seenStore) == .unreadComplete)
        #expect(resolve(later, attention: .failure, seenStore: seenStore) == .failed)
    }

    private func resolve(
        _ session: HermesSession, attention: SessionAttentionDot? = nil, seenStore: SidebarSessionSeenStore
    ) -> SidebarSessionStatus {
        SidebarSessionStatusResolver.resolve(
            session: session, summary: nil, activeSessionID: nil, activeStatus: nil, attention: attention,
            seenAt: seenStore.seenAt(profileID: session.profileID, sessionID: session.id), isProfileBaselined: true)
    }

    private func session(
        id: String, profileID: String = "bot", isWorking: Bool = false, hasUnreadUpdate: Bool = true,
        updatedAt: Date = Date(timeIntervalSince1970: 100)
    ) -> HermesSession {
        HermesSession(
            id: id, profileID: profileID, title: id, preview: "Result", startedAt: nil, updatedAt: updatedAt,
            messageCount: 2, source: "herm", isWorking: isWorking, hasUnreadUpdate: hasUnreadUpdate)
    }
}
