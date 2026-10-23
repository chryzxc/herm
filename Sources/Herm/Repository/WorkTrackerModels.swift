import Foundation

enum WorkTrackerProvider: String, CaseIterable, Codable, Sendable {
    case jira
    case linear
    case trello
    case asana
    case clickUp = "clickup"
    case todoist
}

struct WorkTrackerProviderDescriptor: Equatable, Sendable {
    let provider: WorkTrackerProvider
    let displayName: String
    let supportsSearch: Bool
    let supportsCreate: Bool
    let supportsStatusUpdate: Bool
}

enum WorkTrackerProviderCatalog {
    static let descriptors: [WorkTrackerProviderDescriptor] = [
        .init(
            provider: .jira, displayName: "Jira", supportsSearch: true, supportsCreate: true, supportsStatusUpdate: true
        ),
        .init(
            provider: .linear, displayName: "Linear", supportsSearch: true, supportsCreate: true,
            supportsStatusUpdate: true),
        .init(
            provider: .trello, displayName: "Trello", supportsSearch: true, supportsCreate: true,
            supportsStatusUpdate: true),
        .init(
            provider: .asana, displayName: "Asana", supportsSearch: true, supportsCreate: true,
            supportsStatusUpdate: true),
        .init(
            provider: .clickUp, displayName: "ClickUp", supportsSearch: true, supportsCreate: true,
            supportsStatusUpdate: true),
        .init(
            provider: .todoist, displayName: "Todoist", supportsSearch: true, supportsCreate: true,
            supportsStatusUpdate: true),
    ]

    static func descriptor(for provider: WorkTrackerProvider) -> WorkTrackerProviderDescriptor? {
        descriptors.first { $0.provider == provider }
    }
}

enum WorkTrackerAvailability: Equatable, Sendable {
    case unconfigured
    case available
    case stale(Date)
    case unavailable(String)
}

/// Ephemeral UI projection for a tracker-backed view. Items are retained when
/// a refresh becomes stale or unavailable so a transient provider outage does
/// not erase useful context from the developer workflow.
struct WorkTrackerProjection: Equatable, Sendable {
    let availability: WorkTrackerAvailability
    let items: [ExternalWorkItem]
    let refreshedAt: Date?

    static let unconfigured = WorkTrackerProjection(availability: .unconfigured, items: [], refreshedAt: nil)

    func preservingItems(with availability: WorkTrackerAvailability, refreshedAt: Date? = nil) -> WorkTrackerProjection
    {
        WorkTrackerProjection(availability: availability, items: items, refreshedAt: refreshedAt ?? self.refreshedAt)
    }
}

struct ExternalWorkItem: Identifiable, Equatable, Sendable {
    let provider: WorkTrackerProvider
    let remoteID: String
    let title: String
    let status: String?
    let assignee: String?
    let priority: String?
    let url: URL?
    let updatedAt: Date?

    var id: String { "\(provider.rawValue):\(remoteID)" }
}

/// The Dock stores only the canonical provider identity and deep link. Remote
/// title/status/description are never copied into durable workspace state.
struct WorkItemLink: Codable, Equatable, Sendable {
    let provider: WorkTrackerProvider
    let remoteID: String
    let url: URL

    var id: String { "\(provider.rawValue):\(remoteID)" }
}

struct WorkItemCreateRequest: Equatable, Sendable {
    let title: String
    let description: String
    let projectID: String?
}

enum WorkTrackerError: Error, Equatable, Sendable {
    case unconfigured
    case unavailable
    case unauthorized
    case malformedResponse
    case mutationRejected
}

/// Provider adapters implement this narrow contract. Views and workflow
/// models never need to know whether the selected provider is Jira, Linear,
/// or another supported tracker.
protocol WorkTrackerService: Sendable {
    var provider: WorkTrackerProvider { get }
    func search(query: String) async -> Result<[ExternalWorkItem], WorkTrackerError>
    func create(_ request: WorkItemCreateRequest) async -> Result<ExternalWorkItem, WorkTrackerError>
    func updateStatus(remoteID: String, status: String) async -> Result<ExternalWorkItem, WorkTrackerError>
}

/// Safe default until a user selects and authorizes one provider. It keeps
/// tracker actions visibly unavailable without silently falling back to a
/// second durable task store.
struct UnconfiguredWorkTrackerService: WorkTrackerService, Sendable {
    let provider: WorkTrackerProvider

    func search(query: String) async -> Result<[ExternalWorkItem], WorkTrackerError> { .failure(.unconfigured) }
    func create(_ request: WorkItemCreateRequest) async -> Result<ExternalWorkItem, WorkTrackerError> {
        .failure(.unconfigured)
    }
    func updateStatus(remoteID: String, status: String) async -> Result<ExternalWorkItem, WorkTrackerError> {
        .failure(.unconfigured)
    }
}

enum WorkTrackerSelectionError: Error, Equatable, Sendable {
    case noProvider
    case multipleProviders
}

struct WorkTrackerSelection: Equatable, Sendable {
    let provider: WorkTrackerProvider?

    init(providers: [WorkTrackerProvider]) throws {
        let unique = Array(Set(providers))
        guard unique.count <= 1 else { throw WorkTrackerSelectionError.multipleProviders }
        provider = unique.first
    }

    var availability: WorkTrackerAvailability {
        provider == nil ? .unconfigured : .unavailable("Provider adapter not configured")
    }

    func service() -> any WorkTrackerService {
        UnconfiguredWorkTrackerService(provider: provider ?? .jira)
    }
}

enum WorkTrackerMutationError: Error, Equatable, Sendable {
    case emptyTitle
    case titleTooLong
    case descriptionTooLong
    case controlCharacter
}

enum WorkTrackerRequestBuilder {
    static func create(title: String, description: String, projectID: String?) -> Result<
        WorkItemCreateRequest, WorkTrackerMutationError
    > {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { return .failure(.emptyTitle) }
        guard cleanTitle.count <= 240 else { return .failure(.titleTooLong) }
        guard cleanDescription.count <= 10_000 else { return .failure(.descriptionTooLong) }
        let cleanProjectID = projectID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        guard cleanTitle.rangeOfCharacter(from: .controlCharacters) == nil,
            cleanDescription.rangeOfCharacter(from: .controlCharacters) == nil,
            cleanProjectID?.rangeOfCharacter(from: .controlCharacters) == nil
        else { return .failure(.controlCharacter) }
        return .success(
            WorkItemCreateRequest(title: cleanTitle, description: cleanDescription, projectID: cleanProjectID))
    }
}

extension String {
    fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}
