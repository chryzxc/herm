import Combine
import Foundation

enum KokoroVoice {
    static let presets: [(id: String, name: String, language: String)] = [
        ("af_heart", "Heart · US English", "en-us"),
        ("af_bella", "Bella · US English", "en-us"),
        ("am_adam", "Adam · US English", "en-us"),
        ("am_michael", "Michael · US English", "en-us"),
        ("bf_emma", "Emma · UK English", "en-gb"),
        ("bm_george", "George · UK English", "en-gb"),
    ]

    static var available: Bool {
        #if arch(arm64)
            true
        #else
            false
        #endif
    }

    static var installer: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ["/opt/homebrew/bin/uv", "/usr/local/bin/uv", home.appendingPathComponent(".local/bin/uv").path]
            .first(where: FileManager.default.isExecutableFile(atPath:))
    }

    static let root = URL.applicationSupportDirectory.appendingPathComponent("Herm/Voice/Kokoro-v1", isDirectory: true)
    private static let python = root.appendingPathComponent("runtime/bin/python")
    private static let ready = root.appendingPathComponent("ready")

    static var installed: Bool {
        available && FileManager.default.isExecutableFile(atPath: python.path)
            && ["ready", "kokoro-v1.0.int8.onnx", "voices-v1.0.bin"].allSatisfy {
                FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path)
            }
    }

    static func resolvedPreset(_ id: String) -> (id: String, name: String, language: String) {
        presets.first(where: { $0.id == id }) ?? presets[0]
    }

    private static func program() throws -> URL {
        guard let url = Bundle.herm.url(forResource: "kokoro_voice", withExtension: "py", subdirectory: "Voice")
        else { throw Failure.unavailable }
        return url
    }

    private static var environment: [String: String] {
        [
            "PATH": "/usr/bin:/bin",
            "PYTHONNOUSERSITE": "1",
            "UV_CACHE_DIR": root.appendingPathComponent("cache").path,
            "UV_PYTHON_INSTALL_DIR": root.appendingPathComponent("python").path,
            "UV_NO_PROGRESS": "1",
        ]
    }

    static func install() async throws {
        guard available, let installer else { throw Failure.unavailable }
        let program = try program()
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        if FileManager.default.fileExists(atPath: ready.path) { try FileManager.default.removeItem(at: ready) }
        let arguments = [
            "--no-config", "venv", "--allow-existing", "--python", "3.12",
            root.appendingPathComponent("runtime").path,
        ]
        try await run(installer, arguments, timeout: 180)
        try await run(
            installer,
            [
                "--no-config", "pip", "install", "--python", python.path,
                "--index-url", "https://pypi.org/simple", "--only-binary", ":all:", "kokoro-onnx==0.6.1",
            ], timeout: 300)
        try await run(python.path, ["-I", program.path, "prepare", root.path], timeout: 900)
        try Task.checkCancellation()
        try Data().write(to: ready, options: .atomic)
    }

    @MainActor static func prewarmIfSelected() {
        guard VoiceSpeechEngine.current == .kokoro, installed else { return }
        try? prepareWorker()
    }

    @MainActor static func synthesize(_ text: String, voice: String, speed: Double) async throws -> Data {
        try Task.checkCancellation()
        guard installed, text.utf8.count <= 1_024 else { throw Failure.unavailable }
        try prepareWorker()
        let preset = resolvedPreset(voice)
        let request = Request(text: text, voice: preset.id, language: preset.language, speed: speed)
        return try await KokoroVoiceWorker.shared.speak(JSONEncoder().encode(request))
    }

    @MainActor private static func prepareWorker() throws {
        try KokoroVoiceWorker.shared.prepare(
            executable: python,
            arguments: ["-I", try program().path, "serve", root.path], environment: environment)
    }

    private static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) async throws {
        let output = try await HermesLocalProcess.capture(
            executable, arguments: arguments, timeout: timeout,
            environment: environment)
        guard output.code == 0 else { throw Failure.installation }
    }

    private struct Request: Encodable {
        let text: String
        let voice: String
        let language: String
        let speed: Double
    }

    enum Failure: Error { case unavailable, installation }
}

@MainActor
final class KokoroVoiceSetup: ObservableObject {
    static let shared = KokoroVoiceSetup()
    @Published private(set) var installing = false
    @Published private(set) var failed = false

    func install() {
        guard !installing else { return }
        failed = false
        installing = true
        KokoroVoiceWorker.shared.close()
        Task {
            defer { installing = false }
            do { try await KokoroVoice.install() } catch { failed = true }
        }
    }
}
