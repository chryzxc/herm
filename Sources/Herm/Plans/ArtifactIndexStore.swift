import Foundation

private final class ArtifactProgressConsumer: @unchecked Sendable {
    let progress: ArtifactIndexLoader.ProgressHandler
    private let lock = NSLock()
    private var canceled = false

    init(progress: @escaping ArtifactIndexLoader.ProgressHandler) { self.progress = progress }

    func cancel() {
        lock.lock()
        canceled = true
        lock.unlock()
    }

    @MainActor func send(_ value: ArtifactIndexLoader.SessionProgress) {
        lock.lock()
        let acceptsProgress = !canceled
        lock.unlock()
        if acceptsProgress { progress(value) }
    }
}

/// Disposable shared index for session/global browsers. Hermes history remains authoritative.
@MainActor
final class ArtifactIndexStore {
    static let shared = ArtifactIndexStore()
    private struct Key: Hashable {
        let owner: ObjectIdentifier
        let session: ProfileScopedID
    }
    private struct Pending {
        let generation: UUID
        let session: HermesSession
        let task: Task<ArtifactIndexLoader.SessionResult, Never>
        var consumers: [UUID: ArtifactProgressConsumer]
        var latestProgress: ArtifactIndexLoader.SessionProgress?
    }
    private var cached: [Key: ArtifactIndexLoader.CachedSession] = [:]
    private var order: [Key] = []
    private var pending: [Key: Pending] = [:]

    func load(
        owner: ObjectIdentifier, session: HermesSession, force: Bool,
        work: @escaping @MainActor @Sendable () async -> ArtifactIndexLoader.SessionResult
    ) async -> ArtifactIndexLoader.SessionResult {
        await load(owner: owner, session: session, force: force, onProgress: { _ in }, work: { _ in await work() })
    }

    func load(
        owner: ObjectIdentifier, session: HermesSession, force: Bool,
        onProgress: @escaping ArtifactIndexLoader.ProgressHandler,
        work:
            @escaping @MainActor @Sendable (@escaping ArtifactIndexLoader.ProgressHandler) async ->
            ArtifactIndexLoader.SessionResult
    ) async -> ArtifactIndexLoader.SessionResult {
        let key = Key(owner: owner, session: session.scopedID)
        if !force, let value = cached[key], value.matches(session) {
            return .init(sessionID: session.id, profileID: session.profileID, records: value.records, error: nil)
        }
        let token = UUID()
        let consumer = ArtifactProgressConsumer(progress: onProgress)
        let generation: UUID
        let task: Task<ArtifactIndexLoader.SessionResult, Never>
        if !force, var existing = pending[key], existing.session.lastUpdatedAt == session.lastUpdatedAt,
            existing.session.messageCount == session.messageCount
        {
            existing.consumers[token] = consumer
            pending[key] = existing
            task = existing.task
            generation = existing.generation
            if let progress = existing.latestProgress { consumer.send(progress) }
        } else {
            pending[key]?.task.cancel()
            generation = UUID()
            task = Task { [weak self] in
                await work { [weak self] progress in
                    self?.publish(progress, key: key, generation: generation)
                }
            }
            pending[key] = Pending(
                generation: generation, session: session, task: task,
                consumers: [token: consumer], latestProgress: nil)
        }
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            consumer.cancel()
            Task { @MainActor in self.release(key, token: token, generation: generation) }
        }
        if !Task.isCancelled, pending[key]?.generation == generation, result.error == nil {
            cached[key] = .init(session: session, records: result.records)
            order.removeAll { $0 == key }
            order.append(key)
            trim()
        }
        release(key, token: token, generation: generation)
        return result
    }

    private func publish(_ progress: ArtifactIndexLoader.SessionProgress, key: Key, generation: UUID) {
        guard var entry = pending[key], entry.generation == generation else { return }
        entry.latestProgress = progress
        pending[key] = entry
        for consumer in entry.consumers.values { consumer.send(progress) }
    }

    private func release(_ key: Key, token: UUID, generation: UUID) {
        guard var entry = pending[key], entry.generation == generation else { return }
        entry.consumers.removeValue(forKey: token)
        if entry.consumers.isEmpty {
            entry.task.cancel()
            pending.removeValue(forKey: key)
        } else {
            pending[key] = entry
        }
    }
    private func trim() {
        func bytes(_ value: ArtifactIndexLoader.CachedSession) -> Int {
            value.records.reduce(0) { $0 + ($1.generated?.source.utf8.count ?? $1.value.utf8.count) }
        }
        var count = cached.values.reduce(0) { $0 + bytes($1) }
        while order.count > 64 || count > 32 * 1_048_576 {
            guard !order.isEmpty else { break }
            let key = order.removeFirst()
            if let value = cached.removeValue(forKey: key) { count -= bytes(value) }
        }
    }
}
