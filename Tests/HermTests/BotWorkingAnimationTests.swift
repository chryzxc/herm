import Foundation
import Testing
@testable import Herm

struct BotWorkingAnimationTests {
    @Test func reactionsStartAndFinishAtRest() {
        for variation in 0..<3 {
            for time in [-1.0, 0, 1.2, 10] {
                let pose = BotWorkingPose.reaction(at: time, variation: variation)
                #expect(abs(pose.lift) < 0.0001)
                #expect(abs(pose.reach) < 0.0001)
                #expect(abs(pose.rotation) < 0.0001)
                #expect(abs(pose.scaleX - 1) < 0.0001)
                #expect(abs(pose.scaleY - 1) < 0.0001)
            }
        }
    }

    @Test func adjacentUpdatesHaveDistinctBoundedGestures() {
        let poses = (0..<3).map { BotWorkingPose.reaction(at: 0.5, variation: $0) }
        #expect(poses[0].reach < 0)
        #expect(abs(poses[1].reach) < 0.0001)
        #expect(poses[2].reach > 0)
        for variation in 0..<3 {
            for tick in 0...120 {
                let pose = BotWorkingPose.reaction(at: Double(tick) / 100, variation: variation)
                #expect(pose.lift >= 0 && pose.lift <= 1)
                #expect(abs(pose.reach) <= 0.3)
                #expect(abs(pose.rotation) <= 25)
                #expect((0.9...1.1).contains(pose.scaleX))
                #expect((0.9...1.1).contains(pose.scaleY))
            }
        }
    }

    @Test func hopsAnticipateAndLandBeforeSettling() {
        let crouch = BotWorkingPose.reaction(at: 0.08, variation: 0)
        #expect(crouch.lift == 0)
        #expect(crouch.scaleX > 1 && crouch.scaleY < 1)
        #expect(abs(BotWorkingPose.reaction(at: 0.5, variation: 0).lift - 1) < 0.0001)
        let landing = BotWorkingPose.reaction(at: 1.02, variation: 0)
        #expect(landing.lift < 0.0001)
        #expect(landing.scaleX > 1 && landing.scaleY < 1)
    }

    @Test func rapidUpdatesContinueFromTheVisiblePose() {
        var current = BotWorkingPose.at(0.5)
        for update in 0..<20 {
            let start = BotWorkingPose.reaction(at: 0, variation: update % 3, from: current)
            #expect(start.lift == current.lift)
            #expect(start.reach == current.reach)
            #expect(start.rotation == current.rotation)
            #expect(start.scaleX == current.scaleX && start.scaleY == current.scaleY)
            let nextFrame = BotWorkingPose.reaction(at: 0.001, variation: update % 3, from: current)
            #expect(abs(nextFrame.lift - current.lift) < 0.001)
            #expect(abs(nextFrame.rotation - current.rotation) < 0.01)
            current = BotWorkingPose.reaction(at: 0.3, variation: update % 3, from: current)
        }
        let settled = BotWorkingPose.reaction(at: BotWorkingPose.reactionDuration, variation: 0, from: current)
        #expect(settled.lift == 0 && settled.reach == 0 && settled.rotation == 0)
        #expect(settled.scaleX == 1 && settled.scaleY == 1)
    }

    @Test func waitingMotionSettlesAndRepeats() {
        for tick in 0..<280 {
            let time = Double(tick) / 100
            let pose = BotWorkingPose.at(time)
            let repeated = BotWorkingPose.at(time + 280)
            #expect(pose.lift >= 0 && pose.lift <= 0.4)
            #expect(abs(pose.lift - repeated.lift) < 0.0001)
        }
        #expect(abs(BotWorkingPose.at(1.5).lift) < 0.0001)
        #expect(BotWorkingPose.at(-1).lift == 0)
    }

    @Test func faceSwirlVariesPerSegmentAndFadesBetweenMoves() {
        let moves = Set((0..<40).map { segment in
            Int(BotFacePose.swirl(at: (Double(segment) + 0.25) * BotFacePose.swirlSegment, seed: 42).0.rounded())
        })
        #expect(moves.count > 3)
        let edge = BotFacePose.swirl(at: BotFacePose.swirlSegment * 7, seed: 42)
        #expect(edge.1 < 0.001)
    }
}
