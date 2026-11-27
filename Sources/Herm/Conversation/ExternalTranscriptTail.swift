import Foundation

/// Projections of the same session share reads, not transcript or scroll state.
@MainActor
final class ExternalTranscriptReads {
    private struct Key: Hashable {
        let client: ObjectIdentifier
        let path: String
    }

    private var pending: [Key: Task<UncheckedTranscriptValue<[String: Any]>, Error>] = [:]
    private var recent: [Key: (at: ContinuousClock.Instant, body: [String: Any])] = [:]

    func fetch(_ path: String, client: HermesRPCClientProtocol) async throws -> [String: Any] {
        try Task.checkCancellation()
        let key = Key(client: ObjectIdentifier(client), path: path)
        recent = recent.filter { $0.value.at.duration(to: .now) < .seconds(1) }
        if let hit = recent[key] { return hit.body }
        if let task = pending[key] { return try await task.value.value }
        let task = Task(priority: .utility) { UncheckedTranscriptValue(value: try await client.fetchHTTP(path)) }
        pending[key] = task
        defer { pending[key] = nil }
        let body = try await task.value.value
        // Only retain a small shared result window, even with many windows open.
        if recent.count < 16 {
            let loadedAt = ContinuousClock.now
            recent[key] = (loadedAt, body)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                if self?.recent[key]?.at == loadedAt { self?.recent[key] = nil }
            }
        }
        return body
    }
}

enum ExternalTranscriptTail {
    struct Merge {
        let messages: [ChatMessage]
        let inserted: Set<UUID>
    }

    /// Ignore timestamps the parser supplies for older tool records that have none.
    static func sameActivity(_ lhs: [ActiveToolCall], _ rhs: [ActiveToolCall]) -> Bool {
        lhs.elementsEqual(rhs) {
            $0.id == $1.id && $0.name == $1.name && $0.input == $1.input && $0.context == $1.context
                && $0.result == $1.result && $0.isComplete == $1.isComplete && $0.args == $1.args
        }
    }

    /// Hermes' stored row IDs order the tail. Keep older rows and local overlays in place.
    static func merge(
        current: [ChatMessage], previousRows: [Int: UUID], tail: [ChatMessage], tailRows: [Int: UUID], liveID: UUID
    ) -> Merge? {
        guard let newestKnownRow = previousRows.keys.max() else {
            return mergeLegacy(current: current, tail: tail, liveID: liveID)
        }
        let currentIndices = Dictionary(
            current.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        let rowsByMessage = Dictionary(tailRows.map { ($0.value, $0.key) }, uniquingKeysWith: max)
        var additions: [ChatMessage] = []
        var updated = current
        var changed = false
        for message in tail {
            guard let row = rowsByMessage[message.id] else { continue }
            if let index = currentIndices[message.id] {
                let previous = current[index]
                guard
                    previous.contentRevision != message.contentRevision
                        || previous.restoredImageURLs != message.restoredImageURLs
                        || !sameActivity(previous.activity, message.activity)
                        || previous.reactions != message.reactions
                else { continue }
                updated[index] = message.restoredImageURLs.isEmpty ? message.attachingImages(previous.images) : message
                changed = true
            } else if row > newestKnownRow {
                additions.append(message)
            }
        }
        guard changed || !additions.isEmpty else { return nil }
        let insertAt = currentIndices[liveID] ?? updated.endIndex
        updated.insert(contentsOf: additions, at: insertAt)
        return Merge(messages: updated, inserted: Set(additions.map(\.id)))
    }

    private static func mergeLegacy(current: [ChatMessage], tail: [ChatMessage], liveID: UUID) -> Merge? {
        let insertion = current.firstIndex { $0.id == liveID } ?? current.endIndex
        let additions: ArraySlice<ChatMessage>
        if insertion == 0 {
            additions = tail[...]
        } else {
            // Some older inline resumes have no row IDs. Only append after an unambiguous shared message.
            let anchor = current[insertion - 1]
            guard !anchor.text.isEmpty else { return nil }
            let matches = tail.indices.filter { tail[$0].role == anchor.role && tail[$0].text == anchor.text }
            guard matches.count == 1, let index = matches.first else { return nil }
            additions = tail.dropFirst(index + 1)
        }
        guard !additions.isEmpty else { return nil }
        var updated = current
        updated.insert(contentsOf: additions, at: insertion)
        return Merge(messages: updated, inserted: Set(additions.map(\.id)))
    }

    static func cursor(
        keeping previous: TranscriptHistoryCursor?, observing tail: TranscriptHistoryCursor
    ) -> TranscriptHistoryCursor? {
        guard var previous, let newest = previous.seenRowIDs.max() else { return previous }
        // Offsets are measured from the live tail. Keeping the old offset may
        // reread overlap, but adding the new count could skip rows after a concurrent prepend.
        previous.seenRowIDs.formUnion(tail.seenRowIDs.lazy.filter { $0 > newest })
        return previous
    }
}
