import Foundation

@MainActor
final class ConversationMarkdownPrefetch {
    private struct Input: Sendable {
        let messageID: UUID
        let revision: Int
        let source: String
        let key: MarkdownRenderKey
    }
    private struct Identity: Equatable {
        let sessionID: String?
        let range: Range<Int>
        let themeRevision: Int
        let messages: [String]
    }
    private var identity: Identity?
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0
    private(set) var committedDocuments = 0

    func cancel() {
        generation &+= 1
        task?.cancel()
        task = nil
        identity = nil
    }

    func update(
        messages: [ChatMessage], range: Range<Int>, sessionID: String?, streamingID: UUID?,
        isCurrent: @escaping @MainActor (UUID, Int) -> Bool
    ) {
        let range = ConversationMessageWindow.visibleRange(range, totalCount: messages.count)
        let page = ConversationMessageWindow.pageSize
        let indices =
            Array(max(0, range.lowerBound - page)..<range.lowerBound)
            + Array(range.upperBound..<min(messages.count, range.upperBound + page))
        var completed: [ChatMessage] = []
        for index in indices {
            let message = messages[index]
            guard message.id != streamingID, message.role == .hermes, !message.isError,
                message.systemEvent == nil, message.kanbanNotice == nil, !RichDocument.mentionsSurface(message.text)
            else { continue }
            completed.append(message)
        }
        let next = Identity(
            sessionID: sessionID, range: range, themeRevision: DockThemeRuntime.revision,
            messages: completed.map { "\($0.id):\($0.contentRevision)" })
        guard identity != next else { return }
        cancel()
        identity = next
        let generation = generation
        var inputs: [Input] = []
        for message in completed {
            let segments = ChatMediaSegment.split(
                message.text, delivered: ArtifactService.deliveredFiles(in: message.activity))
            for segment in segments {
                guard case .markdown(let text) = segment else { continue }
                let source = text.trimmingCharacters(in: .whitespacesAndNewlines)
                let key = MarkdownMessageView.renderKey(for: source)
                guard !source.isEmpty, MarkdownRenderDocumentCache.cached(source: source, key: key) == nil else {
                    continue
                }
                inputs.append(Input(messageID: message.id, revision: message.contentRevision, source: source, key: key))
            }
        }
        task = Task.detached(priority: .utility) { [weak self] in
            var seen: Set<MarkdownRenderKey> = []
            for input in inputs {
                guard !Task.isCancelled else { return }
                guard seen.insert(input.key).inserted else { continue }
                let document = MarkdownRenderDocumentBuilder.build(source: input.source, key: input.key)
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    guard let self, self.generation == generation, isCurrent(input.messageID, input.revision) else {
                        return
                    }
                    MarkdownRenderDocumentCache.insert(document, prefetched: true)
                    self.committedDocuments += 1
                }
            }
        }
    }

    deinit { task?.cancel() }
}
