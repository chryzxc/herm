import Testing
@testable import Herm

struct ScrollPerformanceFixtureTests {
    @Test
    func standardFixtureMatchesTheProfilingContract() {
        let fixture = ScrollPerformanceFixture.standard
        #expect(fixture.projectCount == 30)
        #expect(fixture.sessionCount == 500)
        #expect(fixture.messageCount == 500)
        #expect(fixture.streamingBytes == 131_072)
        #expect(fixture.streamingCadenceMilliseconds == 250)
        #expect(fixture.markdownSamples.count >= 4)
        #expect(fixture.sessions.count == 500)
        #expect(fixture.messages.count == 500)
        #expect(fixture.idleLongMarkdown.utf8.count == fixture.streamingBytes)
        #expect(fixture.streamingLongMarkdown == fixture.idleLongMarkdown)
        #expect(fixture.streamingDeltas().joined() == fixture.streamingLongMarkdown)
        #expect(fixture.streamingDeltas().count > 1_000)
        #expect(fixture.streamingDeltas(chunkBytes: 37).allSatisfy { $0.utf8.count <= 37 })
        #expect(fixture.messages.last?.role == .hermes)
        #expect(fixture.messages.last?.text == fixture.idleLongMarkdown)
    }

    @Test
    func sidebarRowDescriptorsAreValueStable() {
        let descriptor = SidebarSessionRowDescriptor(
            id: "session-1",
            title: "Build release",
            preview: "Preparing the release notes",
            repositoryLabel: "hermes-agent-dock",
            statusLabel: "Working",
            relativeTime: "now",
            isPinned: true,
            isSelected: false,
            actionState: nil
        )
        #expect(descriptor == descriptor)
        #expect(descriptor.id == "session-1")
    }
}
