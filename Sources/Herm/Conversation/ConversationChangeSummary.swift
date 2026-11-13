import Foundation

/// A projection of the edit previews Hermes supplied, not a working-tree diff.
enum ConversationChangeSummary {
    struct File: Identifiable, Equatable {
        let path: String
        var previews: [String]
        var id: String { path }
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

    static func files(in calls: [ActiveToolCall]) -> [File] {
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
