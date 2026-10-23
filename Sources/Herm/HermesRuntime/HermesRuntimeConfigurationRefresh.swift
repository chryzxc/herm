import Foundation

/// One ephemeral refresh lane per DockModel. The CLI remains authoritative.
@MainActor
final class HermesRuntimeConfigurationRefresh {
    typealias Identity = @MainActor @Sendable (String?) async -> Void
    typealias Reader = @MainActor (@escaping Identity) async -> HermesRuntimeInspection

    private let clock: () -> TimeInterval
    private let scope: () -> String
    private let metadata: (String) async -> String?
    private let reader: Reader
    private var task: Task<Void, Never>?
    private var generation = 0
    private var pending = false
    private var cancellationRequested = false
    private var activeScope: String?
    private var configurationScope: String?
    private var hasCompleteConfiguration = false
    private var success:
        (configuration: HermesRuntimeConfiguration, instant: TimeInterval, scope: String, signature: String)?
    private(set) var configuration: HermesRuntimeConfiguration?
    private(set) var isLoading = false
    private(set) var error: String?
    var onChange: (() -> Void)?

    init(
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        scope: @escaping () -> String = { HermesRuntimeConfigurationRefresh.environmentScope() },
        metadata: @escaping (String) async -> String? = { await HermesRuntimeConfigurationRefresh.fileSignature($0) },
        reader: @escaping Reader = { identity in
            await Task.detached(priority: .utility) {
                HermesRuntimeInspector.inspect(onIdentity: { name in
                    Task { await identity(name) }
                })
            }.value
        }
    ) {
        self.clock = clock
        self.scope = scope
        self.metadata = metadata
        self.reader = reader
    }

    func refresh(force: Bool = false) async {
        let requestedScope = scope()
        if cancellationRequested {
            cancellationRequested = false
            pending = task != nil
        }
        if force || (activeScope != nil && activeScope != requestedScope) {
            generation &+= 1
            success = nil
            pending = task != nil
        }
        if let task {
            await task.value
            return
        }
        activeScope = requestedScope
        let work = Task { await self.run() }
        task = work
        await work.value
    }

    /// Invalidates callbacks without pretending Task cancellation terminates Process.
    func cancel() {
        generation &+= 1
        success = nil
        pending = false
        cancellationRequested = true
        error = "Hermes runtime inspection was cancelled. Try refreshing."
    }

    private func run() async {
        repeat {
            pending = false
            let token = generation
            let key = scope()
            activeScope = key
            if let configurationScope, configurationScope != key {
                configuration = nil
                success = nil
                error = nil
                self.configurationScope = nil
                hasCompleteConfiguration = false
                onChange?()
            }
            if let success, success.scope == key, clock() - success.instant < 30,
                let path = success.configuration.configPath,
                let signature = await metadata(path), signature == success.signature,
                token == generation, key == scope(), !Task.isCancelled
            {
                break
            }
            guard !Task.isCancelled, !cancellationRequested else { break }
            if token != generation || key != scope() {
                pending = true
                continue
            }
            success = nil
            isLoading = true
            error = nil
            onChange?()
            guard token == generation, key == scope(), !cancellationRequested else {
                pending = !cancellationRequested
                continue
            }
            let outcome = await reader { [weak self] name in
                guard let self, self.generation == token, self.scope() == key,
                    !Task.isCancelled, !self.cancellationRequested, let name
                else { return }
                self.configuration = Self.withIdentity(name, retaining: self.configuration)
                self.configurationScope = key
                self.onChange?()
            }
            let signature: String?
            if let path = outcome.configuration.configPath {
                signature = await metadata(path)
            } else {
                signature = nil
            }
            guard !Task.isCancelled, !cancellationRequested else { break }
            guard token == generation, key == scope() else {
                pending = true
                continue
            }
            if outcome.isComplete {
                configuration = outcome.configuration
                configurationScope = key
                hasCompleteConfiguration = true
                if let signature, outcome.initialSignature == signature {
                    success = (outcome.configuration, clock(), key, signature)
                }
                error = nil
            } else {
                // Preserve a useful complete projection across failed/partial reads.
                if !hasCompleteConfiguration {
                    configuration = outcome.configuration
                    configurationScope = key
                }
                error = "Hermes runtime inspection is unavailable or incomplete. Try refreshing."
            }
            onChange?()
        } while pending
        isLoading = false
        activeScope = nil
        task = nil
        onChange?()
    }

    static func withIdentity(_ name: String, retaining value: HermesRuntimeConfiguration?) -> HermesRuntimeConfiguration
    {
        HermesRuntimeConfiguration(
            agentName: name, model: value?.model, provider: value?.provider,
            configPath: value?.configPath, maxTurns: value?.maxTurns, terminalTimeout: value?.terminalTimeout,
            skills: value?.skills ?? [], skillsInventory: value?.skillsInventory ?? .unavailable(.emptyOutput),
            mcpServers: value?.mcpServers ?? [], plugins: value?.plugins ?? [])
    }

    nonisolated static func environmentScope() -> String {
        let environment = HermesEnvironment.processEnvironment()
        let path = environment["PATH"] ?? ""
        let executable =
            path.split(separator: ":", omittingEmptySubsequences: false)
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent("hermes") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }?
            .resolvingSymlinksInPath().path ?? ""
        return ([executable] + ["PATH", "HOME", "HERMES_HOME", "HERMES_PROFILE"].map { environment[$0] ?? "" })
            .map { "\($0.utf8.count):\($0)" }.joined()
    }

    nonisolated static func fileSignature(_ configPath: String) async -> String? {
        await Task.detached(priority: .utility) {
            fileSignatureNow(configPath)
        }.value
    }

    /// Synchronous only for the inspector's already-detached read boundary.
    nonisolated static func fileSignatureNow(_ configPath: String) -> String? {
        let config = URL(fileURLWithPath: configPath)
        let urls = [config, config.deletingLastPathComponent().appendingPathComponent("SOUL.md")]
        var parts: [String] = []
        for url in urls {
            do {
                let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
                guard let modified = attrs[.modificationDate] as? Date,
                    let size = attrs[.size] as? NSNumber,
                    let number = attrs[.systemFileNumber] as? NSNumber,
                    let device = attrs[.systemNumber] as? NSNumber
                else { return nil }
                parts.append("\(device):\(number):\(modified.timeIntervalSince1970):\(size)")
            } catch let error as NSError {
                guard error.domain == NSCocoaErrorDomain,
                    error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError
                else { return nil }
                parts.append("missing")
            }
        }
        return parts.joined(separator: "|")
    }
}
