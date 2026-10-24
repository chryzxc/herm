import SwiftUI

@MainActor
final class RichHostActionRouter: ObservableObject {
    struct ResolvedRecord {
        let title: String
        let detail: String
        let open: @MainActor () -> Void
    }
    let scope: ProfileScopedID?
    var openSource: @MainActor (RichArtifactReference) async throws -> Void
    struct Feature {
        let kind: RichRecordTarget.Kind
        let ids: @MainActor () -> [String]
        let resolve: @MainActor (String) -> ResolvedRecord?
    }
    let features: [Feature]
    init(
        scope: ProfileScopedID? = nil,
        openSource: @escaping @MainActor (RichArtifactReference) async throws -> Void = { _ in
            throw QuickDraftError.message("Open the source session to inspect this reply.")
        }, features: [Feature]
    ) {
        self.scope = scope
        self.openSource = openSource
        self.features = features
    }
    func resolve(_ target: RichRecordTarget) -> ResolvedRecord? {
        features.first { $0.kind == target.kind }?.resolve(target.id)
    }
    func contextProvider() -> (QuickDestination) -> RichGenerationContext {
        let scope = scope
        // Capture only data readers, never navigation handlers that retain their view.
        let readers = features.map { ($0.kind, $0.ids) }
        return { destination in
            guard let scope, scope.resourceID == destination.sessionID, scope.profileID == destination.profileID else {
                return RichGenerationContext(profileID: destination.profileID, sessionID: destination.sessionID)
            }
            let records = readers.flatMap { kind, ids in
                ids().sorted().prefix(20).map { RichRecordTarget(kind: kind, id: $0) }
            }
            return RichGenerationContext(
                profileID: scope.profileID, sessionID: scope.resourceID,
                availableRecords: Set(records.map(\.kind)), recordReferences: records)
        }
    }
    func generationContext() -> RichGenerationContext {
        contextProvider()(QuickDestination(profileID: scope?.profileID, sessionID: scope?.resourceID, title: "Session"))
    }
}
private struct RichHostActionRouterKey: EnvironmentKey {
    static let defaultValue: RichHostActionRouter? = nil
}
extension EnvironmentValues {
    var richHostActionRouter: RichHostActionRouter? {
        get { self[RichHostActionRouterKey.self] }
        set { self[RichHostActionRouterKey.self] = newValue }
    }
}
struct RichConnectedRecordView: View {
    let target: RichRecordTarget
    @Environment(\.richHostActionRouter) private var router
    @Environment(\.richArtifactReference) private var reference
    var body: some View {
        if let router,
            reference.map({ router.scope == ProfileScopedID(profileID: $0.profileID, resourceID: $0.sessionID) })
                ?? true,
            let record = router.resolve(target)
        {
            VStack(alignment: .leading, spacing: 8) {
                Text(record.title).fontWeight(.semibold)
                Text(record.detail).foregroundStyle(Color.dockSecondaryText)
                Button("Open in Herm", action: record.open).buttonStyle(.dockSecondary)
            }
        } else {
            Text("This \(target.kind.rawValue) record is unavailable in the current workspace.")
                .foregroundStyle(Color.dockSecondaryText)
        }
    }
}
