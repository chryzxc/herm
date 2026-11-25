import Combine
import CryptoKit
import Foundation

@MainActor
final class TerminalWorkspaceStore {
    static let shared = TerminalWorkspaceStore()
    let verificationChanges = PassthroughSubject<Void, Never>()
    private var workspaces: [String: TerminalTabStore] = [:]
    func existingWorkspace(key: String) -> TerminalTabStore? { workspaces[key] }

    func workspace(key: String) -> TerminalTabStore {
        if let existing = workspaces[key] { return existing }
        let created = TerminalTabStore(persistenceKey: key)
        workspaces[key] = created
        return created
    }
    func processIDs(matching identity: String) -> [Int32] {
        workspaces.filter { $0.key.contains(identity) }.values.flatMap { $0.sessions.map(\.shellProcessID) }.filter {
            $0 > 0
        }
    }

    func tabs(identity: String, directory: String) -> [(extraID: UUID?, tabs: TerminalTabStore)] {
        let base = "\(identity):\(directory)"
        let prefix = "\(identity):extra:"
        return workspaces.compactMap { key, tabs in
            if key == base { return (nil, tabs) }
            guard key.hasPrefix(prefix) else { return nil }
            let parts = key.dropFirst(prefix.count).split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[1] == directory, let id = UUID(uuidString: String(parts[0])) else {
                return nil
            }
            return (id, tabs)
        }
    }
    func closeWorkspace(key: String) {
        guard let workspace = workspaces.removeValue(forKey: key) else { return }
        workspace.closeAll()
        verificationChanges.send()
    }

    /// Move legacy nested shells into independently owned inspector workspaces without stopping them.
    func separateShells(key: String, makeKey: (UUID) -> String) -> [UUID] {
        let source: TerminalTabStore
        if let existing = existingWorkspace(key: key) {
            source = existing
        } else {
            guard TerminalTabStore.hasNestedLayout(key: key) else { return [] }
            source = workspace(key: key)
        }
        let moved = source.takeUnselectedSessions().map { session in
            let id = UUID()
            let targetKey = makeKey(id)
            workspaces[targetKey] = TerminalTabStore(session: session, persistenceKey: targetKey)
            return id
        }
        if !moved.isEmpty { verificationChanges.send() }
        return moved
    }
    func shutdown() {
        for workspace in workspaces.values { workspace.closeAll() }
        workspaces = [:]
    }
}

/// Real interactive terminal view following DESIGN.md glass pane & typography specifications.
@MainActor
final class TerminalTabStore: ObservableObject {
    @Published private(set) var sessions: [LocalTerminalSession]
    @Published var selectedID: LocalTerminalSession.ID { didSet { persistLayout() } }
    @Published var splitAxis = 0 { didSet { persistLayout() } }
    @Published var splitIDs: [UUID] = [] { didSet { persistLayout() } }
    private let persistenceKey: String?
    private var subscriptions: [AnyCancellable] = []

    init(persistenceKey: String? = nil) {
        self.persistenceKey = persistenceKey.map(Self.layoutKey)
        let layout = self.persistenceKey.map(Self.loadLayout)
        let count = max(1, min(16, layout?.count ?? 1))
        let restored = (0..<count).map { _ in LocalTerminalSession() }
        sessions = restored
        selectedID = restored[min(max(0, layout?.selected ?? 0), count - 1)].id
        splitIDs = Array((layout?.splits ?? []).prefix(4)).compactMap {
            restored.indices.contains($0) ? restored[$0].id : nil
        }
        splitAxis = layout?.axis == 1 ? 1 : 0
        sessions.forEach(observe)
    }
    init(session: LocalTerminalSession, persistenceKey: String) {
        self.persistenceKey = Self.layoutKey(persistenceKey)
        sessions = [session]
        selectedID = session.id
        observe(session)
        persistLayout()
    }

    func takeUnselectedSessions() -> [LocalTerminalSession] {
        let kept = selected
        let moved = sessions.filter { $0.id != kept.id }
        guard !moved.isEmpty || !splitIDs.isEmpty else { return [] }
        sessions = [kept]
        subscriptions.removeAll()
        observe(kept)
        splitIDs = []
        persistLayout()
        return moved
    }
    private struct TerminalLayout: Codable {
        let count: Int
        let selected: Int
        let splits: [Int]
        let axis: Int
    }
    private static func layoutKey(_ key: String) -> String {
        "herm.terminal-layout." + SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func loadLayout(_ key: String) -> TerminalLayout {
        if let data = UserDefaults.standard.data(forKey: key + ".v2"),
            let layout = try? JSONDecoder().decode(TerminalLayout.self, from: data)
        {
            return layout
        }
        return TerminalLayout(count: UserDefaults.standard.integer(forKey: key), selected: 0, splits: [], axis: 0)
    }

    static func hasNestedLayout(key: String) -> Bool {
        let layout = loadLayout(layoutKey(key))
        return layout.count > 1 || !layout.splits.isEmpty
    }

    private func persistLayout() {
        guard let persistenceKey else { return }
        let layout = TerminalLayout(
            count: sessions.count, selected: sessions.firstIndex(where: { $0.id == selectedID }) ?? 0,
            splits: splitIDs.compactMap { id in sessions.firstIndex(where: { $0.id == id }) }, axis: splitAxis)
        if let data = try? JSONEncoder().encode(layout) {
            UserDefaults.standard.set(data, forKey: persistenceKey + ".v2")
        }
    }

    var selected: LocalTerminalSession {
        sessions.first(where: { $0.id == selectedID }) ?? sessions[0]
    }

    func add(directory: String) {
        let session = LocalTerminalSession()
        sessions.append(session)
        observe(session)
        selectedID = session.id
        persistLayout()
        session.start(directory: directory)
    }

    /// A suggested command must never become input to an existing job or a half-written prompt.
    func runInNewShell(_ command: String, directory: String) throws {
        guard !command.isEmpty else { throw QuickDraftError.message("The command is empty.") }
        let unused = selected.state == .idle && selected.workingDirectory == nil
        guard unused || sessions.count < 16 else {
            throw QuickDraftError.message("Close a terminal before opening another command (16 shells maximum).")
        }
        let session = unused ? selected : LocalTerminalSession()
        session.start(directory: directory)
        guard session.state == .ready, session.submitCommand(command) else {
            let detail: String
            if case .failed(let message) = session.state {
                detail = message
            } else {
                detail = "Could not open the shell."
            }
            session.close()
            throw QuickDraftError.message(HermesDiagnosticsService.safeSummary(detail))
        }
        if !unused {
            sessions.append(session)
            observe(session)
        }
        splitIDs = []
        selectedID = session.id
        persistLayout()
    }

    func closeSelected() {
        guard sessions.count > 1 else {
            selected.close()
            return
        }
        let index = sessions.firstIndex(where: { $0.id == selectedID }) ?? 0
        splitIDs.removeAll { $0 == selectedID }
        sessions[index].close()
        sessions.remove(at: index)
        subscriptions.removeAll()
        sessions.forEach(observe)
        selectedID = sessions[min(index, sessions.count - 1)].id
        TerminalWorkspaceStore.shared.verificationChanges.send()
    }

    func closeAll() {
        for session in sessions { session.close() }
    }

    private func observe(_ session: LocalTerminalSession) {
        session.$lastVerificationRun.dropFirst()
            .receive(on: RunLoop.main)
            .sink { _ in TerminalWorkspaceStore.shared.verificationChanges.send() }
            .store(in: &subscriptions)
        session.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &subscriptions)
    }
}
