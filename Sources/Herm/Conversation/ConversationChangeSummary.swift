import Foundation

/// A projection of the edit previews Hermes supplied, not a working-tree diff.
enum ConversationChangeSummary {
    struct File: Identifiable, Equatable {
        let path: String
        var previews: [String]
        var id: String { path }
    }

    struct Row: Identifiable, Equatable {
        let path: String
        var previews: [String]
        var delivery: String?
        var id: String { path }
    }

    static func merge(files: [File], delivered: [String]) -> [Row] {
        var rows = files.map { Row(path: $0.path, previews: $0.previews, delivery: nil) }
        for path in delivered {
            if let index = rows.firstIndex(where: { $0.path == path && $0.delivery == nil }) {
                rows[index].delivery = path
            } else if !rows.contains(where: { $0.delivery == path }) {
                rows.append(Row(path: path, previews: [], delivery: path))
            }
        }
        return rows
    }

    static func turnFiles(messages: [ChatMessage], at index: Int, streamingID: UUID?) -> [File] {
        guard messages.indices.contains(index), messages[index].role == .hermes,
            messages[index].systemEvent == nil, messages[index].kanbanNotice == nil,
            !messages[index].isBotHandoffReply
        else { return [] }
        let end = messages[(index + 1)...].firstIndex(where: { $0.role == .user }) ?? messages.endIndex
        let following = messages[(index + 1)..<end]
        guard !following.contains(where: { $0.role == .hermes && $0.systemEvent == nil && $0.kanbanNotice == nil }),
            !messages[index..<end].contains(where: { $0.id == streamingID })
        else { return [] }
        let start = messages[..<index].lastIndex(where: { $0.role == .user }).map { $0 + 1 } ?? 0
        return files(in: messages[start...index].flatMap(\.activity))
    }

    /// Every transcript body evaluation asks each mounted row for its turn's
    /// files; re-splitting completed diffs each time is pure waste because a
    /// completed call's preview never changes. Keyed by call id plus preview size
    /// and hash, so reused ids with different previews never share an entry.
    private struct CacheKey: Hashable {
        let calls: [String]
        let sizes: [Int]
        let hashes: [Int]
    }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [CacheKey: [File]] = [:]
    static let cacheLimit = 256

    static func files(in calls: [ActiveToolCall]) -> [File] {
        let diffs = calls.filter { $0.isComplete && $0.diffPreview != nil }
        guard !diffs.isEmpty else { return [] }
        let key = CacheKey(
            calls: diffs.map(\.id), sizes: diffs.map { $0.diffPreview?.utf8.count ?? 0 },
            hashes: diffs.map { $0.diffPreview?.hashValue ?? 0 })
        cacheLock.lock()
        let cached = cache[key]
        cacheLock.unlock()
        if let cached { return cached }
        let result = parseFiles(in: diffs)
        cacheLock.lock()
        if cache.count >= cacheLimit { cache.removeAll(keepingCapacity: true) }
        cache[key] = result
        cacheLock.unlock()
        return result
    }

    private static func parseFiles(in calls: [ActiveToolCall]) -> [File] {
        var files: [File] = []
        for call in calls where call.isComplete {
            guard let diff = call.diffPreview else { continue }
            var path: String?
            var lines: [String] = []
            func appendSection() {
                guard let path,
                    lines.contains(where: {
                        ($0.hasPrefix("+") && !$0.hasPrefix("+++"))
                            || ($0.hasPrefix("-") && !$0.hasPrefix("---"))
                    })
                else { return }
                let preview = lines.joined(separator: "\n")
                if let index = files.firstIndex(where: { $0.path == path }) {
                    files[index].previews.append(preview)
                } else {
                    files.append(File(path: path, previews: [preview]))
                }
            }
            for line in diff.components(separatedBy: "\n") {
                let parts = line.components(separatedBy: " → ")
                if parts.count == 2, parts[0].hasPrefix("a/"), parts[1].hasPrefix("b/") {
                    appendSection()
                    path = String(parts[1].dropFirst(2))
                    lines = []
                } else if path != nil {
                    lines.append(line)
                }
            }
            appendSection()
        }
        return files
    }
}
