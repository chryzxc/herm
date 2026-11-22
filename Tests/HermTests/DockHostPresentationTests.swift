import AppKit
import Testing

@testable import Herm

@MainActor
struct DockHostPresentationTests {
    @Test func aReplacedObserversLateDetachKeepsTheNewWindowVisible() {
        let presentation = DockHostPresentation()
        let old = NSObject()
        let new = NSObject()
        presentation.update(window: nil, owner: ObjectIdentifier(old))
        // SwiftUI attaches the replacement before it dismantles the old observer.
        presentation.update(window: nil, owner: ObjectIdentifier(new))
        presentation.setDisplaysAsleep(false, window: nil)
        presentation.detach(owner: ObjectIdentifier(old))
        #expect(presentation.ownerForTesting == ObjectIdentifier(new))
        presentation.detach(owner: ObjectIdentifier(new))
        #expect(presentation.ownerForTesting == nil)
        #expect(!presentation.isVisible)
    }
}

@MainActor
struct EdgeIslandCrewTests {
    private func task(_ id: String, phase: EdgeNotchTask.Phase, profile: String?, current: Bool = true) -> EdgeNotchTask
    {
        EdgeNotchTask(
            id: id, title: id, phase: phase, statusLabel: "", detail: nil, updatedAt: nil, isCurrent: false,
            isStatusCurrent: current, session: nil, profileID: profile)
    }

    private func bot(_ id: String, isDefault: Bool = false) -> BotSummary {
        BotSummary(
            id: id, name: id, title: nil, description: nil, model: nil, provider: nil, isActive: true, chat: nil,
            avatarURL: nil, preview: nil, lastActive: nil, isHidden: false, hasAvatar: false, isDefault: isDefault)
    }

    @Test func showsEachWorkingBotOnceAndSkipsStaleOrIdleRows() {
        let bots = [bot("nexus", isDefault: true), bot("scout")]
        let crew = EdgeIslandStatusStrip.crew(
            [
                task("a", phase: .working, profile: "scout"),
                task("b", phase: .working, profile: "scout"),
                task("c", phase: .finished, profile: "nexus"),
                task("d", phase: .working, profile: "nexus", current: false),
                task("e", phase: .working, profile: "unknown"),
            ], bots: bots)
        // An unknown profile falls back to the default Bot, as the notch rows do.
        #expect(crew.map(\.bot.id) == ["scout", "nexus"])
        #expect(crew.map(\.task.id) == ["a", "e"])
    }
}
