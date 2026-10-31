import Foundation

/// Installs the Hermes plugins bundled in `Resources/HermesPlugins` into a local Hermes through its own
/// `plugins.manage install`, then prepares the simulator bridge the `herm-simulator` plugin drives.
/// Hermes installs only from Git, so each plugin is staged as a one-commit local repository first.
@MainActor
enum HermesBundledPlugins {
    static let names = ["herm", "herm-simulator"]
    private static var task: Task<Void, Never>?

    /// Once per launch; a failure retries on the next connection.
    static func ensure(client: HermesRPCClientProtocol) {
        guard task == nil else { return }
        task = Task {
            // The Command Line Tools provide git and python3; without them their shims prompt an install.
            guard await run("/usr/bin/xcode-select", ["-p"]) else {
                DebugLog.write("plugins: Command Line Tools unavailable; bundled plugins not installed")
                return
            }
            let installed = await install(client: client)
            await HermesSimulatorBridge.prepare()
            if !installed { task = nil }
        }
    }

    static func manifestVersion(_ manifest: String) -> String {
        manifest.split(separator: "\n").lazy.compactMap { line -> String? in
            guard line.hasPrefix("version:") else { return nil }
            return line.dropFirst("version:".count).trimmingCharacters(in: .whitespaces)
        }.first ?? ""
    }

    /// Bundled is the source of truth: a missing or different version is replaced.
    static func needsInstall(bundled: String, installed: String?) -> Bool {
        !bundled.isEmpty && installed != bundled
    }

    private static func install(client: HermesRPCClientProtocol) async -> Bool {
        guard let folder = Bundle.module.url(forResource: "HermesPlugins", withExtension: nil) else { return false }
        let rpc = HermesWorkflowRPC(client: client, profileID: nil)
        do {
            let rows = try await rpc.plugins()
            for name in names {
                let source = folder.appendingPathComponent(name, isDirectory: true)
                let version = manifestVersion(
                    try String(contentsOf: source.appendingPathComponent("plugin.yaml"), encoding: .utf8))
                let row = rows.first { $0.name == name }
                guard needsInstall(bundled: version, installed: row?.version) else { continue }
                let repository = try await stage(source, name: name)
                // Keep the user's on/off choice for a plugin they already have.
                try await rpc.installPlugin(identifier: repository.absoluteString, enable: row?.enabled ?? true)
                DebugLog.write("plugins: installed bundled \(name) \(version)")
            }
            return true
        } catch {
            DebugLog.write(
                "plugins: bundled install failed: \(HermesDiagnosticsService.safeSummary(error.localizedDescription))")
            return false
        }
    }

    private static func stage(_ source: URL, name: String) async throws -> URL {
        let fm = FileManager.default
        let target = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Herm/HermesPlugins/\(name)", isDirectory: true)
        try? fm.removeItem(at: target)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        for file in try fm.contentsOfDirectory(atPath: source.path)
        where !file.hasPrefix("test_") && !file.hasPrefix(".") && file != "__pycache__" {
            try fm.copyItem(at: source.appendingPathComponent(file), to: target.appendingPathComponent(file))
        }
        let git = ["-C", target.path, "-c", "user.name=Herm", "-c", "user.email=herm@localhost"]
        guard await run("/usr/bin/git", git + ["init", "-q"]),
            await run("/usr/bin/git", git + ["add", "-A"]),
            await run("/usr/bin/git", git + ["commit", "-q", "-m", name])
        else { throw CocoaError(.fileWriteUnknown) }
        return target
    }

    /// Runs without a shell; true on exit 0. Output is discarded.
    @discardableResult
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 60) async -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return await withCheckedContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus == 0) }
            do { try process.run() } catch {
                process.terminationHandler = nil
                return continuation.resume(returning: false)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [process] in
                if process.isRunning { process.terminate() }
            }
        }
    }
}
