import Foundation
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

    @Test func disabledMotionIsStaticAcrossDates() {
        for date in [Date(timeIntervalSinceReferenceDate: 0), Date(timeIntervalSinceReferenceDate: 456.7)] {
            let frame = DockBotIndicatorFrame(date: date, moves: false)
            let pose = frame.face(id: "alpha", busy: true)
            #expect(pose.t == BotFacePose.rest.t)
            #expect(pose.look == BotFacePose.rest.look)
            #expect(pose.bob == 0)
            #expect(pose.blink == 1)
            #expect(frame.sweep == 0)
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
                let frame = DockBotIndicatorFrame(date: Date(timeIntervalSinceReferenceDate: Double(tick) * 0.8), moves: true)
                let turn = done.turn(at: frame)
                if count <= 1 { #expect(turn.active == -1) }
                else {
                    #expect((1...count).contains(turn.active))
                    #expect((1...count).contains(turn.next))
                }
            }
        }
    }

    @Test func cosmeticSweepUsesLowerCadenceThanFrameClock() {
        let first = DockBotIndicatorFrame(date: Date(timeIntervalSinceReferenceDate: 10.01), moves: true)
        let next = DockBotIndicatorFrame(date: Date(timeIntervalSinceReferenceDate: 10.09), moves: true)
        let later = DockBotIndicatorFrame(date: Date(timeIntervalSinceReferenceDate: 10.11), moves: true)
        #expect(first.sweep == next.sweep)
        #expect(first.sweep != later.sweep)
    }

    // Clock ownership and compositing are structural contracts, not timing benchmarks.
    @Test func workingAvatarDelegatesClockOwnership() throws {
        let source = try sourceFile("Sources/Herm/Bots/BotAvatar.swift")
        let working = try #require(source.components(separatedBy: "struct BotWorkingAvatarView: View {").last)
            .components(separatedBy: "/// Idle motion")[0]
        #expect(!working.contains("TimelineView("))
        #expect(working.contains("DockBotFrameClock"))
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
}
