import CryptoKit
import Foundation

/// A reviewed source snapshot, not a declaration that a runtime passed integration tests.
struct HermesCompatibilityBaseline: Codable, Sendable {
    struct ReviewItem: Codable, Identifiable, Sendable {
        let id: String
        let title: String
        let detail: String
        let source: String
    }

    let formatVersion: Int
    let revision: String
    let reviewedAt: String
    let trackedMethods: [String]
    let signatures: [String: String]
    let backlog: [ReviewItem]

    func validate() throws {
        guard formatVersion == 1, HermesCompatibilityContract.validRevision(revision),
            !signatures.isEmpty, !trackedMethods.isEmpty
        else { throw HermesCompatibilityContract.Failure.invalidBaseline }
    }
}

enum HermesCompatibilityContract {
    enum Failure: Error { case invalidBaseline, invalidContract, invalidRevision }

    struct Change: Identifiable, Equatable, Sendable {
        enum Kind: String, Sendable { case removed, changed, added }
        let id: String
        let kind: Kind
        var name: String { String(id.drop(while: { $0 != ":" }).dropFirst()) }
    }

    static func validRevision(_ value: String) -> Bool {
        value.count == 40 && value.allSatisfy { "0123456789abcdef".contains($0) }
    }

    /// Include transitive schemas: an unchanged method name can still acquire a breaking payload.
    /// Prose-only edits are excluded; defaults, required fields, enums and closed shapes are retained.
    static func signatures(data: Data) throws -> [String: String] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let components = root["components"] as? [String: Any],
            let schemas = components["schemas"] as? [String: Any],
            let methods = root["methods"] as? [[String: Any]], !methods.isEmpty
        else { throw Failure.invalidContract }
        var result: [String: String] = [:]
        for (section, prefix) in [
            ("methods", "rpc"), ("x-canonical-methods", "canonical"),
            ("x-server-requests", "request"), ("x-notifications", "event"),
        ] {
            guard let entries = root[section] as? [[String: Any]] else { throw Failure.invalidContract }
            for entry in entries {
                guard let name = entry["name"] as? String, !name.isEmpty, name.count <= 200,
                    name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "_.-".contains($0)) })
                else { throw Failure.invalidContract }
                let key = "\(prefix):\(name)"
                guard result[key] == nil else { throw Failure.invalidContract }
                var dependencies: [String: Any] = [:]
                try collect(entry, schemas: schemas, dependencies: &dependencies)
                let shape: [String: Any] = ["method": structural(entry), "schemas": dependencies]
                let bytes = try JSONSerialization.data(
                    withJSONObject: shape, options: [.sortedKeys, .withoutEscapingSlashes])
                result[key] = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            }
        }
        return result
    }

    private static func structural(_ value: Any) -> Any {
        if let object = value as? [String: Any] {
            var result: [String: Any] = [:]
            for (key, child) in object where !["description", "summary", "title", "examples"].contains(key) {
                if ["properties", "patternProperties", "$defs"].contains(key), let fields = child as? [String: Any] {
                    result[key] = fields.mapValues { structural($0) }
                } else {
                    result[key] = structural(child)
                }
            }
            return result
        }
        if let array = value as? [Any] { return array.map { structural($0) } }
        return value
    }

    private static func collect(_ value: Any, schemas: [String: Any], dependencies: inout [String: Any]) throws {
        if let object = value as? [String: Any] {
            if let reference = object["$ref"] as? String {
                let prefix = "#/components/schemas/"
                guard reference.hasPrefix(prefix), let schema = schemas[String(reference.dropFirst(prefix.count))]
                else { throw Failure.invalidContract }
                let name = String(reference.dropFirst(prefix.count))
                if dependencies[name] == nil {
                    dependencies[name] = structural(schema)
                    try collect(schema, schemas: schemas, dependencies: &dependencies)
                }
            }
            for child in object.values {
                try collect(child, schemas: schemas, dependencies: &dependencies)
            }
        } else if let array = value as? [Any] {
            for child in array { try collect(child, schemas: schemas, dependencies: &dependencies) }
        }
    }

    static func changes(baseline: HermesCompatibilityBaseline, current: [String: String]) -> [Change] {
        let used = Set(baseline.trackedMethods)
        let relevant = baseline.signatures.keys.filter { key in
            key.hasPrefix("event:") || key.hasPrefix("request:")
                || used.contains(String(key.drop(while: { $0 != ":" }).dropFirst()))
        }
        var changes = relevant.compactMap { key -> Change? in
            guard current[key] != baseline.signatures[key] else { return nil }
            return Change(id: key, kind: current[key] == nil ? .removed : .changed)
        }
        changes += current.keys.filter { baseline.signatures[$0] == nil }.map { Change(id: $0, kind: .added) }
        let order: [Change.Kind: Int] = [.removed: 0, .changed: 1, .added: 2]
        return changes.sorted {
            if $0.kind != $1.kind { return order[$0.kind, default: 0] < order[$1.kind, default: 0] }
            return $0.id < $1.id
        }
    }
}
