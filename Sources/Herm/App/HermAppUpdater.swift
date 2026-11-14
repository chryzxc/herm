import AppKit
import CryptoKit
import Foundation
import Security

enum HermUpdateTrust {
    private struct Failure: LocalizedError { let errorDescription: String? }
    static func publisherRequirement(team: String) throws -> SecRequirement {
        guard team.count == 10, team.utf8.allSatisfy({ (65...90).contains($0) || (48...57).contains($0) }) else {
            throw Failure(errorDescription: "Automatic updates require a Developer ID signed Herm release.")
        }
        let expression =
            "anchor apple generic and identifier \"io.github.chryzxc.Herm\" and "
            + "certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"\(team)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess,
            let requirement
        else { throw CocoaError(.coderInvalidValue) }
        return requirement
    }

    static func trustedPublisher(of app: URL) throws -> SecRequirement {
        let code = try staticCode(app)
        var information: CFDictionary?
        guard
            SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
                == errSecSuccess,
            let team = (information as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
        else {
            throw Failure(
                errorDescription:
                    "Automatic updates require a Developer ID signed Herm release. Install updates manually for this build."
            )
        }
        let requirement = try publisherRequirement(team: team)
        try verify(code, requirement: requirement)
        return requirement
    }

    static func verify(_ app: URL, requirement: SecRequirement) throws {
        try verify(staticCode(app), requirement: requirement)
    }

    private static func staticCode(_ app: URL) throws -> SecStaticCode {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return code
    }

    private static func verify(_ code: SecStaticCode, requirement: SecRequirement) throws {
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
        guard SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess else {
            throw Failure(
                errorDescription:
                    "The update's signature does not match this Herm publisher. Install a trusted release manually.")
        }
    }

    static func expectedDigest(_ digest: String?) -> String? {
        guard let digest, digest.hasPrefix("sha256:") else { return nil }
        let value = String(digest.dropFirst(7)).lowercased()
        return value.count == 64 && value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
            ? value : nil
    }
}

struct HermRelease: Equatable {
    let version: String
    let pageURL: URL?
    /// API URL of the DMG asset; works for public and (with a token) private repos.
    let assetURL: URL
    /// "sha256:<hex>" when GitHub reports one.
    let digest: String?
    /// Source commit of a nightly; nightlies share a version, so the commit identifies the build.
    var commit: String? = nil
}

enum HermAppUpdatePhase: Equatable {
    case idle
    case unavailable(String)
    case checking
    case upToDate
    /// Newer release exists but this build can't install it automatically (no Developer ID signature).
    case available(String)
    case downloading
    /// Verified and staged next to the running app; installs once Herm is idle.
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
        let pageURL = (payload["html_url"] as? String).flatMap(URL.init(string:))
        let digest = asset["digest"] as? String
        if tag == nightlyTag {
            // The workflow targets the release at the full source SHA.
            guard let commit = payload["target_commitish"] as? String, commit.count == 40 else { return nil }
            return HermRelease(
                version: "nightly \(commit.prefix(8))", pageURL: pageURL, assetURL: assetURL, digest: digest,
                commit: commit)
        }
        return HermRelease(
            version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag,
            pageURL: pageURL, assetURL: assetURL, digest: digest)
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
/// once no turn is in flight. The helper rolls back to the previous bundle if
/// the swap or the relaunch fails.
@MainActor
final class HermAppUpdater: ObservableObject {
    static let shared = HermAppUpdater()
    nonisolated static let repository = "chryzxc/herm"
    private static let checkInterval: TimeInterval = 6 * 60 * 60
    private static let idleRetryInterval: TimeInterval = 30

    @Published private(set) var phase: HermAppUpdatePhase = .idle
    @Published private(set) var latest: HermRelease?
    @Published private(set) var lastChecked: Date?

    /// Set by the app delegate; an update never restarts Herm mid-turn.
    var isBusy: () -> Bool = { false }

    private var timer: Timer?
    private var stagedAppURL: URL?

    let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    let isNightly = HermBuildInfo.current.channel == .nightly

    /// Drives the update badges on the rail and in Settings.
    var hasUpdate: Bool {
        switch phase {
        case .available, .readyToInstall: true
        default: false
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
        if let reason = Self.unavailableReason(version: currentVersion) {
            phase = .unavailable(reason)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.checkForUpdates() }
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { _ in
            Task { @MainActor in HermAppUpdater.shared.checkForUpdates() }
        }
    }

    nonisolated static func unavailableReason(version: String?, bundleURL: URL = Bundle.main.bundleURL) -> String? {
        guard bundleURL.pathExtension == "app" else { return "Updates are available only in the installed app." }
        guard let version, !version.isEmpty else { return "Development builds don't update automatically." }
        guard FileManager.default.isWritableFile(atPath: bundleURL.deletingLastPathComponent().path) else {
            return
                "Herm can't write to \(bundleURL.deletingLastPathComponent().path). Move it to Applications to enable updates."
        }
        return nil
    }

    func checkForUpdates() {
        guard canCheck, let currentVersion, Self.unavailableReason(version: currentVersion) == nil else { return }
        phase = .checking
        Task {
            do {
                let token = await GitHubCodeHostService.localGitHubToken()
                let stable = try await Self.fetchRelease("latest", token: token)
                // Nightlies are pre-releases, absent from /releases/latest; a nightly build checks its own tag.
                let nightly =
                    isNightly ? try? await Self.fetchRelease("tags/\(HermUpdateParsing.nightlyTag)", token: token) : nil
                lastChecked = Date()
                let release: HermRelease
                if HermUpdateParsing.shouldOffer(stable.version, over: currentVersion, isNightly: isNightly) {
                    release = stable
                } else if let nightly,
                    HermUpdateParsing.isNewerNightly(nightly, currentCommit: HermBuildInfo.current.commit)
                {
                    release = nightly
                } else {
                    latest = nightly ?? stable
                    phase = .upToDate
                    return
                }
                latest = release
                // Ad-hoc signed builds can't verify an update's publisher; tell the user instead of failing.
                guard (try? HermUpdateTrust.trustedPublisher(of: Bundle.main.bundleURL)) != nil else {
                    phase = .available(release.version)
                    return
                }
                phase = .downloading
                stagedAppURL = try await Self.downloadAndStage(release, token: token)
                phase = .readyToInstall(release.version)
                installWhenIdle()
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    /// Installs immediately if idle, otherwise waits for the current turn.
    func installWhenIdle() {
        guard case .readyToInstall = phase else { return }
        guard !isBusy() else {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.idleRetryInterval) { [weak self] in
                self?.installWhenIdle()
            }
            return
        }
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

    /// Strips the GitHub token when the asset redirects to its storage host.
    private final class RedirectAuthStripper: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
        ) {
            var request = request
            if request.url?.host != "api.github.com" { request.setValue(nil, forHTTPHeaderField: "Authorization") }
            completionHandler(request)
        }
    }

    nonisolated private static func downloadAndStage(_ release: HermRelease, token: String?) async throws -> URL {
        let publisher = try HermUpdateTrust.trustedPublisher(of: Bundle.main.bundleURL)
        guard let expectedDigest = HermUpdateTrust.expectedDigest(release.digest) else {
            throw UpdateError("The release has no valid SHA-256 checksum. The update was not installed.")
        }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("herm-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let (downloaded, response) = try await URLSession.shared.download(
            for: request(release.assetURL, token: token, accept: "application/octet-stream"),
            delegate: RedirectAuthStripper()
        )
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw UpdateError("The update download failed (status \((response as? HTTPURLResponse)?.statusCode ?? 0)).")
        }
        let dmg = work.appendingPathComponent(HermUpdateParsing.assetName)
        try FileManager.default.moveItem(at: downloaded, to: dmg)

        let actual = SHA256.hash(data: try Data(contentsOf: dmg, options: .mappedIfSafe)).map {
            String(format: "%02x", $0)
        }.joined()
        guard actual == expectedDigest else {
            throw UpdateError("The downloaded update failed its checksum.")
        }

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
        } else if info?["CFBundleShortVersionString"] as? String != release.version {
            throw UpdateError("The update's version doesn't match release \(release.version).")
        }
        try HermUpdateTrust.verify(mountedApp, requirement: publisher)

        // Stage on the same volume as the running app so the swap is a rename.
        let staged = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent(".Herm-update.app")
        try? FileManager.default.removeItem(at: staged)
        try run("/usr/bin/ditto", [mountedApp.path, staged.path])
        try HermUpdateTrust.verify(staged, requirement: publisher)
        return staged
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
