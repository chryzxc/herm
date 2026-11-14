import Foundation

@MainActor
enum HermesSimulatorSetup {
    static func prepare(
        python: URL, root: URL, lock: URL, executable: Bool,
        run: (String, [String], TimeInterval) async -> Bool
    ) async -> Bool {
        if !executable {
            guard await run("/usr/bin/python3", ["-m", "venv", root.path], 120) else {
                DebugLog.write("simulator: bridge environment could not be created")
                return false
            }
        }
        if !(await run(python.path, ["-c", "import grpc, google.protobuf"], 30)) {
            DebugLog.write("simulator: installing bridge packages")
            guard
                await run(
                    python.path,
                    [
                        "-m", "pip", "--isolated", "install", "-q", "--disable-pip-version-check",
                        "--require-hashes", "--only-binary=:all:", "--index-url", "https://pypi.org/simple", "-r",
                        lock.path,
                    ], 600)
            else {
                DebugLog.write("simulator: bridge package install failed")
                return false
            }
        }
        return true
    }
}
