import AppKit
import CryptoKit
import Foundation
import Security

struct HermRelease: Equatable, Sendable {
    let version: String
    let pageURL: URL?
    /// API URL of the DMG asset; works for public and (with a token) private repos.
    let assetURL: URL
    /// "sha256:<hex>" when GitHub reports one.
    let digest: String?
    /// Source commit of a nightly; nightlies share a version, so the commit identifies the build.
    var commit: String? = nil
    var signatureURL: URL? = nil
    var updatedAt: Date? = nil
    var nightlyVersion: String? = nil

    var downloadVersionLabel: String {
        guard let commit else { return "Version \(version)" }
        let shortCommit = commit.prefix(8)
        return nightlyVersion.map { "\($0) · \(shortCommit)" } ?? "Build \(shortCommit)"
    }

    var archiveFilename: String {
        let label = version.prefix(80).map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == ".") ? $0 : "-" }
        return "Herm-\(String(label)).dmg"
    }
}

enum HermAlternateReleaseChannel: String, Sendable {
    case stable, nightly

    init(current: HermBuildInfo.Channel) {
        self = current == .nightly ? .stable : .nightly
    }

    var releasePath: String { self == .nightly ? "tags/\(HermUpdateParsing.nightlyTag)" : "latest" }
    var title: String { self == .nightly ? "Nightly from main" : "Stable release" }

    func matches(_ release: HermRelease) -> Bool {
        (self == .nightly) == (release.commit != nil)
    }
}

enum HermAlternateReleaseState: Equatable {
    case idle, checking
    case available(HermRelease)
    case downloading(HermRelease, fraction: Double?, stage: String)
    case downloaded(HermRelease, URL)
    case downloadFailed(HermRelease, String)
    case failed(String)

    var release: HermRelease? {
        switch self {
        case .available(let release), .downloading(let release, _, _), .downloaded(let release, _),
            .downloadFailed(let release, _):
            release
        default: nil
        }
    }
}

enum HermAppUpdatePhase: Equatable {
    case idle
    case unavailable(String)
    case checking
    case upToDate
    /// Newer release is available to download.
    case available(String)
    case downloading
    /// Verified and staged next to the running app, awaiting restart.
    case readyToInstall(String)
    case installing
    case failed(String)
}

enum HermUpdateParsing {
    static let assetName = "Herm.dmg"

    static let nightlyTag = "nightly"

    static func release(from payload: [String: Any]) -> HermRelease? {
        guard let tag = payload["tag_name"] as? String,
            payload["draft"] as? Bool != true,
            payload["prerelease"] as? Bool != true || tag == nightlyTag,
            let assets = payload["assets"] as? [[String: Any]],
            let asset = assets.first(where: { $0["name"] as? String == assetName }),
            let assetURL = (asset["url"] as? String).flatMap(URL.init(string:)),
            assetURL.scheme == "https", assetURL.host == "api.github.com"
        else { return nil }
        let pageURL = (payload["html_url"] as? String).flatMap(URL.init(string:)).flatMap {
            $0.scheme == "https" && $0.host == "github.com" && $0.path.hasPrefix("/chryzxc/herm/releases/")
                ? $0 : nil
        }
        let digest = asset["digest"] as? String
        let signatureURL = assets.first(where: { $0["name"] as? String == assetName + ".sig" })
            .flatMap { ($0["url"] as? String).flatMap(URL.init(string:)) }
            .flatMap { $0.scheme == "https" && $0.host == "api.github.com" ? $0 : nil }
        let updatedAt =
            (asset["updated_at"] as? String).flatMap(ISO8601Parsing.date)
            ?? (payload["published_at"] as? String).flatMap(ISO8601Parsing.date)
        if tag == nightlyTag {
            // The workflow targets the release at the full source SHA.
            guard let commit = payload["target_commitish"] as? String, commit.count == 40 else { return nil }
            // The rolling tag identifies a commit. Its release title also carries the app version.
            let title = (payload["name"] as? String)?.split(separator: " ", maxSplits: 2).map(String.init) ?? []
            let nightlyVersion =
                if title.count == 3, title[0] == "Nightly", title[2] == "(\(commit.prefix(8)))",
                    title[1].range(of: #"^\d+\.\d+\.\d+-dev$"#, options: .regularExpression) != nil
                {
                    title[1]
                } else {
                    nil as String?
                }
            return HermRelease(
                version: "nightly \(commit.prefix(8))", pageURL: pageURL, assetURL: assetURL, digest: digest,
                commit: commit, signatureURL: signatureURL, updatedAt: updatedAt, nightlyVersion: nightlyVersion)
        }
        return HermRelease(
            version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag,
            pageURL: pageURL, assetURL: assetURL, digest: digest, signatureURL: signatureURL, updatedAt: updatedAt)
    }

    /// A nightly build moves to a newer nightly whenever main has a different commit.
    static func isNewerNightly(_ release: HermRelease, currentCommit: String?) -> Bool {
        guard let commit = release.commit, let currentCommit, !currentCommit.isEmpty else { return false }
        return !commit.hasPrefix(currentCommit) && !currentCommit.hasPrefix(commit)
    }

    /// Numeric major.minor.patch comparison; build/pre-release suffixes are ignored.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ version: String) -> [Int] {
            let core = version.split(whereSeparator: { $0 == "-" || $0 == "+" }).first.map(String.init) ?? version
            let numbers = core.split(separator: ".").map { Int($0) ?? 0 }
            return numbers + Array(repeating: 0, count: max(0, 3 - numbers.count))
        }
        return parts(current).lexicographicallyPrecedes(parts(candidate))
    }

    /// A nightly is built ahead of its stable release, so it also takes the stable build of the same version.
    static func shouldOffer(_ candidate: String, over current: String, isNightly: Bool) -> Bool {
        isNewer(candidate, than: current) || (isNightly && !isNewer(current, than: candidate))
    }
}

/// Checks chryzxc/herm releases, downloads and verifies the DMG, stages the
/// new bundle beside the running app, and swaps it in with a detached helper
/// after the user requests a restart and no turn is in flight. The helper rolls back if
/// the swap or the relaunch fails.
@MainActor
final class HermAppUpdater: ObservableObject {
    typealias ArchiveProgress = @Sendable (Double?, String) -> Void

    static let shared = HermAppUpdater()
    nonisolated static let repository = "chryzxc/herm"
    nonisolated static let updatePublicKey = Bundle.main.infoDictionary?["HermUpdatePublicKey"] as? String
    private static let checkInterval: TimeInterval = 60 * 60
    /// Activation and Settings re-check only results older than this, so focus changes stay offline.
    private static let staleInterval: TimeInterval = 15 * 60
    private static let idleRetryInterval: TimeInterval = 30

    @Published private(set) var phase: HermAppUpdatePhase = .idle
    @Published private(set) var latest: HermRelease?
    @Published private(set) var lastChecked: Date?
    @Published private(set) var waitingForIdle = false
    @Published private(set) var hasUpdate = false
    @Published private(set) var downloadFraction: Double?
    @Published private(set) var downloadStage = "Downloading"
    @Published private(set) var installUnavailableReason: String?
    @Published private(set) var alternateReleaseState: HermAlternateReleaseState = .idle

    /// Set by the app delegate; an update never restarts Herm mid-turn.
    var isBusy: () -> Bool = { false }

    private var timer: Timer?
    private var activationObserver: NSObjectProtocol?
    private var stagedAppURL: URL?
    private var alternateLastChecked: Date?
    private let fetchAlternate: @Sendable (HermAlternateReleaseChannel) async throws -> HermRelease
    private let saveAlternate: @Sendable (HermRelease, @escaping ArchiveProgress) async throws -> URL

    let currentVersion: String?
    let build: HermBuildInfo
    let alternateChannel: HermAlternateReleaseChannel

    init(
        build: HermBuildInfo = .current,
        currentVersion: String? = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
        fetchAlternate: @escaping @Sendable (HermAlternateReleaseChannel) async throws -> HermRelease =
            HermAppUpdater.fetchAlternateRelease,
        saveAlternate: @escaping @Sendable (HermRelease, @escaping ArchiveProgress) async throws -> URL =
            HermAppUpdater.saveAlternateArchive
    ) {
        self.build = build
        self.currentVersion = currentVersion
        alternateChannel = HermAlternateReleaseChannel(current: build.channel)
        self.fetchAlternate = fetchAlternate
        self.saveAlternate = saveAlternate
    }

    func checkAlternateIfStale() {
        guard Self.isStale(alternateLastChecked, now: Date(), maxAge: Self.staleInterval) else { return }
        checkAlternateRelease()
    }

    func checkAlternateRelease() {
        switch alternateReleaseState {
        case .checking, .downloading: return
        default: break
        }
        alternateLastChecked = Date()
        alternateReleaseState = .checking
        Task {
            do {
                let release = try await fetchAlternate(alternateChannel)
                guard alternateChannel.matches(release) else {
                    throw UpdateError("GitHub returned a release from a different channel.")
                }
                alternateReleaseState = .available(release)
            } catch {
                alternateReleaseState = .failed(HermesDiagnosticsService.safeSummary(error.localizedDescription))
            }
        }
    }

    func downloadAlternateRelease() {
        guard case .available(let release) = alternateReleaseState else { return }
        alternateReleaseState = .downloading(release, fraction: nil, stage: "Downloading")
        Task { [self] in
            do {
                let file = try await saveAlternate(release) { [weak self] fraction, stage in
                    Task { @MainActor in
                        guard let self, case .downloading(let active, _, _) = self.alternateReleaseState,
                            active == release
                        else { return }
                        self.alternateReleaseState = .downloading(release, fraction: fraction, stage: stage)
                    }
                }
                alternateReleaseState = .downloaded(release, file)
            } catch {
                alternateReleaseState = .downloadFailed(
                    release, HermesDiagnosticsService.safeSummary(error.localizedDescription))
            }
        }
    }

    var canCheck: Bool {
        switch phase {
        case .checking, .downloading, .installing, .readyToInstall: false
        default: true
        }
    }

    func start() {
        guard timer == nil else { return }
        if let reason = Self.checkUnavailableReason(version: currentVersion) {
            phase = .unavailable(reason)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.checkIfStale() }
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { _ in
            Task { @MainActor in HermAppUpdater.shared.checkForUpdates() }
        }
        timer?.tolerance = Self.checkInterval / 10
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in HermAppUpdater.shared.checkIfStale() }
        }
    }

    /// Checks only when the last result is older than `staleInterval`; cheap to call on every appear.
    func checkIfStale() {
        guard timer != nil, Self.isStale(lastChecked, now: Date(), maxAge: Self.staleInterval) else { return }
        checkForUpdates()
    }

    nonisolated static func isStale(_ lastChecked: Date?, now: Date, maxAge: TimeInterval) -> Bool {
        guard let lastChecked else { return true }
        return now.timeIntervalSince(lastChecked) >= maxAge
    }

    nonisolated static func checkUnavailableReason(version: String?, bundleURL: URL = Bundle.main.bundleURL) -> String?
    {
        guard bundleURL.pathExtension == "app" else { return "Updates are available only in the installed app." }
        guard let version, !version.isEmpty else { return "Development builds don't update automatically." }
        return nil
    }

    nonisolated static func installUnavailableReason(bundleURL: URL = Bundle.main.bundleURL) -> String? {
        guard FileManager.default.isWritableFile(atPath: bundleURL.deletingLastPathComponent().path) else {
            return
                "Herm can't write to \(bundleURL.deletingLastPathComponent().path). Move it to Applications to enable updates."
        }
        return nil
    }

    nonisolated private static func installUnavailableReason(for release: HermRelease) -> String? {
        if let reason = Self.installUnavailableReason() { return reason }
        do {
            let publisher = try HermUpdateTrust.updatePublisher(of: Bundle.main.bundleURL)
            if publisher == nil && (release.signatureURL == nil || Self.updatePublicKey == nil) {
                return "This release has no update signature. Install it from the release page."
            }
            return nil
        } catch {
            return "This Herm build could not be verified. Install it from the release page."
        }
    }

    func checkForUpdates() {
        guard canCheck, let currentVersion, Self.checkUnavailableReason(version: currentVersion) == nil else { return }
        phase = .checking
        Task {
            do {
                let token = await GitHubCodeHostService.localGitHubToken()
                let result = try await Self.findUpdate(
                    currentVersion: currentVersion, isNightly: build.channel == .nightly, currentCommit: build.commit
                ) { path in
                    try await Self.fetchRelease(path, token: token)
                }
                latest = result.latest
                if result.hasUpdate {
                    installUnavailableReason = await Task.detached {
                        Self.installUnavailableReason(for: result.latest)
                    }.value
                }
                lastChecked = Date()
                hasUpdate = result.hasUpdate
                phase = result.hasUpdate ? .available(result.latest.version) : .upToDate
            } catch {
                phase = .failed(HermesDiagnosticsService.safeSummary(error.localizedDescription))
            }
        }
    }

    nonisolated static func findUpdate(
        currentVersion: String, isNightly: Bool, currentCommit: String?,
        fetch: @Sendable (String) async throws -> HermRelease
    ) async throws -> (latest: HermRelease, hasUpdate: Bool) {
        let stable: Result<HermRelease, Error>
        do {
            stable = .success(try await fetch("latest"))
        } catch {
            stable = .failure(error)
        }
        if case .success(let release) = stable,
            HermUpdateParsing.shouldOffer(release.version, over: currentVersion, isNightly: isNightly)
        {
            return (release, true)
        }
        if isNightly {
            guard let currentCommit, !currentCommit.isEmpty else {
                throw UpdateError("This nightly build has no commit identity to check for updates.")
            }
            let nightly = try await fetch("tags/\(HermUpdateParsing.nightlyTag)")
            if HermUpdateParsing.isNewerNightly(nightly, currentCommit: currentCommit) {
                return (nightly, true)
            }
        }
        return (try stable.get(), false)
    }

    func downloadUpdate() {
        guard case .available = phase, let release = latest, installUnavailableReason == nil else { return }
        phase = .downloading
        downloadFraction = nil
        downloadStage = "Downloading"
        Task { [self] in
            do {
                let token = await GitHubCodeHostService.localGitHubToken()
                stagedAppURL = try await Self.downloadAndStage(release, token: token) { [weak self] fraction, stage in
                    Task { @MainActor in
                        self?.downloadFraction = fraction
                        self?.downloadStage = stage
                    }
                }
                phase = .readyToInstall(release.version)
            } catch {
                phase = .failed(HermesDiagnosticsService.safeSummary(error.localizedDescription))
            }
        }
    }

    /// Installs immediately if idle, otherwise waits for the current turn.
    func installWhenIdle() {
        guard case .readyToInstall = phase else { return }
        guard !isBusy() else {
            waitingForIdle = true
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.idleRetryInterval) { [weak self] in
                self?.installWhenIdle()
            }
            return
        }
        waitingForIdle = false
        installNow()
    }

    func installNow() {
        guard case .readyToInstall = phase, let stagedAppURL else { return }
        phase = .installing
        do {
            try Self.launchSwapHelper(appURL: Bundle.main.bundleURL, stagedURL: stagedAppURL)
            // applicationWillTerminate shuts the Hermes backend down; the
            // helper waits for this PID to exit before touching the bundle.
            NSApplication.shared.terminate(nil)
        } catch {
            phase = .failed("The installer could not start: \(error.localizedDescription)")
        }
    }

    // MARK: - Networking

    private struct UpdateError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    nonisolated private static func request(_ url: URL, token: String?, accept: String) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("Herm-Updater", forHTTPHeaderField: "User-Agent")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }

    nonisolated private static func fetchRelease(_ path: String, token: String?) async throws -> HermRelease {
        let url = URL(string: "https://api.github.com/repos/\(repository)/releases/\(path)")!
        let (data, response) = try await URLSession.shared.data(
            for: request(url, token: token, accept: "application/vnd.github+json"))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw UpdateError(
                status == 404
                    ? "No release found. A private repository needs `gh auth login` on this Mac."
                    : "GitHub returned status \(status) while checking for updates.")
        }
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let release = HermUpdateParsing.release(from: payload)
        else {
            throw UpdateError("The latest release has no \(HermUpdateParsing.assetName).")
        }
        return release
    }

    nonisolated private static func fetchAlternateRelease(_ channel: HermAlternateReleaseChannel) async throws
        -> HermRelease
    {
        let token = await GitHubCodeHostService.localGitHubToken()
        return try await fetchRelease(channel.releasePath, token: token)
    }

    /// Strips the GitHub token when the asset redirects to its storage host.
    private final class RedirectAuthStripper: NSObject, URLSessionDownloadDelegate {
        let progress: @Sendable (Double?, String) -> Void

        init(progress: @escaping @Sendable (Double?, String) -> Void = { _, _ in }) {
            self.progress = progress
        }

        func urlSession(
            _ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL
        ) {}

        func urlSession(
            _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
            totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
        ) {
            progress(
                totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : nil,
                "Downloading")
        }

        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
        ) {
            var request = request
            if request.url?.host != "api.github.com" { request.setValue(nil, forHTTPHeaderField: "Authorization") }
            completionHandler(request)
        }
    }

    nonisolated private static func downloadAndStage(
        _ release: HermRelease, token: String?, progress: @escaping @Sendable (Double?, String) -> Void
    ) async throws -> URL {
        let publisher = try HermUpdateTrust.updatePublisher(of: Bundle.main.bundleURL)
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("herm-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let dmg = work.appendingPathComponent(HermUpdateParsing.assetName)
        try await downloadVerifiedArchive(
            release, to: dmg, token: token, requiresArchiveSignature: publisher == nil, progress: progress)

        let mount = work.appendingPathComponent("mnt")
        try run(
            "/usr/bin/hdiutil",
            ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path, dmg.path])
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", "-force", mount.path]) }

        let mountedApp = mount.appendingPathComponent("Herm.app")
        let info = NSDictionary(contentsOf: mountedApp.appendingPathComponent("Contents/Info.plist"))
        guard info?["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier else {
            throw UpdateError("The update is not a Herm build.")
        }
        if let commit = release.commit {
            guard info?["HermBuildCommit"] as? String == commit else {
                throw UpdateError("The update's commit doesn't match release \(release.version).")
            }
        } else if info?["CFBundleShortVersionString"] as? String != release.version
            || info?["HermBuildChannel"] as? String == "nightly"
        {
            throw UpdateError("The update's version doesn't match release \(release.version).")
        }
        try HermUpdateTrust.verify(mountedApp, requirement: publisher)

        // Stage on the same volume as the running app so the swap is a rename.
        progress(1, "Preparing to install")
        let staged = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent(".Herm-update.app")
        try? FileManager.default.removeItem(at: staged)
        do {
            try run("/usr/bin/ditto", [mountedApp.path, staged.path])
            try HermUpdateTrust.verify(staged, requirement: publisher)
            return staged
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
    }

    nonisolated private static func saveAlternateArchive(
        _ release: HermRelease, progress: @escaping ArchiveProgress
    ) async throws -> URL {
        let files = FileManager.default
        let work = files.temporaryDirectory.appendingPathComponent("herm-download-\(UUID().uuidString)")
        try files.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: work) }
        let dmg = work.appendingPathComponent(HermUpdateParsing.assetName)
        let token = await GitHubCodeHostService.localGitHubToken()
        // A standalone DMG has no staged bundle to check for an Apple publisher.
        try await downloadVerifiedArchive(
            release, to: dmg, token: token, requiresArchiveSignature: true, progress: progress)
        let downloads = try files.url(for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        var destination = downloads.appendingPathComponent(release.archiveFilename)
        if files.fileExists(atPath: destination.path) {
            destination = destination.deletingPathExtension()
                .appendingPathExtension("\(UUID().uuidString.prefix(8)).dmg")
        }
        try files.moveItem(at: dmg, to: destination)
        return destination
    }

    nonisolated private static func downloadVerifiedArchive(
        _ release: HermRelease, to dmg: URL, token: String?, requiresArchiveSignature: Bool,
        progress: @escaping ArchiveProgress
    ) async throws {
        guard let expectedDigest = HermUpdateTrust.expectedDigest(release.digest) else {
            throw UpdateError("The release has no valid SHA-256 checksum.")
        }
        let (downloaded, response) = try await URLSession.shared.download(
            for: request(release.assetURL, token: token, accept: "application/octet-stream"),
            delegate: RedirectAuthStripper(progress: progress)
        )
        defer { try? FileManager.default.removeItem(at: downloaded) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw UpdateError("The update download failed (status \((response as? HTTPURLResponse)?.statusCode ?? 0)).")
        }
        try FileManager.default.moveItem(at: downloaded, to: dmg)

        progress(1, "Verifying")
        let archive = try Data(contentsOf: dmg, options: .mappedIfSafe)
        let actual = SHA256.hash(data: archive).map {
            String(format: "%02x", $0)
        }.joined()
        guard actual == expectedDigest else {
            throw UpdateError("The downloaded update failed its checksum.")
        }
        if requiresArchiveSignature {
            guard let signatureURL = release.signatureURL, let publicKey = updatePublicKey else {
                throw UpdateError("The release has no update signature. Install it from the release page.")
            }
            let (bytes, response) = try await URLSession.shared.bytes(
                for: request(signatureURL, token: token, accept: "application/octet-stream"),
                delegate: RedirectAuthStripper())
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw UpdateError("The update signature could not be downloaded.")
            }
            var signature = Data()
            for try await byte in bytes {
                guard signature.count < 128 else { throw UpdateError("The update signature is invalid.") }
                signature.append(byte)
            }
            try HermUpdateTrust.verifyArchive(archive, signature: signature, publicKey: publicKey)
        }
    }

    @discardableResult
    nonisolated private static func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError(
                "\(URL(fileURLWithPath: executable).lastPathComponent) failed: \(output.trimmingCharacters(in: .whitespacesAndNewlines))"
            )
        }
        return output
    }

    // MARK: - Swap

    /// Waits for Herm to exit, swaps bundles, relaunches, and restores the
    /// previous bundle if the move or the new version's launch fails.
    nonisolated static let swapScript = #"""
        pid="$1"; app="$2"; staged="$3"; backup="$(dirname "$app")/.Herm-previous.app"
        i=0; while kill -0 "$pid" 2>/dev/null; do i=$((i+1)); [ "$i" -gt 600 ] && exit 1; sleep 0.1; done
        rm -rf "$backup"
        mv "$app" "$backup" || { open "$app"; exit 1; }
        if ! mv "$staged" "$app"; then mv "$backup" "$app"; open "$app"; exit 1; fi
        open "$app"; sleep 8
        if ! pgrep -f "$app/Contents/MacOS/Herm" >/dev/null; then
          rm -rf "$app"; mv "$backup" "$app"; open "$app"; exit 1
        fi
        rm -rf "$backup"
        """#

    nonisolated private static func launchSwapHelper(appURL: URL, stagedURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c", swapScript, "herm-update", String(ProcessInfo.processInfo.processIdentifier), appURL.path,
            stagedURL.path,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }
}
