import Foundation
import Testing
@testable import HermesAgentDock

struct WorkTrackerModelsTests {
    @Test func linkIdentityUsesProviderAndRemoteIDOnly() {
        let link = WorkItemLink(provider: .jira, remoteID: "ABC-42", url: URL(string: "https://example.atlassian.net/browse/ABC-42")!)
        #expect(link.id == "jira:ABC-42")
    }

    @Test func createRequestTrimsAndBoundsInputs() {
        let result = WorkTrackerRequestBuilder.create(title: "  Fix sync  ", description: "  Investigate refresh race  ", projectID: " P-1 ")
        #expect(result == .success(WorkItemCreateRequest(title: "Fix sync", description: "Investigate refresh race", projectID: "P-1")))
    }

    @Test func createRequestRejectsUnsafeInputs() {
        #expect(WorkTrackerRequestBuilder.create(title: "", description: "", projectID: nil) == .failure(.emptyTitle))
        #expect(WorkTrackerRequestBuilder.create(title: "ok", description: "bad\u{0000}", projectID: nil) == .failure(.controlCharacter))
        #expect(WorkTrackerRequestBuilder.create(title: "ok", description: "", projectID: "bad\u{0000}id") == .failure(.controlCharacter))
        #expect(WorkTrackerRequestBuilder.create(title: String(repeating: "x", count: 241), description: "", projectID: nil) == .failure(.titleTooLong))
    }

    @Test func projectionPreservesItemsWhenProviderIsUnavailable() {
        let item = ExternalWorkItem(provider: .linear, remoteID: "LIN-7", title: "Fix", status: "Todo", assignee: nil, priority: nil, url: nil, updatedAt: nil)
        let refreshed = Date(timeIntervalSince1970: 100)
        let projection = WorkTrackerProjection(availability: .available, items: [item], refreshedAt: refreshed)
        let degraded = projection.preservingItems(with: .unavailable("timeout"))

        #expect(degraded.items == [item])
        #expect(degraded.availability == .unavailable("timeout"))
        #expect(degraded.refreshedAt == refreshed)
    }

    @Test func serviceContractKeepsProviderIdentityOutsideTheViewLayer() async {
        let service = StubWorkTrackerService(provider: .jira)
        let result = await service.search(query: "ABC")
        #expect(result == .success([]))
        #expect(service.provider == .jira)
    }

    @Test func unconfiguredServiceFailsClosedForEveryOperation() async {
        let service = UnconfiguredWorkTrackerService(provider: .jira)
        #expect(await service.search(query: "anything") == .failure(.unconfigured))
        #expect(await service.create(WorkItemCreateRequest(title: "x", description: "", projectID: nil)) == .failure(.unconfigured))
        #expect(await service.updateStatus(remoteID: "ABC-1", status: "Done") == .failure(.unconfigured))
    }

    @Test func trackerSelectionRejectsDualProviderConfiguration() throws {
        let none = try WorkTrackerSelection(providers: [])
        #expect(none.provider == nil)
        #expect(none.availability == .unconfigured)

        let single = try WorkTrackerSelection(providers: [.jira, .jira])
        #expect(single.provider == .jira)
        #expect(single.availability == .unavailable("Provider adapter not configured"))
        #expect(throws: WorkTrackerSelectionError.multipleProviders) {
            try WorkTrackerSelection(providers: [.jira, .linear])
        }
    }

    @Test func providerCatalogListsEverySupportedProviderOnce() {
        #expect(Set(WorkTrackerProviderCatalog.descriptors.map(\.provider)).count == WorkTrackerProvider.allCases.count)
        #expect(WorkTrackerProviderCatalog.descriptor(for: .jira)?.displayName == "Jira")
        #expect(WorkTrackerProviderCatalog.descriptor(for: .todoist)?.supportsStatusUpdate == true)
    }
}

private struct StubWorkTrackerService: WorkTrackerService {
    let provider: WorkTrackerProvider
    func search(query: String) async -> Result<[ExternalWorkItem], WorkTrackerError> { .success([]) }
    func create(_ request: WorkItemCreateRequest) async -> Result<ExternalWorkItem, WorkTrackerError> { .failure(.unconfigured) }
    func updateStatus(remoteID: String, status: String) async -> Result<ExternalWorkItem, WorkTrackerError> { .failure(.unconfigured) }
}
