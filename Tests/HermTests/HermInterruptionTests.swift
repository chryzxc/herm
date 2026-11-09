import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Herm

@MainActor
struct HermInterruptionTests {
    private func notice(
        _ kind: HermNotice.Kind = .completion, event: String = "turn-1", profile: String = "research"
    ) -> HermNotice {
        HermNotice(
            kind: kind, source: .session, profileID: profile, sourceID: "session-1", eventID: event)
    }

    @Test func quietMenuTitleShowsRemainingTime() {
        let now = Date(timeIntervalSinceReferenceDate: 0)
        #expect(EdgeQuietMenu.title(quiet: false, expiry: nil, now: now) == "Quiet")
        #expect(EdgeQuietMenu.title(quiet: true, expiry: nil, now: now) == "Quiet · On")
        #expect(
            EdgeQuietMenu.title(quiet: true, expiry: now.addingTimeInterval(41 * 60 + 5), now: now) == "Quiet · 42m")
        #expect(EdgeQuietMenu.title(quiet: true, expiry: now.addingTimeInterval(3600), now: now) == "Quiet · 1h")
        #expect(EdgeQuietMenu.title(quiet: true, expiry: now.addingTimeInterval(90 * 60), now: now) == "Quiet · 1h 30m")
        #expect(EdgeQuietMenu.title(quiet: true, expiry: now.addingTimeInterval(-5), now: now) == "Quiet · 1m")
    }

    @Test func quietIsOptInAndChannelsDeduplicateIndependently() {
        let policy = HermInterruptionCoordinator()
        #expect(!policy.quiet)
        #expect(policy.admit(notice(), channel: .notch))
        #expect(!policy.admit(notice(), channel: .notch))
        #expect(policy.admit(notice(), channel: .system))
        #expect(policy.entries.isEmpty)
    }

    @Test func completionLookupRetainsItsOwnerOutsideTheVisibleInventory() throws {
        var completion = notice()
        completion.unavailable = true
        let other = HermesSession(
            id: "session-1", profileID: "coding", title: "Other profile",
            preview: "", startedAt: nil, messageCount: 0, source: "herm")
        let target = try #require(completion.completedSession(in: [other]))
        #expect(target.id == "session-1")
        #expect(target.profileID == "research")
        #expect(completion.canCheckCompletedSession)
        #expect(!notice(.clarification).canCheckCompletedSession)
        #expect(notice(.clarification).completedSession(in: [other]) == nil)
    }

    @Test func quietSuppressesOrdinaryNoticesButAllowsBlockingDecisions() {
        let policy = HermInterruptionCoordinator()
        policy.start(minutes: nil)
        for kind in [HermNotice.Kind.completion, .quota, .information] {
            #expect(!policy.admit(notice(kind), channel: .notch))
            #expect(!policy.admit(notice(kind), channel: .system))
        }
        for kind in [HermNotice.Kind.approval, .clarification, .failure] {
            #expect(policy.admit(notice(kind), channel: .notch))
            #expect(policy.admit(notice(kind), channel: .system))
        }
        #expect(policy.entries.count == 3)
    }

    @Test func digestUsesOriginAndRunIdentityAndIsBounded() {
        let policy = HermInterruptionCoordinator()
        policy.start()
        for index in 0..<52 { _ = policy.admit(notice(event: "run-\(index)"), channel: .record) }
        _ = policy.admit(notice(event: "run-51"), channel: .notch)
        #expect(policy.entries.count == 50)
        #expect(policy.overflow == 2)
        _ = policy.admit(notice(event: "run-51", profile: "coding"), channel: .record)
        #expect(policy.overflow == 3)
        policy.end()
        #expect(policy.pendingDigest)
        policy.consumeDigestAnnouncement()
        policy.consumeDigestAnnouncement()
        #expect(policy.digestPresentationRevision == 1)
        #expect(!policy.pendingDigest)
    }

    @Test func restoredExpiryProducesOneDigestAndReferencesRequireReconciliation() throws {
        let suite = "HermInterruptionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let start = Date(timeIntervalSince1970: 1000)
        let first = HermInterruptionCoordinator(defaults: defaults, now: { start })
        first.start(minutes: 30)
        _ = first.admit(notice(), channel: .record)
        let restored = HermInterruptionCoordinator(
            defaults: defaults, now: { start.addingTimeInterval(1801) })
        #expect(!restored.quiet)
        #expect(restored.pendingDigest)
        #expect(restored.entries.first?.unavailable == true)
        restored.reconcile(profileID: "coding", sessions: [], kanban: [])
        #expect(restored.entries.first?.unavailable == true)
        restored.clearDigest()
        #expect(restored.entries.isEmpty)
    }

    @Test func failureCanOnlyBeClearedByItsOwner() {
        let policy = HermInterruptionCoordinator()
        policy.recordFailure(notice(.failure))
        policy.clearFailure(owner: "session-1", profileID: "coding")
        #expect(policy.blockingFailure != nil)
        policy.clearFailure(owner: "session-1", profileID: "research")
        #expect(policy.blockingFailure == nil)
    }

    @Test func reviewingOneFailurePreservesOtherOwners() {
        let policy = HermInterruptionCoordinator()
        policy.recordFailure(notice(.failure))
        policy.recordFailure(notice(.failure, profile: "coding"))
        #expect(policy.failures.count == 2)
        policy.clearFailure(owner: "session-1", profileID: "coding")
        #expect(policy.failures.count == 1)
        #expect(policy.blockingFailure?.profileID == "research")
    }

    @Test func renderDigest() async throws {
        guard let output = ProcessInfo.processInfo.environment["NOTCH_SNAPSHOT_DIR"] else { return }
        let policy = HermInterruptionCoordinator()
        policy.start()
        _ = policy.admit(notice(), channel: .record)
        _ = policy.admit(notice(.quota, event: "quota-1"), channel: .record)
        let view = EdgeDigestView(coordinator: policy, back: {}, open: { _ in }, openActivity: {})
            .frame(width: 352, height: 272).background(Color.dockCanvas)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 352, height: 272)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        for _ in 0..<3 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
        }
        let image = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: image)
        try #require(image.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: output).appendingPathComponent("quiet-digest.png"))
    }
}
