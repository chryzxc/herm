import Combine
import CryptoKit
import Foundation

@MainActor
final class TerminalWorkspaceStore {
    static let shared = TerminalWorkspaceStore()
    private var workspaces: [String: TerminalTabStore] = [:]
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
    func closeWorkspace(key: String) { workspaces.removeValue(forKey: key)?.closeAll() }
    func shutdown() {
        workspaces.values.forEach { $0.closeAll() }
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
        self.persistenceKey = persistenceKey.map {
            "herm.terminal-layout." + SHA256.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        let layout = self.persistenceKey.flatMap { UserDefaults.standard.data(forKey: $0 + ".v2") }.flatMap {
            try? JSONDecoder().decode(TerminalLayout.self, from: $0)
        }
        let count =
            layout.map { max(1, min(16, $0.count)) } ?? self.persistenceKey.map {
                max(1, min(16, UserDefaults.standard.integer(forKey: $0)))
            } ?? 1
        let restored = (0..<count).map { _ in LocalTerminalSession() }
        sessions = restored
        selectedID = restored[min(max(0, layout?.selected ?? 0), count - 1)].id
        splitIDs = Array((layout?.splits ?? []).prefix(4)).compactMap {
            restored.indices.contains($0) ? restored[$0].id : nil
        }
        splitAxis = layout?.axis == 1 ? 1 : 0
        sessions.forEach(observe)
    }
    private struct TerminalLayout: Codable {
        let count: Int
        let selected: Int
        let splits: [Int]
        let axis: Int
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
    }

    func closeAll() {
        sessions.forEach { $0.close() }
    }

    private func observe(_ session: LocalTerminalSession) {
        session.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &subscriptions)
    }
}
