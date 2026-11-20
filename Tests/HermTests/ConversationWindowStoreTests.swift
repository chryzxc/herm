import CoreGraphics
import Foundation
import Testing

@testable import Herm

@MainActor
private final class FakeConversationWindow: ConversationWindowHandle {
    var focusCount = 0
    var closeCount = 0
    var titles: [String] = []
    func focus() { focusCount += 1 }
    func close() { closeCount += 1 }
    func retitle(_ title: String) { titles.append(title) }
}

@MainActor
struct ConversationWindowStoreTests {
    private func destination(_ id: String, profile: String? = "default") -> QuickDestination {
        QuickDestination(profileID: profile, sessionID: id, title: "Chat \(id)")
    }

    private func makeStore() -> (ConversationWindowStore, () -> [FakeConversationWindow]) {
        var made: [FakeConversationWindow] = []
        let store = ConversationWindowStore { _ in
            let window = FakeConversationWindow()
            made.append(window)
            return window
        }
        return (store, { made })
    }

    // MARK: resolution

    @Test func resolveFocusesAlreadyDetached() {
        #expect(
            ConversationWindowStore.resolve(
                sessionID: "s1", mainSessionID: "s1", columnSessionIDs: ["s1"], detachedSessionIDs: ["s1"])
                == .focusWindow)
    }

    @Test func resolveLeavesMainWhenOpenInMain() {
        #expect(
            ConversationWindowStore.resolve(
                sessionID: "s1", mainSessionID: "s1", columnSessionIDs: [], detachedSessionIDs: [])
                == .openWindow(leaveMain: true, removeFromColumn: false))
    }

    @Test func resolveRemovesFromColumn() {
        #expect(
            ConversationWindowStore.resolve(
                sessionID: "s1", mainSessionID: "s2", columnSessionIDs: ["s1"], detachedSessionIDs: [])
                == .openWindow(leaveMain: false, removeFromColumn: true))
    }

    @Test func resolveLetsTheColumnMoveMainOnWhenSplit() {
        #expect(
            ConversationWindowStore.resolve(
                sessionID: "s1", mainSessionID: "s1", columnSessionIDs: ["s1"], detachedSessionIDs: [])
                == .openWindow(leaveMain: false, removeFromColumn: true))
    }

    @Test func resolveRemovesGroupRoomFromColumn() {
        let room = QuickDestination.groupRoomTabID("r1")
        #expect(
            ConversationWindowStore.resolve(
                sessionID: room, mainSessionID: nil, columnSessionIDs: [room], detachedSessionIDs: [])
                == .openWindow(leaveMain: false, removeFromColumn: true))
    }

    // MARK: bookkeeping

    @Test func openTwiceCreatesOneWindowAndFocuses() {
        let (store, made) = makeStore()
        store.open(destination("s1"))
        store.open(destination("s1"))
        #expect(made().count == 1)
        #expect(made().first?.focusCount == 2)
        #expect(store.detachedSessionIDs == ["s1"])
    }

    @Test func openMainSessionLeavesMainOnce() {
        let (store, _) = makeStore()
        store.mainSessionID = { "s1" }
        var left = 0
        store.addLeaveMainHandler(UUID()) { left += 1 }
        store.open(destination("s1"))
        store.open(destination("s1"))
        #expect(left == 1)
    }

    @Test func leaveMainRunsEveryRegisteredHandler() {
        let (store, _) = makeStore()
        store.mainSessionID = { "s1" }
        var calls: [String] = []
        let removed = UUID()
        store.leaveMain = { calls.append("model") }
        store.addLeaveMainHandler(UUID()) { calls.append("a") }
        store.addLeaveMainHandler(UUID()) { calls.append("b") }
        store.addLeaveMainHandler(removed) { calls.append("gone") }
        store.removeLeaveMainHandler(removed)
        store.open(destination("s1"))
        // The shared model clears once however many workspaces are mounted.
        #expect(calls.sorted() == ["a", "b", "model"])
    }

    @Test func openColumnSessionRemovesItFromColumn() {
        let (store, _) = makeStore()
        store.columnSessionIDs = { ["s1"] }
        var removed: [String] = []
        store.removeFromColumn = { removed.append($0) }
        store.open(destination("s1"))
        #expect(removed == ["s1"])
    }

    @Test func openGroupRoomDetachesIt() {
        let (store, made) = makeStore()
        let room = QuickDestination.groupRoomTabID("r1")
        store.open(destination(room, profile: nil))
        #expect(made().count == 1)
        #expect(store.detachedSessionIDs == [room])
    }

    @Test func windowDidCloseForgetsWithoutClosingAgain() {
        let (store, made) = makeStore()
        store.open(destination("s1"))
        store.windowDidClose(sessionID: "s1")
        #expect(store.detachedSessionIDs.isEmpty)
        #expect(made().first?.closeCount == 0)
        #expect(!store.focus(sessionID: "s1"))
    }

    @Test func closeClosesHandleAndForgets() {
        let (store, made) = makeStore()
        store.open(destination("s1"))
        store.close(sessionID: "s1")
        #expect(made().first?.closeCount == 1)
        #expect(store.detachedSessionIDs.isEmpty)
    }

    @Test func focusUnknownReturnsFalse() {
        let (store, _) = makeStore()
        #expect(!store.focus(sessionID: "nope"))
    }

    @Test func retitleUpdatesFoundAndKeepsMissing() {
        let (store, made) = makeStore()
        store.open(destination("s1"))
        store.open(destination("s2"))
        let renamed = HermesSession(
            id: "s1", profileID: "default", title: "Renamed", preview: "", startedAt: nil, messageCount: 1,
            source: HermesFeatureIDs.sessionSource)
        store.retitle(from: [renamed])
        #expect(made()[0].titles.last == renamed.displayTitle)
        #expect(made()[1].titles.isEmpty)
        #expect(store.detachedSessionIDs == ["s1", "s2"])
    }

    // MARK: placement

    private let size = CGSize(width: 420, height: 600)

    @Test func placementUsesSavedFrameOnVisibleScreen() {
        let saved = CGRect(x: 100, y: 100, width: 500, height: 700)
        let frame = ConversationWindowStore.placement(
            saved: saved, screens: [CGRect(x: 0, y: 0, width: 1440, height: 900)], mouse: .zero, size: size,
            cascadeIndex: 0)
        #expect(frame == saved)
    }

    @Test func placementRecentersWhenSavedFrameIsOffscreen() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let saved = CGRect(x: 5000, y: 100, width: 500, height: 700)
        let frame = ConversationWindowStore.placement(
            saved: saved, screens: [screen], mouse: CGPoint(x: 6000, y: 300), size: size, cascadeIndex: 0)
        #expect(screen.contains(frame))
        #expect(frame.size == saved.size)
    }

    @Test func placementCascadesOnMouseScreen() {
        let first = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let second = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        let frame = ConversationWindowStore.placement(
            saved: nil, screens: [first, second], mouse: CGPoint(x: 2000, y: 500), size: size, cascadeIndex: 2)
        let centered = CGPoint(x: second.midX - size.width / 2, y: second.midY - size.height / 2)
        #expect(second.contains(frame))
        #expect(frame.origin.x == centered.x + 48)
        #expect(frame.origin.y == centered.y - 48)
    }

    @Test func placementShrinksAnOversizedWindowToTheScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1280, height: 720)
        let saved = CGRect(x: 9000, y: 0, width: 1600, height: 1000)
        let frame = ConversationWindowStore.placement(
            saved: saved, screens: [screen], mouse: CGPoint(x: 10, y: 10), size: size, cascadeIndex: 0)
        #expect(frame == screen)
    }
}
