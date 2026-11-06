import Foundation

struct HermesCompatibilityRemote: Sendable {
    let revision: String
    let contract: Data
}

/// Public upstream metadata only; this never updates or restarts the user's runtime.
@MainActor
final class HermesCompatibilityService: ObservableObject {
    static let shared = HermesCompatibilityService()

    let baseline: HermesCompatibilityBaseline?
    @Published private(set) var changes: [HermesCompatibilityContract.Change] = []
    @Published private(set) var upstreamRevision: String?
    @Published private(set) var checkedAt: Date?
    @Published private(set) var isChecking = false
    @Published private(set) var error: String?

    private let fetch: @Sendable () async throws -> HermesCompatibilityRemote

    init(
        baseline: HermesCompatibilityBaseline? = try? HermesCompatibilityService.bundledBaseline(),
        fetch: @escaping @Sendable () async throws -> HermesCompatibilityRemote = { try await fetchUpstream() }
    ) {
        self.baseline = baseline
        self.fetch = fetch
    }

    static func bundledBaseline() throws -> HermesCompatibilityBaseline {
        guard let url = Bundle.herm.url(forResource: "HermesCompatibility", withExtension: "json") else {
            throw HermesCompatibilityContract.Failure.invalidBaseline
        }
        let baseline = try JSONDecoder().decode(HermesCompatibilityBaseline.self, from: Data(contentsOf: url))
        try baseline.validate()
        return baseline
    }

    func check(force: Bool = false) async {
        guard !isChecking else { return }
        if !force, let checkedAt, Date().timeIntervalSince(checkedAt) < 21_600 { return }
        guard let baseline else {
            error = "The reviewed Hermes baseline is unavailable in this Herm build."
            return
        }
        isChecking = true
        defer { isChecking = false }
        do {
            try baseline.validate()
            let remote = try await fetch()
            try Task.checkCancellation()
            guard HermesCompatibilityContract.validRevision(remote.revision) else {
                throw HermesCompatibilityContract.Failure.invalidRevision
            }
            let detected = try await Task.detached(priority: .utility) {
                let signatures = try HermesCompatibilityContract.signatures(data: remote.contract)
                return HermesCompatibilityContract.changes(baseline: baseline, current: signatures)
            }.value
            try Task.checkCancellation()
            changes = detected
            upstreamRevision = remote.revision
            checkedAt = Date()
            error = nil
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            self.error =
                "Upstream check unavailable. " + HermesDiagnosticsService.safeSummary(error.localizedDescription)
        }
    }

    nonisolated static func fetchUpstream() async throws -> HermesCompatibilityRemote {
        let head = try await readURL("https://api.github.com/repos/NousResearch/hermes-agent/commits/main")
        guard let object = try JSONSerialization.jsonObject(with: head) as? [String: Any],
            let revision = object["sha"] as? String, HermesCompatibilityContract.validRevision(revision)
        else { throw HermesCompatibilityContract.Failure.invalidRevision }
        // Pin both reads to one immutable commit, even if main moves during this check.
        let contract = try await readURL(
            "https://raw.githubusercontent.com/NousResearch/hermes-agent/\(revision)/apps/shared/src/gateway-contract.openrpc.json"
        )
        return HermesCompatibilityRemote(revision: revision, contract: contract)
    }

    nonisolated private static func readURL(_ address: String) async throws -> Data {
        guard let url = URL(string: address) else { throw URLError(.badURL) }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        guard data.count <= 8_388_608 else { throw URLError(.dataLengthExceedsMaximum) }
        return data
    }
}
