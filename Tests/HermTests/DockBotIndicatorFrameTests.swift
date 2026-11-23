import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Herm

struct DockBotIndicatorFrameTests {
    @Test func sameDateIsDeterministicAndMembersAreSeeded() {
        let frame = DockBotIndicatorFrame(date: Date(timeIntervalSinceReferenceDate: 123.25), moves: true)
        let first = frame.face(id: "alpha", busy: true)
        let again = frame.face(id: "alpha", busy: true)
        let other = frame.face(id: "beta", busy: true)
        #expect(first.t == again.t)
        #expect(first.look == again.look)
        #expect(first.blink == again.blink)
        #expect(first.t != other.t)
    }

    @Test func busyGazeCrossesCenterWithoutJumpingBetweenFrames() {
        let center = Double.pi / 2.4
        let before = BotFacePose.at(center - 1.0 / 30, busy: true).look.width
        let after = BotFacePose.at(center + 1.0 / 30, busy: true).look.width
        #expect(before > 0 && after < 0)
        #expect(before - after < 0.01)
    }

    @Test func disabledMotionIsStaticAcrossDates() {
        for date in [Date(timeIntervalSinceReferenceDate: 0), Date(timeIntervalSinceReferenceDate: 456.7)] {
            let frame = DockBotIndicatorFrame(date: date, moves: false)
            let pose = frame.face(id: "alpha", busy: true)
            #expect(pose.t == BotFacePose.rest.t)
            #expect(pose.look == BotFacePose.rest.look)
            #expect(pose.bob == 0)
            #expect(pose.blink == 1)
            #expect(DockBotHuddleLayout(partnerCount: 4, leadDone: false).turn(at: frame).active == -1)
        }
    }

    @Test func standaloneStaticRequestsDoNotAnimateUnderExternalClock() {
        let frame = DockBotIndicatorFrame(date: Date(timeIntervalSinceReferenceDate: 123), moves: true)
        #expect(frame.face(id: "alpha", busy: false).t == 0)
        #expect(frame.face(id: "alpha", busy: true, animated: false).t == 0)
    }

    @Test func huddleMembershipPreservesLeadSlotAndFinishedLeadOrder() {
        for count in [0, 1, 8] {
            let active = DockBotHuddleLayout(partnerCount: count, leadDone: false)
            let done = DockBotHuddleLayout(partnerCount: count, leadDone: true)
            #expect(active.centers.first == 28)
            #expect(active.centers == done.centers)
            #expect(active.centers.count == count + 1)
            #expect(active.rotation == Array(0...count))
            #expect(done.rotation == Array(0..<count).map { $0 + 1 })
            for tick in 0..<20 {
                let frame = DockBotIndicatorFrame(
                    date: Date(timeIntervalSinceReferenceDate: Double(tick) * DockBotHuddleLayout.turnLength),
                    moves: true)
                let turn = done.turn(at: frame)
                if count == 0 {
                    #expect(turn.active == -1)
                } else {
                    #expect((1...count).contains(turn.active))
                    #expect((1...count).contains(turn.next))
                }
            }
        }
    }

    // Clock ownership and compositing are structural contracts, not timing benchmarks.
    @Test func workingAvatarDelegatesMotionToTheRenderLayer() throws {
        let source = try sourceFile("Sources/Herm/Bots/BotAvatar.swift")
        let working = try #require(source.components(separatedBy: "struct BotWorkingAvatarView: View {").last)
            .components(separatedBy: "/// Idle motion")[0]
        #expect(!working.contains("TimelineView("))
        #expect(!working.contains("DockBotFrameClock"))
        #expect(working.contains("BotWorkingAvatarLayer"))
    }

    @MainActor @Test func nativeWorkingPoseLoopsAndReactsOnlyToNewActivity() throws {
        let host = BotNotchFaceMotion.Host(size: 40)
        let layer = try #require(host.face.layer)
        host.applyWorking(enabled: true, signature: ["one"])
        #expect(layer.animation(forKey: "bot.statusMotion")?.repeatCount == .infinity)
        host.applyWorking(enabled: true, signature: ["one"])
        #expect(layer.animation(forKey: "bot.activityReaction") == nil)
        host.applyWorking(enabled: true, signature: ["two"])
        #expect(layer.animation(forKey: "bot.activityReaction")?.repeatCount == 0)
        #expect(layer.animation(forKey: "bot.statusMotion")?.repeatCount == .infinity)
        host.applyWorking(enabled: false, signature: ["two"])
        #expect(layer.animation(forKey: "bot.statusMotion") == nil)
        #expect(layer.animation(forKey: "bot.activityReaction") == nil)
    }

    @MainActor @Test func huddleKeepsItsNativeLeadWhenPartnersJoinAndLeave() async throws {
        _ = NSApplication.shared
        func bot(_ id: String) -> BotSummary {
            BotSummary(
                id: id, name: id, title: nil, description: nil, model: nil,
                isActive: true, chat: nil, avatarURL: nil, preview: nil, lastActive: nil,
                isHidden: false, hasAvatar: false, isDefault: false)
        }
        let lead = bot("lead")
        func huddle(_ partners: [BotSummary]) -> some View {
            BotHuddle(lead: lead, partners: partners, leadSignature: ["running"])
                .environment(\.dockBotIndicatorLive, true)
        }
        func leadView(in view: NSView) -> BotNotchFaceMotion.Host? {
            (view as? BotNotchFaceMotion.Host) ?? view.subviews.lazy.compactMap(leadView(in:)).first
        }
        let host = DockWindowHostingView(rootView: huddle([]))
        host.sizingOptions = []
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 180),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }

        func settle() async throws {
            for _ in 0..<5 {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        try await settle()
        let initial = try #require(leadView(in: host))
        for partners in [[bot("partner")], []] {
            host.rootView = huddle(partners)
            try await settle()
            #expect(leadView(in: host) === initial)
        }
    }

    @Test func liveTextDoesNotCreateMaskedAnimationLayers() throws {
        let source = try sourceFile("Sources/Herm/Conversation/ConversationComponents.swift")
        #expect(!source.contains(".mask(content)"))
        #expect(!source.contains(".modifier(RunningShimmer())"))
    }

    private func sourceFile(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    @Test func thoughtBubblePopsTypesAndBursts() {
        #expect(ThoughtBubbleTiming.scale(0.02) == 0)
        #expect(ThoughtBubbleTiming.scale(0.5) == 1)
        #expect(ThoughtBubbleTiming.scale(0.95) == 0)
        #expect(ThoughtBubbleTiming.typed("Running swift build", phase: 0.1) == "R")
        #expect(ThoughtBubbleTiming.typed("Running swift build", phase: 0.8) == "Running swift build")
        #expect(ThoughtBubbleTiming.typed(nil, phase: 0.5).count == 3)
        #expect(ThoughtBubbleTiming.short("Running a command · git status") == "Running a command")
    }
}
