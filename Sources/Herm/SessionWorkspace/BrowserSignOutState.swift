import Combine
import Foundation

/// Only reset identifiers persist here. Cookies remain in the browser's own profile store.
@MainActor
final class BrowserSignOutState: ObservableObject {
    static let shared = BrowserSignOutState(root: AgentBrowser.profileRoot)

    @Published private(set) var isResetting = false
    private let root: URL

    init(root: URL) { self.root = root }

    private var generationFile: URL { root.appendingPathComponent("SignOutGeneration") }

    func reset(clearRunningStores: () async throws -> Void) async throws {
        guard !isResetting else { return }
        isResetting = true
        defer { isResetting = false }
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        try write(UUID().uuidString, to: generationFile)
        // Explicit sign-out discards the legacy jar without unlocking or importing it.
        do {
            try FileManager.default.removeItem(at: root.appendingPathComponent("SharedLogins.sealed"))
        } catch CocoaError.fileNoSuchFile {
        }
        try await clearRunningStores()
    }

    func apply(to profile: String, clearCookies: () async throws -> Void) async throws {
        let appliedFile = root.appendingPathComponent(profile, isDirectory: true).appendingPathComponent("HermSignOuts")
        while let generation = try generation() {
            let applied: String?
            do {
                applied = try String(contentsOf: appliedFile, encoding: .utf8)
            } catch CocoaError.fileReadNoSuchFile {
                applied = nil
            }
            if applied == generation { return }
            try await clearCookies()
            try Task.checkCancellation()
            try write(generation, to: appliedFile)
        }
    }

    private func generation() throws -> String? {
        let data: Data
        do {
            data = try Data(contentsOf: generationFile)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        }
        guard data.count == 36, let value = String(data: data, encoding: .utf8), UUID(uuidString: value) != nil else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return value
    }

    private func write(_ value: String, to file: URL) throws {
        try Data(value.utf8).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

/// A reset waits for suspended WebKit writes before clearing their destination store.
@MainActor
final class BrowserCookieTransfers {
    struct Transfer: Hashable {
        fileprivate let id = UUID()
        fileprivate let generation: UUID
    }

    private var generation = UUID()
    private var active: Set<Transfer> = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func begin() -> Transfer {
        let transfer = Transfer(generation: generation)
        active.insert(transfer)
        return transfer
    }

    func isValid(_ transfer: Transfer) -> Bool { transfer.generation == generation }

    func finish(_ transfer: Transfer) {
        active.remove(transfer)
        guard active.isEmpty else { return }
        let completed = waiters
        waiters.removeAll()
        for waiter in completed { waiter.resume() }
    }

    func invalidate() { generation = UUID() }

    func invalidateAndDrain() async {
        invalidate()
        guard !active.isEmpty else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
