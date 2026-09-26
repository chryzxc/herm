import Foundation

enum HermesEnvironment {
    static func processEnvironment(
        basedOn environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [String: String] {
        var environment = environment
        let userBin = homeDirectory.appendingPathComponent(".local/bin", isDirectory: true).path
        let currentPath = environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin"
        let pathEntries = currentPath.split(separator: ":", omittingEmptySubsequences: false).map(String.init)

        if !pathEntries.contains(userBin) {
            environment["PATH"] = ([userBin] + pathEntries).joined(separator: ":")
        }

        return environment
    }
}
