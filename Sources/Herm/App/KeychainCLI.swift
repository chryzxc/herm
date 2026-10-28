import Foundation

/// Keychain items kept through Apple's `security` tool rather than in-process SecItem calls. An
/// item Herm adds in-process trusts only the exact binary that made it, so every ad-hoc-signed
/// rebuild asks for the login password again; `security` keeps one signature across rebuilds.
enum KeychainCLI {
    /// errSecItemNotFound, as `security` reports it in its exit status.
    static let notFound: Int32 = 44

    static func run(_ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output, as: UTF8.self).trimmingCharacters(in: .newlines))
    }
}
