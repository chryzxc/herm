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
        let poses = (0..<3).map { BotWorkingPose.reaction(at: 0.6, variation: $0) }
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
}
