import Testing

@testable import Herm

struct RunningProcessesStripTests {
    private func process(_ id: String, _ state: String, _ output: String? = nil) -> ProcessSummary {
        ProcessSummary(id: id, name: id, state: state, detail: nil, latestOutput: output)
    }

    @Test func headerUsesLastRunningProcessWithoutInventingOutput() {
        let first = process("first", "running", "building")
        let second = process("second", "running", " ")
        let finished = process("third", "killed", "old output")
        #expect(RunningProcessesPresentation([first, finished]).count == "1 running")
        #expect(RunningProcessesPresentation([first, finished]).preview == "building")
        #expect(RunningProcessesPresentation([first, second, finished]).count == "2 running")
        #expect(RunningProcessesPresentation([first, second, finished]).preview == nil)
        #expect(RunningProcessesPresentation([finished]).count == "Finished")
        #expect(RunningProcessesPresentation([finished]).preview == nil)
    }
}
