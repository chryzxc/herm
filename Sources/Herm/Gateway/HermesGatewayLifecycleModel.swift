import Foundation
import Combine

/// Local messaging gateway, independent of Herm's `hermes serve` connection.
/// Always targets the default profile (the host gateway), never a selected chat.
enum HermesGatewayCommand: Sendable {
    case status, restart

    var arguments: [String] {
        ["hermes", "-p", "default", "gateway", self == .status ? "status" : "restart"]
    }

    var timeout: TimeInterval { self == .status ? 15 : 90 }
}

struct HermesGatewayProcessStatus: Equatable, Sendable {
    enum State: String, Sendable {
        case running = "Running"
        case stopped = "Stopped"
        case unavailable = "Status unavailable"
    }

    var state: State = .unavailable
    var isManaged = false
    var processID: Int?

    /// Recognize only verified macOS CLI messages. Exit zero alone does not
    /// mean running; a registered launchd definition alone does not either.
    static func parse(_ output: String) -> Self {
        let clean = output.replacingOccurrences(of: "\u{001B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
        let primary = clean.components(separatedBy: "Other profiles:")[0]
        let lines = primary.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        let managed = lines.contains { $0.hasPrefix("Launchd plist: ") && $0.hasSuffix("/ai.hermes.gateway.plist") }
        let running = lines.first { line in
            line.range(of: #"^(?:✓ Gateway is supervised by launchd|✓ Gateway is running|✓ Detached fallback process is running|Detached gateway process is running|Note: a detached gateway process is running) \(PID:? [1-9][0-9]*(?:, [1-9][0-9]*)*\)$"#, options: .regularExpression) != nil
        }
        if let running, let range = running.range(of: #"[1-9][0-9]*"#, options: .regularExpression) {
            return Self(state: .running, isManaged: managed, processID: Int(running[range]))
        }
        if lines.contains("✗ Gateway is not running") || lines.contains("✗ No fallback process is running") || lines.contains("✗ Gateway service is not loaded") {
            return Self(state: .stopped, isManaged: managed)
        }
        return Self(state: .unavailable, isManaged: managed)
    }
}

struct HermesGatewayCommandResult: Sendable {
    var succeeded: Bool
    var output: String = ""
}

@MainActor
final class HermesGatewayLifecycleModel: ObservableObject {
    @Published private(set) var status = HermesGatewayProcessStatus()
    @Published private(set) var isRefreshing = false
    @Published private(set) var isRestarting = false
    @Published private(set) var hasChecked = false
    @Published private(set) var error: String?

    private let run: (HermesGatewayCommand) async -> HermesGatewayCommandResult
    private let pause: () async -> Void

    init(
        pause: @escaping () async -> Void = { try? await Task.sleep(for: .seconds(2)) },
        run: @escaping (HermesGatewayCommand) async -> HermesGatewayCommandResult = HermesGatewayLifecycleModel.runCommand
    ) {
        self.run = run
        self.pause = pause
    }

    var canRestart: Bool { status.isManaged && !isRefreshing && !isRestarting }
    var label: String { isRestarting ? "Restarting…" : (hasChecked ? status.state.rawValue : "Checking…") }
    var detail: String {
        if let error { return error }
        if isRestarting { return "Waiting for the default-profile messaging gateway to restart." }
        if !hasChecked { return "Checking the default-profile messaging gateway." }
        if status.state == .unavailable { return "Hermes did not return a recognized process status. Refresh to check again." }
        if !status.isManaged { return "UI restart requires a Hermes launchd service. Manage manual gateways in Terminal." }
        return "Default-profile messaging gateway · checked every 15 seconds while visible."
    }

    func refresh() async {
        guard !isRefreshing, !isRestarting else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        await readStatus()
    }

    func restart() async {
        guard canRestart else { return }
        isRestarting = true
        error = nil
        defer { isRestarting = false }

        // Recheck ownership before launching: a manual gateway restart can run
        // in the foreground indefinitely on some Hermes releases.
        await readStatus()
        guard status.isManaged else {
            error = "Restart unavailable: Hermes could not verify a launchd service. Refresh and try again."
            return
        }
        let previousProcessID = status.processID
        let result = await run(.restart)
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        for attempt in 0..<15 {
            await readStatus()
            if !result.succeeded || restartVerified(previousProcessID) { break }
            if attempt == 14 || ContinuousClock.now >= deadline || Task.isCancelled { break }
            await pause()
        }
        if !result.succeeded {
            error = "Gateway restart failed or timed out. Check `hermes gateway status` in Terminal, then retry."
        } else if !restartVerified(previousProcessID) {
            error = "Restart command finished, but a replacement gateway is not confirmed running. Refresh to check again."
        }
    }

    private func restartVerified(_ previousProcessID: Int?) -> Bool {
        status.state == .running && status.processID != previousProcessID
    }

    private func readStatus() async {
        let result = await run(.status)
        hasChecked = true
        status = result.succeeded ? .parse(result.output) : .init()
        // A restart error remains visible through automatic status refreshes.
        if !result.succeeded && error == nil {
            error = "Gateway status could not be read. Check that the Hermes CLI is installed and try refreshing."
        } else if result.succeeded && error?.hasPrefix("Gateway status could not") == true {
            error = nil
        }
    }

    /// Run outside the gateway so restarting it cannot sever the command's
    /// transport. File output avoids pipe backpressure and inherited-pipe hangs.
    nonisolated static func runCommand(_ command: HermesGatewayCommand) async -> HermesGatewayCommandResult {
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("herm-gateway-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { return .init(succeeded: false) }
        defer { try? FileManager.default.removeItem(at: outputURL) }
        guard let output = try? FileHandle(forUpdating: outputURL) else { return .init(succeeded: false) }
        defer { try? output.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = command.arguments
        process.environment = HermesEnvironment.processEnvironment()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return .init(succeeded: false) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(command.timeout))
        while process.isRunning, ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard !process.isRunning else {
            process.terminate()
            try? await Task.sleep(for: .milliseconds(200))
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            return .init(succeeded: false)
        }
        try? output.seek(toOffset: 0)
        let data = (try? output.read(upToCount: 65_536)) ?? Data()
        return .init(succeeded: process.terminationStatus == 0, output: String(decoding: data, as: UTF8.self))
    }
}
