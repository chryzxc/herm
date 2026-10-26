import Testing

@testable import Herm

@MainActor
struct TurnModelTests {
    @Test func downloadProgressWeightsCompletedFilesAndCurrentTransfer() {
        let completed = 70_854
        let weights = 16_714_240
        let total = Double(TurnModelStore.downloadSize)
        #expect(TurnModelStore.downloadProgress(completedBytes: 0, fileBytes: 243, fraction: 0) == 0)
        let start = TurnModelStore.downloadProgress(completedBytes: completed, fileBytes: weights, fraction: 0)
        let halfway = TurnModelStore.downloadProgress(completedBytes: completed, fileBytes: weights, fraction: 0.5)
        let end = TurnModelStore.downloadProgress(completedBytes: completed, fileBytes: weights, fraction: 1)
        #expect(start == Double(completed) / total)
        #expect(halfway == (Double(completed) + Double(weights) * 0.5) / total)
        #expect(start < halfway && halfway < end)
        #expect(end == 1)
    }

    @Test func downloadProgressBoundsCurrentTransfer() {
        #expect(TurnModelStore.downloadProgress(completedBytes: 0, fileBytes: 243, fraction: -1) == 0)
        #expect(
            TurnModelStore.downloadProgress(
                completedBytes: 70_854, fileBytes: 16_714_240, fraction: 2) == 1)
    }
}
