import Darwin
import Foundation

/// Framing is bounded before allocation; subprocess output is never treated as shell text.
struct HermesSimulatorPacketDecoder {
    static let maximumPayload = 32 * 1024 * 1024
    private var buffer = Data()

    mutating func append(_ data: Data) throws -> [(UInt8, Data)] {
        buffer.append(data)
        var packets: [(UInt8, Data)] = []
        while buffer.count >= 5 {
            let bytes = Array(buffer.prefix(5))
            let count = bytes.dropFirst().reduce(0) { ($0 << 8) | Int($1) }
            guard [UInt8(73), UInt8(74)].contains(bytes[0]), count <= Self.maximumPayload else {
                throw CocoaError(.fileReadCorruptFile)
            }
            guard buffer.count >= count + 5 else { break }
            packets.append((bytes[0], Data(buffer.dropFirst(5).prefix(count))))
            buffer.removeFirst(count + 5)
        }
        return packets
    }
}

@MainActor
final class HermesSimulatorBridge {
    private var process: Process?
    private var input: FileHandle?
    private var reader: Task<Void, Never>?
    private let writes = DispatchQueue(label: "Herm.simulator.input")

    static var python: URL {
        if let path = ProcessInfo.processInfo.environment["HERM_SIMULATOR_PYTHON"] {
            return URL(fileURLWithPath: path)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Herm/simulator-bridge/bin/python3")
    }

    /// What Scripts/setup-simulator-bridge.sh does: a private venv with gRPC, plus
    /// the bundled scripts the `herm-simulator` plugin runs. Only Macs with simulators or emulators get it.
    static func prepare() async {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        guard ProcessInfo.processInfo.environment["HERM_SIMULATOR_PYTHON"] == nil,
            ["Library/Developer/CoreSimulator/Devices", "Library/Android/sdk"].contains(where: {
                fm.fileExists(atPath: home.appendingPathComponent($0).path)
            }),
            let bundled = Bundle.herm.url(forResource: "SimulatorBridge", withExtension: nil)
        else { return }
        let root = python.deletingLastPathComponent().deletingLastPathComponent()
        guard
            await HermesSimulatorSetup.prepare(
                python: python, root: root, lock: bundled.appendingPathComponent("requirements.lock"),
                executable: fm.isExecutableFile(atPath: python.path), run: HermesBundledPlugins.run
            )
        else { return }
        let resources = root.appendingPathComponent("resources", isDirectory: true)
        try? fm.createDirectory(at: resources, withIntermediateDirectories: true)
        for file in (try? fm.contentsOfDirectory(atPath: bundled.path)) ?? [] where file.hasSuffix(".py") {
            let target = resources.appendingPathComponent(file)
            try? fm.removeItem(at: target)
            try? fm.copyItem(at: bundled.appendingPathComponent(file), to: target)
        }
    }

    func start(
        platform: String, device: String, boot: Bool = false,
        receive: @escaping @MainActor @Sendable (UInt8, Data) -> Void,
        ended: @escaping @MainActor @Sendable () -> Void
    ) throws {
        stop()
        guard FileManager.default.isExecutableFile(atPath: Self.python.path),
            let folder = Bundle.herm.url(forResource: "SimulatorBridge", withExtension: nil)
        else {
            throw NSError(
                domain: "HermSimulator", code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Herm is still setting up simulator controls. Wait a minute, then retry."
                ])
        }
        let child = Process()
        child.executableURL = Self.python
        child.arguments = [folder.appendingPathComponent("bridge.py").path, platform, device] + (boot ? ["boot"] : [])
        child.environment = ProcessInfo.processInfo.environment.merging(["PYTHONDONTWRITEBYTECODE": "1"]) { _, new in
            new
        }
        let output = Pipe()
        let inputPipe = try Self.protectedInputPipe()
        child.standardOutput = output
        child.standardInput = inputPipe
        child.standardError = FileHandle.nullDevice
        try child.run()
        process = child
        input = inputPipe.fileHandleForWriting
        let handle = output.fileHandleForReading
        reader = Task.detached {
            var decoder = HermesSimulatorPacketDecoder()
            var bytes = [UInt8](repeating: 0, count: 64 * 1024)
            do {
                while !Task.isCancelled {
                    // A static Android display may emit only one frame; never wait to fill a read buffer.
                    let count = Darwin.read(handle.fileDescriptor, &bytes, bytes.count)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { break }
                    for (kind, payload) in try decoder.append(Data(bytes.prefix(count))) {
                        guard !Task.isCancelled else { break }
                        await receive(kind, payload)
                    }
                }
            } catch {}
            try? handle.close()
            if !Task.isCancelled { await ended() }
        }
    }

    /// Discovery helpers can exit before a queued release-input write reaches the pipe.
    static func protectedInputPipe() throws -> Pipe {
        let pipe = Pipe()
        guard fcntl(pipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return pipe
    }

    func send(_ event: [String: Any]) {
        guard let input, let data = try? JSONSerialization.data(withJSONObject: event) else { return }
        writes.async { try? input.write(contentsOf: data + Data([10])) }
    }

    func stop() {
        reader?.cancel()
        reader = nil
        if let input {
            writes.async { try? input.close() }
        }
        input = nil
        if let process, process.isRunning {
            // EOF releases held input and shuts down only the bridge-owned iOS companion.
            Task.detached {
                try? await Task.sleep(for: .seconds(4))
                if process.isRunning { process.terminate() }
            }
        }
        process = nil
    }
}
