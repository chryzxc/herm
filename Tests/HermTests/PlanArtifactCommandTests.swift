import Testing
@testable import Herm

struct PlanArtifactCommandTests {
    @Test func artifactCommandIsAvailableWithoutRepositoryContext() {
        let available = DockActionRegistry.make(repositoryAvailable: true, isWorking: false).first { $0.action.id == "artifacts" }
        let unavailable = DockActionRegistry.make(repositoryAvailable: false, isWorking: false).first { $0.action.id == "artifacts" }
        #expect(available?.isAvailable == true)
        #expect(unavailable?.isAvailable == true)
        #expect(unavailable?.unavailableReason == nil)
    }

    @Test func artifactSearchMatchesGeneratedOutputs() {
        let descriptors = DockActionRegistry.make(repositoryAvailable: true, isWorking: false)
        let results = DockActionRegistry.search("images outputs", descriptors: descriptors, recentIDs: [])
        #expect(results.map(\.action.id) == ["artifacts"])
    }
}
