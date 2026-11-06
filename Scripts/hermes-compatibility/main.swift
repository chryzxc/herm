import Foundation

// Compile with HermesCompatibilityContract.swift; the app and CI use the same comparison.
func read(_ address: String) async throws -> Data {
    guard let url = URL(string: address) else { throw URLError(.badURL) }
    let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 30))
    guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 8_388_608 else {
        throw URLError(.badServerResponse)
    }
    return data
}

func run() async throws {
    let arguments = CommandLine.arguments
    guard arguments.count == 4 || (arguments.count == 5 && arguments[4] == "--record-review") else {
        throw NSError(
            domain: "Compatibility", code: 1,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Usage: hermes-compatibility <baseline.json> <upstream-contract.json or --upstream> <revision> [--record-review]"
            ])
    }
    let baselineURL = URL(fileURLWithPath: arguments[1])
    let baseline = try JSONDecoder().decode(HermesCompatibilityBaseline.self, from: Data(contentsOf: baselineURL))
    try baseline.validate()
    let revision: String
    let contract: Data
    if arguments[2] == "--upstream" {
        let head = try await read("https://api.github.com/repos/NousResearch/hermes-agent/commits/main")
        guard let object = try JSONSerialization.jsonObject(with: head) as? [String: Any],
            let sha = object["sha"] as? String, HermesCompatibilityContract.validRevision(sha)
        else { throw HermesCompatibilityContract.Failure.invalidRevision }
        revision = sha
        contract = try await read(
            "https://raw.githubusercontent.com/NousResearch/hermes-agent/\(sha)/apps/shared/src/gateway-contract.openrpc.json"
        )
    } else {
        revision = arguments[3]
        guard HermesCompatibilityContract.validRevision(revision) else {
            throw HermesCompatibilityContract.Failure.invalidRevision
        }
        contract = try Data(contentsOf: URL(fileURLWithPath: arguments[2]))
    }
    let signatures = try HermesCompatibilityContract.signatures(data: contract)
    if arguments.count == 5 {
        let proposed = HermesCompatibilityBaseline(
            formatVersion: 1, revision: revision,
            reviewedAt: String(ISO8601DateFormatter().string(from: Date()).prefix(10)),
            trackedMethods: baseline.trackedMethods, signatures: signatures, backlog: baseline.backlog)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        print(String(decoding: try encoder.encode(proposed), as: UTF8.self))
        return
    }
    let changes = HermesCompatibilityContract.changes(baseline: baseline, current: signatures)
    print("# Hermes compatibility review")
    print("\nReviewed baseline: `\(baseline.revision)` (\(baseline.reviewedAt)).")
    print("Upstream checked: `\(revision)`.")
    print(
        "\nThis is contract drift detection, not runtime certification. HTTP, CLI and behavioral changes need review too."
    )
    print("\n## Known work")
    for item in baseline.backlog {
        print("\n- [ ] \(item.title) — \(item.detail) [Evidence](\(item.source))")
    }
    print("\n## Changes since review")
    if changes.isEmpty { print("\nNo tracked structural contract changes detected. Known work remains open.") }
    for change in changes {
        let label = change.kind == .added ? "Feature candidate" : "Contract review: \(change.kind.rawValue)"
        print("\n- [ ] \(label): `\(change.id)`")
    }
    print(
        "\n[Inspect upstream](https://github.com/NousResearch/hermes-agent/compare/\(baseline.revision)...\(revision))")
    print("\nBaseline advancement is a manual code review after relevant fixes and tests; this tool never advances it.")
}

do {
    try await run()
} catch {
    FileHandle.standardError.write(
        Data("Compatibility check failed; no report certified: \(error.localizedDescription)\n".utf8))
    exit(1)
}
