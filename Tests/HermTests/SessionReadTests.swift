import Combine
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
        var updates = 0
        let subscription = seenStore.objectWillChange.sink { updates += 1 }
        defer { subscription.cancel() }

        model.markSessionsRead(recents, seenStore: seenStore)
        #expect(updates == 1)
        model.markSessionsRead(recents, seenStore: seenStore)
        #expect(updates == 1)

        #expect(model.sessions.prefix(12).allSatisfy { !$0.hasUnreadUpdate })
        #expect(model.sessions.prefix(12).allSatisfy { resolve($0, seenStore: seenStore) == .none })
        #expect(model.sessions.last == otherProfile)
        #expect(model.pinnedSessions[0].hasUnreadUpdate == false)
        #expect(model.pinnedSessions[1] == otherProfile)
        #expect(defaults.stringArray(forKey: model.unreadSessionIDsKey) == ["unlisted"])
        seenStore.flushPersistence()
        let restored = SidebarSessionSeenStore(defaults: defaults)
        for session in recents {
            #expect(restored.seenAt(profileID: "bot", sessionID: session.id) == session.lastUpdatedAt)
            #expect(restored.seenAt(profileID: "other", sessionID: session.id) == nil)
        }
        #expect(model.applyPersistedUnreadState(model.sessions).prefix(12).allSatisfy { !$0.hasUnreadUpdate })
    }

    @Test func seenChangesReachTheirOwnRowsAndPersistTheLatestValue() async throws {
        let suite = "SessionReadTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let seen = SidebarSessionSeenStore(defaults: defaults)
        var hits = [0, 0, 0]
        let first = seen.changes(profileID: "bot", sessionID: "first").sink { hits[0] += 1 }
        let second = seen.changes(profileID: "bot", sessionID: "second").sink { hits[1] += 1 }
        let other = seen.changes(profileID: "other", sessionID: "first").sink { hits[2] += 1 }
        defer {
            first.cancel()
            second.cancel()
            other.cancel()
        }
        seen.baseline(profileID: "bot", sessions: [])
        #expect(hits == [1, 1, 0])
        let newest = Date(timeIntervalSince1970: 120)
        seen.markSeen(profileID: "bot", sessionID: "first", at: newest.addingTimeInterval(-1))
        seen.markSeen(profileID: "bot", sessionID: "first", at: newest)
        #expect(hits == [3, 1, 0])
        for _ in 0..<40 {
            let restored = SidebarSessionSeenStore(defaults: defaults)
            if restored.seenAt(profileID: "bot", sessionID: "first") == newest { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("The coalesced write did not persist the latest seen timestamp")
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
        #expect(resolve(later, seenStore: seenStore).allowsUnreadCount)
        #expect(!resolve(read, seenStore: seenStore).allowsUnreadCount)
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
