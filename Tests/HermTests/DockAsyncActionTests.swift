import Testing

@testable import Herm

@Suite @MainActor
struct DockAsyncActionTests {
    @Test func startsImmediatelyRejectsDuplicatesAndResetsAfterCompletion() async {
        let activity = DockAsyncAction()
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        var calls = 0
        let task = activity.perform {
            calls += 1
            for await _ in stream { break }
        }
        #expect(activity.isPending)
        #expect(activity.perform { calls += 1 } == nil)
        continuation.yield(())
        continuation.finish()
        await task?.value
        #expect(calls == 1)
        #expect(!activity.isPending)
        await activity.perform { calls += 1 }?.value
        #expect(calls == 2)
        #expect(!activity.isPending)
    }

    @Test func cancellationAndHandledFailureClearPendingState() async {
        let activity = DockAsyncAction()
        var handled = false
        let task = activity.perform {
            do { try Task.checkCancellation() } catch { handled = true }
        }
        task?.cancel()
        await task?.value
        #expect(handled)
        #expect(!activity.isPending)
    }
}
