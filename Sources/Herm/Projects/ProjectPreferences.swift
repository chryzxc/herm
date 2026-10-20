import CryptoKit
import Foundation

struct ProjectAction: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var command: String
    var directory = "."
    var isSetup: Bool? = nil
    func workingDirectory(project: String) throws -> String {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !directory.hasPrefix("/"), !directory.split(separator: "/").contains("..")
        else {
            throw QuickDraftError.message("Enter a name, command, and a directory inside the project.")
        }
        let root = URL(fileURLWithPath: project).resolvingSymlinksInPath().standardizedFileURL
        let destination = root.appendingPathComponent(directory).resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard destination == root || destination.path.hasPrefix(root.path + "/"),
            FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory), isDirectory.boolValue
        else {
            throw QuickDraftError.message("The action directory is unavailable or outside this project.")
        }
        return destination.path
    }
}

@MainActor
final class ProjectPreferences: ObservableObject {
    static let shared = ProjectPreferences()
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    private func key(_ path: String) -> String {
        let canonical = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return "herm.project." + SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func actions(_ path: String) -> [ProjectAction] {
        guard let data = defaults.data(forKey: key(path) + ".actions") else { return [] }
        return (try? JSONDecoder().decode([ProjectAction].self, from: data)) ?? []
    }
    func save(_ actions: [ProjectAction], path: String) throws {
        defaults.set(try JSONEncoder().encode(actions), forKey: key(path) + ".actions")
        objectWillChange.send()
    }
    func modelID(_ path: String) -> String? { defaults.string(forKey: key(path) + ".model") }
    func setModel(_ id: String?, path: String) {
        defaults.set(id, forKey: key(path) + ".model")
        objectWillChange.send()
    }
}
