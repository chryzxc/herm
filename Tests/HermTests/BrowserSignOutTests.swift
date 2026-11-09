import Foundation
import Testing

@testable import Herm

@MainActor
struct BrowserSignOutTests {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func profile(_ name: String, in root: URL) throws -> URL {
        let folder = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func startupPreservesLegacyFilesAndExistingProfileWithoutReset() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try profile("one", in: root)
        let legacy = root.appendingPathComponent("SharedLogins.sealed")
        let corrupt = Data("unreadable legacy ciphertext".utf8)
        try corrupt.write(to: legacy)
        let cookies = folder.appendingPathComponent("Cookies")
        try Data("native browser data".utf8).write(to: cookies)
        try Data("9".utf8).write(to: folder.appendingPathComponent("HermSignOuts"))
        let state = BrowserSignOutState(root: root)
        var cleared = false
        try await state.apply(to: "one") { cleared = true }
        #expect(!cleared)
        #expect(try Data(contentsOf: legacy) == corrupt)
        #expect(try String(contentsOf: cookies, encoding: .utf8) == "native browser data")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("SignOutGeneration").path))
    }

    @Test func resetClearsRunningAndClosedProfilesOnlyOnceAndRemovesLegacyJar() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try profile("running", in: root)
        _ = try profile("closed", in: root)
        let legacy = root.appendingPathComponent("SharedLogins.sealed")
        try Data("old ciphertext".utf8).write(to: legacy)
        let state = BrowserSignOutState(root: root)
        var runningClears = 0
        try await state.reset {
            #expect(state.isResetting)
            try await state.apply(to: "running") { runningClears += 1 }
        }
        #expect(!state.isResetting)
        #expect(runningClears == 1)
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        let reopened = BrowserSignOutState(root: root)
        var closedClears = 0
        try await reopened.apply(to: "closed") { closedClears += 1 }
        try await reopened.apply(to: "running") { runningClears += 1 }
        try await reopened.apply(to: "closed") { closedClears += 1 }
        #expect(runningClears == 1)
        #expect(closedClears == 1)
        let marker = root.appendingPathComponent("SignOutGeneration")
        let value = try String(contentsOf: marker, encoding: .utf8)
        #expect(UUID(uuidString: value) != nil)
        #expect(try FileManager.default.attributesOfItem(atPath: marker.path)[.posixPermissions] as? Int == 0o600)
        #expect(try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? Int == 0o700)
    }

    @Test func failedResetWriteDoesNotClearRunningStores() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let blocked = root.appendingPathComponent("not-a-directory")
        try Data().write(to: blocked)
        let state = BrowserSignOutState(root: blocked)
        var cleared = false
        do {
            try await state.reset { cleared = true }
            Issue.record("Reset must fail when its directory cannot be created")
        } catch {
            #expect(!cleared)
            #expect(!state.isResetting)
        }
    }

    @Test func failedBrowserClearRemainsPendingUntilSuccessfulRetry() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try profile("one", in: root)
        let state = BrowserSignOutState(root: root)
        do {
            try await state.reset {
                try await state.apply(to: "one") { throw CocoaError(.fileWriteNoPermission) }
            }
            Issue.record("Failed clear must propagate")
        } catch {
            #expect(!state.isResetting)
            #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("HermSignOuts").path))
        }
        var clears = 0
        try await BrowserSignOutState(root: root).apply(to: "one") { clears += 1 }
        #expect(clears == 1)
    }

    @Test func malformedResetAndFailedAcknowledgmentCannotSilentlySucceed() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try profile("one", in: root)
        let state = BrowserSignOutState(root: root)
        try Data("corrupt".utf8).write(to: root.appendingPathComponent("SignOutGeneration"))
        do {
            try await state.apply(to: "one") { Issue.record("Corrupt reset must fail before clearing") }
            Issue.record("Corrupt reset must not be ignored")
        } catch {}
        try await state.reset {}
        let acknowledgment = folder.appendingPathComponent("HermSignOuts")
        try FileManager.default.createDirectory(at: acknowledgment, withIntermediateDirectories: true)
        do {
            try await state.apply(to: "one") {}
            Issue.record("Unreadable acknowledgment must not be treated as success")
        } catch {}
        try FileManager.default.removeItem(at: acknowledgment)
        var cleared = false
        try await state.apply(to: "one") { cleared = true }
        #expect(cleared)
    }

    @Test func anotherResetDuringClearIsAppliedBeforeReturning() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try profile("one", in: root)
        let state = BrowserSignOutState(root: root)
        try await state.reset {}
        var clears = 0
        try await state.apply(to: "one") {
            clears += 1
            if clears == 1 { try await state.reset {} }
        }
        #expect(clears == 2)
    }

    @Test func signOutInvalidatesTransfersAndWaitsForSuspendedWrites() async {
        let transfers = BrowserCookieTransfers()
        let old = transfers.begin()
        var drained = false
        let reset = Task {
            await transfers.invalidateAndDrain()
            drained = true
        }
        while transfers.isValid(old) { await Task.yield() }
        #expect(!drained)
        transfers.finish(old)
        await reset.value
        #expect(drained)
        let fresh = transfers.begin()
        #expect(transfers.isValid(fresh))
        #expect(!transfers.isValid(old))
        transfers.finish(fresh)
    }

    @Test func browserKeychainServiceCannotReturnThroughStartupOrBrowserSources() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources/Herm")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        for case let file as URL in files where file.pathExtension == "swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            #expect(
                !source.contains("io.github.chryzxc.Herm.browser"),
                "Browser Keychain service in \(file.lastPathComponent)")
            if file.deletingLastPathComponent().lastPathComponent == "SessionWorkspace" {
                #expect(!source.contains("HermKeychain"), "Browser code must not access Herm Keychain")
            }
        }
    }
}
