import Foundation

struct ReviewWorkspacePresentation: Codable {
    var scope: String
    var reference: String
    var file: String?
    var navigatorWidth: Double
}

struct ClosedInspectorReference: Codable {
    var kind: String
    var id: UUID?
    var url: String?
}

struct ExplorerPresentation: Codable {
    var selected: String?
    var openFile: String?
    var expandedDirectories: [String]
}

extension WorkspacePresentationStore {
    func loadReferences<Value: Decodable>(_ type: Value.Type, identity: String) -> Value? {
        defaultsData(identity).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }
    func saveReferences<Value: Encodable>(_ value: Value, identity: String) {
        if let data = try? JSONEncoder().encode(value) { saveData(data, identity: identity) }
    }
}
