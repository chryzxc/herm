import Foundation

/// Profile-scoped contracts shared with Hermes Desktop. Hermes owns all assets and selection.
@MainActor
struct HermesPetService {
    let client: HermesRPCClientProtocol
    let profile: String?

    func request(_ method: HermesFeatureIDs.ID, _ values: [String: Any] = [:]) async throws -> [String: Any] {
        var params = values
        if let profile { params["profile"] = profile }
        let result = try await client.request(method.rawValue, params: params)
        guard result["error"] == nil, result["ok"] as? Bool != false else { throw HermesPetError.invalidResponse }
        return result
    }
}

enum HermesPetError: Error { case invalidResponse, invalidImage }

struct HermesPetInfo: Decodable, Equatable, Sendable {
    var enabled: Bool
    var slug: String?
    var displayName: String?
    var mime: String?
    var spritesheetBase64: String?
    var spritesheetRevision: String?
    var spritesheetUnchanged: Bool?
    var frameW: Int?
    var frameH: Int?
    var framesPerState: Int?
    var framesByState: [String: Int]?
    var framesByRow: [String: Int]?
    var loopMs: Int?
    var scale: Double?
    var stateRows: [String]?

    static func decode(_ raw: [String: Any]) throws -> Self {
        let value = try JSONDecoder().decode(Self.self, from: JSONSerialization.data(withJSONObject: raw))
        guard [value.slug, value.displayName].compactMap({ $0 }).allSatisfy(HermesPetGallery.safeLabel),
            !value.enabled || (value.slug != nil && value.displayName != nil),
            value.scale.map({ $0.isFinite && (0.1...3).contains($0) }) ?? true
        else { throw HermesPetError.invalidResponse }
        return value
    }

    static let defaultRows = [
        "idle", "running-right", "running-left", "waving", "jumping", "failed", "waiting", "running", "review",
    ]

    func frame(for pose: String) -> (row: Int, count: Int) {
        let rows = stateRows ?? Self.defaultRows
        let aliases = ["wave": "waving", "run": "running", "jump": "jumping"]
        let row = rows.firstIndex(of: pose) ?? rows.firstIndex(of: aliases[pose] ?? pose)
        if let row {
            let count = framesByRow?[rows[row]] ?? framesByState?[pose] ?? framesPerState ?? 6
            if count > 0 { return (row, count) }
        }
        let idle = rows.firstIndex(of: "idle") ?? 0
        return (idle, max(1, framesByRow?["idle"] ?? framesByState?["idle"] ?? framesPerState ?? 6))
    }
}

struct HermesPetGallery: Decodable, Equatable, Sendable {
    struct Entry: Decodable, Equatable, Identifiable, Sendable {
        let slug: String
        let displayName: String
        let installed: Bool
        var spritesheetUrl: String?
        var curated: Bool?
        var id: String { slug }
    }
    let enabled: Bool
    let active: String
    let pets: [Entry]

    static func safeLabel(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256
            && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    static func decode(_ raw: [String: Any]) throws -> Self {
        let data = try JSONSerialization.data(withJSONObject: raw)
        guard data.count <= 8 * 1024 * 1024 else { throw HermesPetError.invalidResponse }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.pets.count <= 20_000, Set(value.pets.map(\.slug)).count == value.pets.count else {
            throw HermesPetError.invalidResponse
        }
        // One malformed community label must not hide every selectable pet.
        return Self(
            enabled: value.enabled, active: value.active,
            pets: value.pets.filter { safeLabel($0.slug) && safeLabel($0.displayName) })
    }

    func matches(_ query: String) -> [Entry] {
        pets.filter {
            query.isEmpty || $0.displayName.localizedCaseInsensitiveContains(query)
                || $0.slug.localizedCaseInsensitiveContains(query)
        }
        .sorted {
            func rank(_ entry: Entry) -> Int {
                (enabled && entry.slug == active ? 4 : 0) + (entry.installed ? 2 : 0) + (entry.curated == true ? 1 : 0)
            }
            return rank($0) == rank($1)
                ? $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending : rank($0) > rank($1)
        }
    }
}
