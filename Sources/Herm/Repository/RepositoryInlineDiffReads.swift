import Combine
import Foundation

@MainActor
final class RepositoryInlineDiffReads: ObservableObject {
    struct Input: Equatable {
        let path: String
        let changes: RepositoryChangeSnapshot
        let revision: RepositoryChangeRevision?
        let expandedIDs: Set<String>

        fileprivate var requests: [Request] {
            guard !expandedIDs.isEmpty else { return [] }
            let identities = revision?.fileIdentities ?? [:]
            let stagedPaths = Set(changes.files.lazy.filter(\.isStaged).map(\.path))
            return changes.files.compactMap { file in
                guard expandedIDs.contains(file.id) else { return nil }
                let identity = identities[file.id]
                let index = file.isStaged || !stagedPaths.contains(file.path) ? nil : identities["staged:\(file.path)"]
                let uncertain = identity == nil || (!file.isStaged && stagedPaths.contains(file.path) && index == nil)
                return Request(
                    path: path, file: file, head: changes.headRevision, identity: identity, index: index,
                    fallback: uncertain ? revision?.fingerprint : nil,
                    refreshedAt: uncertain && revision == nil ? changes.refreshedAt : nil)
            }
        }
    }

    fileprivate struct Request: Equatable {
        let path: String
        let file: RepositoryFileChange
        let head: String?
        let identity: String?
        let index: String?
        let fallback: String?
        let refreshedAt: Date?
    }

    enum State: Equatable {
        case loading
        case ready(RepositoryDiff?)
    }

    @Published private(set) var states: [String: State] = [:]
    private var requested: [String: Request] = [:]
    private var pending: [Request] = []
    private var running: [String: Task<Void, Never>] = [:]
    private let read: @MainActor (String, RepositoryFileChange) async -> RepositoryDiff?

    init(read: @escaping @MainActor (String, RepositoryFileChange) async -> RepositoryDiff? = RepositoryService.diff) {
        self.read = read
    }

    func update(_ input: Input?) {
        let requests = input?.requests ?? []
        let next = Dictionary(requests.map { ($0.file.id, $0) }, uniquingKeysWith: { first, _ in first })
        var states = self.states
        for (id, previous) in requested where next[id] != previous {
            running[id]?.cancel()
            states[id] = nil
        }
        pending = pending.filter { next[$0.file.id] == $0 }
        for request in requests where requested[request.file.id] != request {
            pending.append(request)
            states[request.file.id] = .loading
        }
        requested = next
        if states != self.states { self.states = states }
        startReads()
    }

    private func startReads() {
        while running.count < 2,
            let index = pending.firstIndex(where: { running[$0.file.id] == nil })
        {
            let request = pending.remove(at: index)
            let id = request.file.id
            running[id] = Task { [weak self, read] in
                let diff = await read(request.path, request.file)
                guard let self else { return }
                running[id] = nil
                if !Task.isCancelled, requested[id] == request { states[id] = .ready(diff) }
                startReads()
            }
        }
    }
}
