import AppKit
import Foundation

/// Version facts parsed from the local `hermes --version` projection.
struct HermesInstalledVersion: Equatable {
    /// Semantic-style version such as `0.19.1`.
    let marketing: String?
    /// Calendar build such as `2026.7.30`.
    let calendar: String?

    var displayVersion: String {
        switch (marketing, calendar) {
        case (.some(let marketing), .some(let calendar)):
            return "v\(marketing) (\(calendar))"
        case (.some(let marketing), .none):
            return "v\(marketing)"
        case (.none, .some(let calendar)):
            return "build \(calendar)"
        case (.none, .none):
            return "unknown"
        }
    }
}

/// The latest release projection from the NousResearch/hermes-agent repository.
struct HermesLatestRelease: Equatable {
    let tag: String
    let marketing: String?
    let name: String?
    let publishedAt: Date?
    let pageURL: String?

    var calendar: String? { HermesUpdateParsing.calendarVersion(fromTag: tag) }

    var displayVersion: String {
        if let marketing {
            return marketing == tag ? "v\(marketing)" : "v\(marketing) (\(tag))"
        }
        return tag
    }
}

enum HermesUpdatePhase: Equatable {
    case idle
    case checking
    case upToDate
    case updateAvailable
    case checkFailed(String)
    case updating
    case updateSucceeded
    case updateFailed(String)

    var ambientStatus: (title: String, isRunning: Bool)? {
        switch self {
        case .updating: ("Updating Hermes Agent…", true)
        case .updateFailed: ("Hermes Agent update failed", false)
        default: nil
        }
    }
}

extension Notification.Name {
    static let hermAgentUpdatePhase = Notification.Name("hermAgentUpdatePhase")
}

enum HermesUpdateFetchError: Error {
    case message(String)
}

/// Pure parsing and comparison helpers for the Hermes agent update flow.
/// Kept free of process and network concerns so they stay unit-testable.
enum HermesUpdateParsing {
    /// `hermes --version` first line looks like
    /// `Hermes Agent v0.19.1 (2026.7.30) · upstream e3b5512b`.
    nonisolated static func installedVersion(from output: String) -> HermesInstalledVersion? {
        let firstLine =
            output
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? output
        let marketing =
            firstMatch(in: firstLine, pattern: #"v(\d+\.\d+(?:\.\d+)?)"#)
            ?? firstMatch(in: firstLine, pattern: #"(\d+\.\d+\.\d+)"#)
        let calendar = firstMatch(in: firstLine, pattern: #"\((\d{4}\.\d{1,2}\.\d{1,2}(?:\.\d+)?)\)"#)
        guard marketing != nil || calendar != nil else { return nil }
        return HermesInstalledVersion(marketing: marketing, calendar: calendar)
    }

    nonisolated static func installMethod(from output: String) -> String? {
        for rawLine in output.split(separator: "\n") {
            let line = String(rawLine)
            guard line.hasPrefix("Install method:") else { continue }
            let value = line.dropFirst("Install method:".count).trimmingCharacters(in: .whitespaces)
            if !value.isEmpty { return value }
        }
        return nil
    }

    nonisolated static func latestRelease(from payload: [String: Any]) -> HermesLatestRelease? {
        guard let tag = payload["tag_name"] as? String, !tag.isEmpty else { return nil }
        let name = (payload["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let nonEmptyName = (name?.isEmpty == false) ? name : nil
        return HermesLatestRelease(
            tag: tag,
            marketing: nonEmptyName.flatMap { marketingVersion(inName: $0) },
            name: nonEmptyName,
            publishedAt: (payload["published_at"] as? String).flatMap(parseDate),
            pageURL: payload["html_url"] as? String
        )
    }

    /// Release names mix semantic and calendar versions, for example
    /// `Hermes Agent v0.20.5 (v2026.8.19)`. The semantic version is any
    /// `v…` match whose major component is below a calendar-year magnitude.
    nonisolated private static func marketingVersion(inName name: String) -> String? {
        allMatches(in: name, pattern: #"v(\d+(?:\.\d+){1,3})"#)
            .first { compareNumeric($0, "2000.0.0") == .orderedAscending }
    }

    /// Release tags such as `v2026.8.19` are calendar versions.
    nonisolated static func calendarVersion(fromTag tag: String) -> String? {
        firstMatch(in: tag, pattern: #"^v?(\d{4}\.\d{1,2}\.\d{1,2}(?:\.\d+)?)$"#)
    }

    /// Semantic versions win when both sides have them; calendar builds are
    /// the fallback. Returns nil when the pair cannot be compared at all.
    nonisolated static func isOutdated(installed: HermesInstalledVersion, latest: HermesLatestRelease) -> Bool? {
        if let installedMarketing = installed.marketing,
            let latestMarketing = latest.marketing,
            let result = compareNumeric(installedMarketing, latestMarketing)
        {
            return result == .orderedAscending
        }
        if let installedCalendar = installed.calendar,
            let latestCalendar = latest.calendar,
            let result = compareNumeric(installedCalendar, latestCalendar)
        {
            return result == .orderedAscending
        }
        return nil
    }

    /// Numeric dot-version comparison that pads unequal component counts,
    /// so `0.20` sorts equal to `0.20.0`.
    nonisolated static func compareNumeric(_ lhs: String, _ rhs: String) -> ComparisonResult? {
        guard let left = numericComponents(lhs), let right = numericComponents(rhs) else { return nil }
        let count = max(left.count, right.count)
        let paddedLeft = left + Array(repeating: 0, count: count - left.count)
        let paddedRight = right + Array(repeating: 0, count: count - right.count)
        if paddedLeft == paddedRight { return .orderedSame }
        return paddedLeft.lexicographicallyPrecedes(paddedRight) ? .orderedAscending : .orderedDescending
    }

    nonisolated private static func numericComponents(_ version: String) -> [Int]? {
        let parts = version.split(separator: ".").map(String.init)
        guard !parts.isEmpty else { return nil }
        var values: [Int] = []
        for part in parts {
            guard let value = Int(part) else { return nil }
            values.append(value)
        }
        return values
    }

    nonisolated private static func parseDate(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        return ISO8601DateFormatter().date(from: raw)
    }

    nonisolated private static func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
            match.numberOfRanges > 1,
            let captureRange = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[captureRange])
    }

    nonisolated private static func allMatches(in text: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                let captureRange = Range(match.range(at: 1), in: text)
            else { return nil }
            return String(text[captureRange])
        }
    }
}

/// Presentation helpers for streamed `hermes update` output. The updater
/// emits git/pip progress with ANSI styling and carriage-return redraws;
/// the Dock only keeps readable, bounded text.
enum HermesUpdateLogPresentation {
    nonisolated static let maximumLineLength = 240

    nonisolated static func sanitize(_ line: String) -> String? {
        var text = line.replacingOccurrences(
            of: "\u{001B}\\[[0-9;?]*[ -/]*[@-~]",
            with: "",
            options: .regularExpression
        )
        text = String(
            text.filter { character in
                character.unicodeScalars.allSatisfy { scalar in
                    scalar == "\t" || !CharacterSet.controlCharacters.contains(scalar)
                }
            })
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if !home.isEmpty, home != "/" {
            text = text.replacingOccurrences(of: home, with: "~")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.count > maximumLineLength {
            return String(trimmed.prefix(maximumLineLength)) + "…"
        }
        return trimmed
    }
}

/// Streams `hermes update` output across thread boundaries. Carriage-return
/// redraws from pip and git become discrete lines.
private final class HermesUpdateOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""

    func completeLines(from text: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        buffer += text
        var segments =
            buffer
            .split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map(String.init)
        buffer = segments.removeLast()
        return segments
    }
}

/// Checks the locally installed Hermes agent against the latest
/// NousResearch/hermes-agent release and can run the allow-listed
/// `hermes update` command with streamed progress. The update only
/// ever starts from an explicit, confirmed user action.
@MainActor
final class HermesUpdateService: ObservableObject {
    static let shared = HermesUpdateService()

    @Published private(set) var phase: HermesUpdatePhase = .idle {
        didSet {
            NotificationCenter.default.post(name: .hermAgentUpdatePhase, object: self, userInfo: ["phase": phase])
        }
    }
    @Published private(set) var installed: HermesInstalledVersion?
    @Published private(set) var installMethod: String?
    @Published private(set) var latest: HermesLatestRelease?
    @Published private(set) var lastChecked: Date?
    @Published private(set) var logLines: [String] = []
    @Published private(set) var updateStartedAt: Date?

    nonisolated static let latestReleaseURLString =
        "https://api.github.com/repos/NousResearch/hermes-agent/releases/latest"
    nonisolated static let updateCommandArguments = ["hermes", "update"]
    nonisolated static let updateCommandDisplay = "hermes update"
    static let remoteBackendMessage =
        "Hermes Agent runs on the remote backend. Run `hermes update` on that host to update it."
    private static let logLineLimit = 300
    private static let versionReadTimeout: TimeInterval = 10

    private var updateProcess: Process?
    private var relaunchScheduled = false

    private let readVersion: @Sendable () async -> (succeeded: Bool, text: String)
    private let readRelease: @Sendable () async -> Result<HermesLatestRelease, HermesUpdateFetchError>
    private let launchUpdate: (Process) throws -> Void

    init(
        readVersion: @escaping @Sendable () async -> (succeeded: Bool, text: String) = {
            await HermesUpdateService.runHermes(arguments: ["--version"], timeout: 10)
        },
        readRelease: @escaping @Sendable () async -> Result<HermesLatestRelease, HermesUpdateFetchError> = {
            await HermesUpdateService.fetchLatestRelease()
        },
        launchUpdate: @escaping (Process) throws -> Void = { try $0.run() }
    ) {
        self.readVersion = readVersion
        self.readRelease = readRelease
        self.launchUpdate = launchUpdate
    }

    var isBusy: Bool { phase == .checking || phase == .updating }
    var canCheck: Bool { !isBusy }
    var canStartUpdate: Bool { !isBusy && phase == .updateAvailable }

    func checkForUpdates() {
        guard !isBusy else { return }
        // The `hermes` on this Mac is not the backend's; only Local mode can check or update it.
        guard GatewayConnectionStore.isLocalBackend else {
            phase = .checkFailed(Self.remoteBackendMessage)
            return
        }
        phase = .checking
        Task { [weak self] in
            guard let self else { return }
            async let versionOutput = self.readVersion()
            async let releaseResult = self.readRelease()
            let output = await versionOutput
            let release = await releaseResult

            guard output.succeeded,
                let installed = HermesUpdateParsing.installedVersion(from: output.text)
            else {
                self.phase = .checkFailed(
                    "The installed Hermes version could not be read. Make sure the `hermes` CLI is installed and on your PATH."
                )
                return
            }
            self.installed = installed
            self.installMethod = HermesUpdateParsing.installMethod(from: output.text)

            switch release {
            case .failure(.message(let message)):
                self.latest = nil
                self.phase = .checkFailed(message)
            case .success(let latest):
                self.latest = latest
                self.lastChecked = Date()
                switch HermesUpdateParsing.isOutdated(installed: installed, latest: latest) {
                case .some(true): self.phase = .updateAvailable
                case .some(false): self.phase = .upToDate
                case .none: self.phase = .checkFailed("The installed and upstream versions could not be compared.")
                }
            }
        }
    }

    func performUpdate() {
        guard !isBusy, GatewayConnectionStore.isLocalBackend else { return }
        phase = .updating
        logLines.removeAll()
        updateStartedAt = Date()
        appendLog("Running \(Self.updateCommandDisplay)…")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = Self.updateCommandArguments
        process.environment = HermesEnvironment.processEnvironment()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let collector = HermesUpdateOutputCollector()

        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            guard let text = String(data: chunk, encoding: .utf8) else { return }
            let lines = collector.completeLines(from: text)
                .compactMap(HermesUpdateLogPresentation.sanitize)
            guard !lines.isEmpty else { return }
            Task { @MainActor [weak self] in
                self?.appendLog(lines)
            }
        }

        process.terminationHandler = { [weak self] terminated in
            Task { @MainActor [weak self] in
                guard let self else { return }
                pipe.fileHandleForReading.readabilityHandler = nil
                self.updateProcess = nil
                if terminated.terminationStatus == 0 {
                    self.phase = .updateSucceeded
                    self.appendLog("Update finished.")
                    await self.refreshInstalledVersionAfterUpdate()
                    self.relaunchDock()
                } else {
                    self.phase = .updateFailed("hermes update exited with status \(terminated.terminationStatus).")
                }
            }
        }

        do {
            try launchUpdate(process)
            updateProcess = process
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            phase = .updateFailed("The Hermes CLI could not be launched: \(error.localizedDescription)")
        }
    }

    /// Restarts the Dock and its Hermes backend so newly selected provider
    /// credentials are loaded by a fresh `hermes serve` process.
    func restartDock() {
        guard !isBusy else { return }
        relaunchDock()
    }

    private func refreshInstalledVersionAfterUpdate() async {
        let output = await Self.runHermes(arguments: ["--version"], timeout: Self.versionReadTimeout)
        if output.succeeded,
            let installed = HermesUpdateParsing.installedVersion(from: output.text)
        {
            self.installed = installed
            self.installMethod = HermesUpdateParsing.installMethod(from: output.text)
            appendLog("Installed version is now \(installed.displayVersion).")
        }
        appendLog("Restart Hermes so new sessions run the updated agent.")
    }

    private func relaunchDock() {
        guard !relaunchScheduled else { return }
        guard Bundle.main.bundleURL.pathExtension.lowercased() == "app" else {
            // Swift package tests and command-line launches have no app bundle
            // to reopen. Keep the successful update state in those contexts.
            appendLog("Herm restart is unavailable outside the app bundle.")
            return
        }

        relaunchScheduled = true
        appendLog("Restarting Herm…")

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(
            at: Bundle.main.bundleURL,
            configuration: configuration
        ) { [weak self] _, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error {
                    self.relaunchScheduled = false
                    self.appendLog("Herm restart failed: \(error.localizedDescription)")
                    return
                }
                // applicationWillTerminate shuts down the existing Hermes
                // backend before this instance exits.
                NSApplication.shared.terminate(nil)
            }
        }
    }

    private func appendLog(_ lines: [String]) {
        logLines.append(contentsOf: lines)
        if logLines.count > Self.logLineLimit {
            logLines.removeFirst(logLines.count - Self.logLineLimit)
        }
    }

    private func appendLog(_ line: String) {
        appendLog([line])
    }

    /// Runs a read-only Hermes CLI command locally with a timeout. The Dock
    /// launches the Hermes backend the same way, so this stays consistent
    /// with the app's existing process-launch boundary.
    nonisolated static func runHermes(arguments: [String], timeout: TimeInterval) async -> (
        succeeded: Bool, text: String
    ) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["hermes"] + arguments
        process.environment = HermesEnvironment.processEnvironment()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (false, "")
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if process.isRunning {
            process.terminate()
            return (false, "")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus == 0, String(data: data, encoding: .utf8) ?? "")
    }

    nonisolated private static func fetchLatestRelease() async -> Result<HermesLatestRelease, HermesUpdateFetchError> {
        guard let url = URL(string: latestReleaseURLString) else {
            return .failure(.message("The NousResearch release feed URL is invalid."))
        }
        switch await QuotaHTTP.getJSON(url: url, headers: ["Accept": "application/vnd.github+json"]) {
        case .success(let payload):
            guard let release = HermesUpdateParsing.latestRelease(from: payload) else {
                return .failure(.message("The latest NousResearch/hermes-agent release payload could not be read."))
            }
            return .success(release)
        case .failure(let error):
            switch error {
            case .status(let code):
                return .failure(.message("GitHub returned status \(code) while fetching the latest release."))
            case .network:
                return .failure(.message("GitHub could not be reached while fetching the latest release."))
            case .invalidResponse:
                return .failure(.message("GitHub returned an unreadable latest-release payload."))
            }
        }
    }
}
