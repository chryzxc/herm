import Foundation

/// Presentation-only discovery, scoped to the currently visible terminal processes.
@MainActor
final class LocalPreviewDiscoveryModel: ObservableObject {
    @Published private(set) var servers: [LocalPreviewServer] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var error: String?
    private var roots: [Int32] = []
    private var active = false
    private var generation = UUID()
    private let discover: ([Int32]) async throws -> [LocalPreviewServer]

    init(discover: @escaping ([Int32]) async throws -> [LocalPreviewServer] = LocalServerDiscovery.discover) {
        self.discover = discover
    }

    func configure(processIDs: [Int32], active: Bool) {
        let roots = Array(Set(processIDs.filter { $0 > 0 })).sorted()
        guard self.roots != roots || self.active != active else { return }
        generation = UUID()
        isRefreshing = false
        if self.roots != roots {
            servers = []
            error = nil
        }
        self.roots = roots
        self.active = active
    }

    func refresh() async {
        guard active, !isRefreshing else { return }
        let token = generation
        isRefreshing = true
        defer { if generation == token { isRefreshing = false } }
        do {
            let found = try await discover(roots)
            guard generation == token, active, !Task.isCancelled else { return }
            servers = found
            error = nil
        } catch {
            guard generation == token, active, !Task.isCancelled else { return }
            self.error = DockModel.safeUserDiagnostic(error.localizedDescription)
        }
    }
}
