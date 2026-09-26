import Foundation

/// Read-only adapter for the bounded, verified skill projection.
enum HermesSkillService {
    static func parse(_ output: String, format: SkillInputFormat) -> SkillInventory {
        guard format == .json else {
            return unavailableInventory(state: .unsupported, diagnostic: "Human-readable skill output is unsupported.")
        }
        do { return try parseVerifiedJSON(output) }
        catch { return unavailableInventory(state: .malformed, diagnostic: "Structured skill inventory was malformed.") }
    }

    static func parseVerifiedJSON(_ output: String) throws -> SkillInventory {
        guard let data = output.data(using: .utf8) else { throw SkillParseError.invalid }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(root.keys) == Set(["schema", "skills", "bundles", "curator", "memory"]),
              let rawSkills = root["skills"] as? [[String: Any]],
              rawSkills.allSatisfy({ Set($0.keys) == Set(["id", "name", "source", "installed", "enabled"]) }),
              let rawBundles = root["bundles"] as? [[String: Any]],
              rawBundles.allSatisfy({ Set($0.keys) == Set(["id", "name", "installed", "enabled"]) }),
              (root["curator"] as? [String: Any]).map({ Set($0.keys) == Set(["status"]) }) == true,
              (root["memory"] as? [String: Any]).map({ Set($0.keys) == Set(["status"]) }) == true else { throw SkillParseError.invalid }
        let value = try JSONDecoder().decode(InventoryFixture.self, from: data)
        guard value.skills.count <= 256, value.bundles.count <= 64,
              uniqueIDs(value.skills.map(\.id)), uniqueIDs(value.bundles.map(\.id)) else { throw SkillParseError.invalid }
        return SkillInventory(state: .ready, skills: value.skills, bundles: value.bundles,
                              curator: value.curator, memory: value.memory,
                              mutations: .unavailable, diagnostic: "")
    }

    static func unavailable(reason: String = "Skill inventory is unavailable.") -> SkillInventory {
        unavailableInventory(state: .unavailable, diagnostic: safeDiagnostic(reason))
    }

    static func search(_ query: String, output: String, format: SkillInputFormat) -> SkillSearchResponse {
        guard format == .json else {
            return SkillSearchResponse(state: .unsupported, query: query, results: [], diagnostic: "Human-readable skill output is unsupported.")
        }
        do {
            guard query.count <= 128, !query.isEmpty, !SkillSafety.isForbidden(query) else { throw SkillParseError.invalid }
            guard let root = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any],
                  Set(root.keys) == Set(["schema", "query", "results"]),
                  let rawResults = root["results"] as? [[String: Any]],
                  rawResults.allSatisfy({ Set($0.keys) == Set(["id", "name", "source", "installed", "enabled"]) }) else { throw SkillParseError.invalid }
            let fixture = try JSONDecoder().decode(SearchFixture.self, from: Data(output.utf8))
            guard fixture.query == query, fixture.results.count <= 256 else { throw SkillParseError.invalid }
            return SkillSearchResponse(state: .ready, query: query,
                                       results: fixture.results.map { SkillSearchResult(id: $0.id, name: $0.name, source: $0.source, isInstalled: $0.isInstalled, isEnabled: $0.isEnabled) }, diagnostic: "")
        } catch {
            return SkillSearchResponse(state: .malformed, query: query, results: [], diagnostic: "Structured skill search was malformed.")
        }
    }

    static func capability(_ mutation: SkillMutation) -> SkillMutationAvailability { .unavailable }

    private static func uniqueIDs(_ ids: [String]) -> Bool {
        Set(ids).count == ids.count
    }

    private static func unavailableInventory(state: SkillInventoryState, diagnostic: String) -> SkillInventory {
        SkillInventory(state: state, skills: [], bundles: [],
                       curator: CuratorStatus(status: .unavailable),
                       memory: MemoryStatus(status: .unavailable),
                       mutations: .unavailable,
                       diagnostic: String(diagnostic.prefix(160)))
    }

    private static func safeDiagnostic(_ reason: String) -> String {
        SkillSafety.isForbidden(reason) ? "Skill inventory is unavailable." : String(reason.prefix(160))
    }
}

private struct InventoryFixture: Decodable {
    let skills: [SkillSummary]
    let bundles: [SkillBundleSummary]
    let curator: CuratorStatus
    let memory: MemoryStatus
    private enum Keys: String, CodingKey, CaseIterable { case schema, skills, bundles, curator, memory }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        guard c.allKeys.allSatisfy({ Keys.allCases.contains($0) }), c.allKeys.count == Keys.allCases.count,
              try c.decode(String.self, forKey: .schema) == "hermes.skills.inventory.v1" else { throw SkillParseError.invalid }
        skills = try c.decode([SkillSummary].self, forKey: .skills)
        bundles = try c.decode([SkillBundleSummary].self, forKey: .bundles)
        curator = try c.decode(CuratorStatus.self, forKey: .curator)
        memory = try c.decode(MemoryStatus.self, forKey: .memory)
    }
}

private struct SearchFixture: Decodable {
    let query: String
    let results: [SkillSummary]
    private enum Keys: String, CodingKey, CaseIterable { case schema, query, results }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        guard c.allKeys.allSatisfy({ Keys.allCases.contains($0) }), c.allKeys.count == Keys.allCases.count,
              try c.decode(String.self, forKey: .schema) == "hermes.skills.search.v1" else { throw SkillParseError.invalid }
        query = try c.decode(String.self, forKey: .query)
        results = try c.decode([SkillSummary].self, forKey: .results)
    }
}
