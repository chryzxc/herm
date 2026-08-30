import Foundation

/// Lifecycle state supplied by a verified read-only Hermes snapshot.
enum SkillLifecycleState: String, Codable, Equatable, Sendable {
    case ready
    case running
    case paused
    case idle
    case unavailable
    case unsupported
    case malformed
    case stale
    case builtIn = "built-in"
    case disabled
}

enum SkillInputFormat: Sendable { case json, humanTable }
enum SkillMutation: Sendable { case install, configure, bundleChange, curatorMutation, memoryWrite }
enum SkillMutationAvailability: Equatable, Sendable { case unavailable }

enum SkillInventoryState: Equatable, Sendable { case ready, unavailable, unsupported, malformed }

struct SkillSummary: Decodable, Equatable, Sendable, Identifiable {
    let id: String
    let name: String
    let source: String
    let isInstalled: Bool
    let isEnabled: Bool

    private enum Keys: String, CodingKey, CaseIterable { case id, name, source, installed, enabled }
    init(id: String, name: String, source: String, installed: Bool, enabled: Bool) {
        self.id = id; self.name = name; self.source = source
        self.isInstalled = installed; self.isEnabled = enabled
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        guard c.allKeys.allSatisfy({ Keys.allCases.contains($0) }), c.allKeys.count == Keys.allCases.count else { throw SkillParseError.invalid }
        self.init(id: try c.decodeBoundedString(.id), name: try c.decodeBoundedString(.name), source: try c.decodeBoundedString(.source), installed: try c.decode(Bool.self, forKey: .installed), enabled: try c.decode(Bool.self, forKey: .enabled))
    }
}

struct SkillBundleSummary: Decodable, Equatable, Sendable, Identifiable {
    let id: String
    let name: String
    let isInstalled: Bool
    let isEnabled: Bool
    private enum Keys: String, CodingKey, CaseIterable { case id, name, installed, enabled }
    init(id: String, name: String, installed: Bool, enabled: Bool) { self.id = id; self.name = name; self.isInstalled = installed; self.isEnabled = enabled }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        guard c.allKeys.allSatisfy({ Keys.allCases.contains($0) }), c.allKeys.count == Keys.allCases.count else { throw SkillParseError.invalid }
        self.init(id: try c.decodeBoundedString(.id), name: try c.decodeBoundedString(.name), installed: try c.decode(Bool.self, forKey: .installed), enabled: try c.decode(Bool.self, forKey: .enabled))
    }
}

struct CuratorStatus: Decodable, Equatable, Sendable {
    let status: SkillLifecycleState
    private enum Keys: String, CodingKey, CaseIterable { case status }
    init(status: SkillLifecycleState) { self.status = status }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        guard c.allKeys.allSatisfy({ Keys.allCases.contains($0) }), c.allKeys.count == 1 else { throw SkillParseError.invalid }
        self.status = try c.decode(SkillLifecycleState.self, forKey: .status)
    }
}

struct MemoryStatus: Decodable, Equatable, Sendable {
    let status: SkillLifecycleState
    private enum Keys: String, CodingKey, CaseIterable { case status }
    init(status: SkillLifecycleState) { self.status = status }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        guard c.allKeys.allSatisfy({ Keys.allCases.contains($0) }), c.allKeys.count == 1 else { throw SkillParseError.invalid }
        self.status = try c.decode(SkillLifecycleState.self, forKey: .status)
    }
}

struct SkillInventory: Equatable, Sendable {
    let state: SkillInventoryState
    let skills: [SkillSummary]
    let bundles: [SkillBundleSummary]
    let curator: CuratorStatus
    let memory: MemoryStatus
    let mutations: SkillMutationAvailability
    let diagnostic: String
}

struct SkillSearchResult: Equatable, Sendable, Identifiable {
    let id: String
    let name: String
    let source: String
    let isInstalled: Bool
    let isEnabled: Bool
}
struct SkillSearchResponse: Equatable, Sendable {
    let state: SkillInventoryState
    let query: String
    let results: [SkillSearchResult]
    let diagnostic: String
}

enum SkillParseError: Error { case invalid }

private extension KeyedDecodingContainer where Key: CodingKey {
    func decodeBoundedString(_ key: Key) throws -> String {
        let value = try decode(String.self, forKey: key)
        guard value.count <= 128, !value.isEmpty,
              !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }),
              !SkillSafety.isForbidden(value) else { throw SkillParseError.invalid }
        return value
    }
}

enum SkillSafety {
    static func isForbidden(_ value: String) -> Bool {
        let lower = value.lowercased()
        return lower.contains("http://") || lower.contains("https://") || lower.contains("token") || lower.contains("prompt") || lower.contains("content") || lower.contains("secret") || lower.contains("credential") || value.contains("/") || value.contains("\\")
    }
}
