import AppKit
import Foundation

struct ConversationPreparedPage {
    let documents: [MarkdownRenderKey: MarkdownRenderDocument]
    let measurements: [NativeMarkdownCompletedHeightCache.Key: NativeMarkdownCompletedHeightCache.Measurement]
}

@MainActor
final class ConversationMarkdownPrefetch {
    private struct Candidate: Sendable {
        let messageID: UUID
        let revision: Int
        let source: String
        let activity: [ActiveToolCall]
    }
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
        let context: NativeMarkdownDocumentContainerView.MeasurementContext?
    }
    private struct WarmJob {
        let input: Input
        let document: MarkdownRenderDocument
        var index = 0
        var context: NativeMarkdownDocumentContainerView.MeasurementContext?
        var offset: Int?
    }
    private enum WarmResult { case finished, waiting, worked, progressed }
    private var identity: Identity?
    private var task: Task<Void, Never>?
    private var warmTask: Task<Void, Never>?
    private var warmQueue: [WarmJob] = []
    private var generation: UInt64 = 0
    private var inputsByMessage: [UUID: [Input]] = [:]
    private var pendingMessages: Set<UUID> = []
    private var requestedMessageIDs: Set<UUID> = []
    private var requestedDocumentKeys: Set<MarkdownRenderKey> = []
    private var requestedDocuments: [MarkdownRenderKey: MarkdownRenderDocument] = [:]
    private var requestedMeasurements:
        [NativeMarkdownCompletedHeightCache.Key: NativeMarkdownCompletedHeightCache.Measurement] = [:]
    private(set) var preparedPage: ConversationPreparedPage?
    var onProgress: (() -> Void)?
    private(set) var committedDocuments = 0
    private(set) var preparationSlices = 0
    private(set) var maximumPreparationSliceNanoseconds: UInt64 = 0

    func cancel() {
        generation &+= 1
        task?.cancel()
        task = nil
        warmTask?.cancel()
        warmTask = nil
        warmQueue.removeAll()
        inputsByMessage.removeAll()
        pendingMessages.removeAll()
        cancelRequest()
        identity = nil
    }

    func update(
        messages: [ChatMessage], range: Range<Int>, sessionID: String?, streamingID: UUID?,
        controller: ConversationScrollController? = nil,
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
                message.systemEvent == nil, message.kanbanNotice == nil
            else { continue }
            completed.append(message)
        }
        let next = Identity(
            sessionID: sessionID, range: range, themeRevision: DockThemeRuntime.revision,
            messages: completed.map { "\($0.id):\($0.contentRevision)" },
            context: controller?.markdownMeasurementContext)
        guard identity != next else { return }
        cancel()
        identity = next
        let generation = generation
        let candidates = completed.map {
            Candidate(messageID: $0.id, revision: $0.contentRevision, source: $0.text, activity: $0.activity)
        }
        pendingMessages = Set(candidates.map(\.messageID))
        task = Task.detached(priority: .utility) { [weak self] in
            var segmented: [(Candidate, [String])] = []
            for candidate in candidates {
                guard !Task.isCancelled else { return }
                let sources: [String]
                if RichDocument.mentionsSurface(candidate.source) {
                    sources = []
                } else {
                    sources = ChatMediaSegment.split(
                        candidate.source, delivered: ArtifactService.deliveredFiles(in: candidate.activity)
                    ).compactMap { segment in
                        guard case .markdown(let text) = segment else { return nil }
                        let source = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        return source.isEmpty ? nil : source
                    }
                }
                segmented.append((candidate, sources))
            }
            let preparedSegments = segmented
            let preparedInputs = await MainActor.run { [weak self] in
                guard let self, self.generation == generation else { return [Input]() }
                var inputs: [Input] = []
                for (candidate, sources) in preparedSegments {
                    defer { self.pendingMessages.remove(candidate.messageID) }
                    guard isCurrent(candidate.messageID, candidate.revision) else { continue }
                    for source in sources {
                        let key = MarkdownMessageView.renderKey(for: source)
                        let input = Input(
                            messageID: candidate.messageID, revision: candidate.revision, source: source, key: key)
                        self.inputsByMessage[candidate.messageID, default: []].append(input)
                        if let document = MarkdownRenderDocumentCache.cached(source: source, key: key) {
                            self.enqueueWarm(input, document: document, controller: controller, isCurrent: isCurrent)
                        } else {
                            inputs.append(input)
                        }
                    }
                }
                self.onProgress?()
                return inputs
            }
            var seen: Set<MarkdownRenderKey> = []
            var inputs = preparedInputs.filter { seen.insert($0.key).inserted }
            while !inputs.isEmpty {
                guard !Task.isCancelled else { return }
                let candidates = inputs
                let next = await MainActor.run { [weak self] in
                    candidates.firstIndex { self?.isRequested($0) == true } ?? 0
                }
                let input = inputs.remove(at: next)
                let document = MarkdownRenderDocumentBuilder.build(source: input.source, key: input.key)
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    guard let self, self.generation == generation, isCurrent(input.messageID, input.revision) else {
                        return
                    }
                    MarkdownRenderDocumentCache.insert(document, prefetched: true)
                    self.committedDocuments += 1
                    self.enqueueWarm(input, document: document, controller: controller, isCurrent: isCurrent)
                    self.onProgress?()
                }
            }
            await MainActor.run { [weak self] in
                guard let self, self.generation == generation else { return }
                self.task = nil
                self.onProgress?()
            }
        }
    }

    private func enqueueWarm(
        _ input: Input, document: MarkdownRenderDocument, controller: ConversationScrollController?,
        isCurrent: @escaping @MainActor (UUID, Int) -> Bool
    ) {
        guard let controller else { return }
        warmQueue.append(WarmJob(input: input, document: document))
        guard warmTask == nil else { return }
        let generation = generation
        warmTask = Task { @MainActor [weak self, weak controller] in
            let textMeasurer = NativeMarkdownTextSectionView()
            let codeMeasurer = NativeMarkdownCodeView()
            var sliceWork: UInt64 = 0
            while !Task.isCancelled {
                guard let controller else { return }
                let workStarted = DispatchTime.now().uptimeNanoseconds
                let result =
                    self?.warmNext(
                        controller: controller, generation: generation, isCurrent: isCurrent,
                        textMeasurer: textMeasurer, codeMeasurer: codeMeasurer) ?? .finished
                let elapsed = DispatchTime.now().uptimeNanoseconds &- workStarted
                if case .worked = result {
                    self?.recordPreparationSlice(elapsed)
                } else if case .progressed = result {
                    self?.recordPreparationSlice(elapsed)
                }
                switch result {
                case .finished:
                    self?.onProgress?()
                    return
                case .waiting:
                    sliceWork = 0
                    try? await Task.sleep(for: .milliseconds(80))
                case .worked, .progressed:
                    sliceWork &+= elapsed
                    if case .progressed = result { self?.onProgress?() }
                    await Task.yield()
                    if sliceWork >= 2_000_000 {
                        try? await Task.sleep(for: .milliseconds(2))
                        sliceWork = 0
                    }
                }
            }
        }
    }

    private func warmNext(
        controller: ConversationScrollController, generation: UInt64,
        isCurrent: @MainActor (UUID, Int) -> Bool,
        textMeasurer: NativeMarkdownTextSectionView, codeMeasurer: NativeMarkdownCodeView
    ) -> WarmResult {
        guard self.generation == generation else { return .finished }
        guard !warmQueue.isEmpty else {
            warmTask = nil
            return .finished
        }
        guard let clipView = controller.clipView,
            !Self.isDraggingDivider(above: clipView), let window = clipView.window,
            window.isVisible, !window.isMiniaturized, !window.inLiveResize,
            window.occlusionState.contains(.visible) || controller.allowsOccludedPreparationForTesting,
            let context = controller.markdownMeasurementContext,
            context.themeRevision == DockThemeRuntime.revision,
            context.mentionRevision == BotMentions.revision, context.themeID == DockThemeRuntime.current
        else { return .waiting }
        let requested = warmQueue.firstIndex { isRequested($0.input) }
        guard !controller.isUserScrolling || requested != nil else { return .waiting }
        let next = requested ?? 0
        // Both scratch views are shared, so an interrupted section must restart
        // if a newly requested page takes over the measurer.
        for index in warmQueue.indices where index != next && warmQueue[index].offset != nil {
            warmQueue[index].offset = nil
        }
        var job = warmQueue.remove(at: next)
        guard isCurrent(job.input.messageID, job.input.revision) else { return .worked }
        if job.context != context {
            job.context = context
            job.index = 0
            job.offset = nil
        }
        guard job.index < job.document.sections.count else { return .worked }
        let section = job.document.sections[job.index]
        let key = NativeMarkdownDocumentContainerView.measurementKey(for: section, context: context)
        if job.offset == nil, let measurement = NativeMarkdownCompletedHeightCache.measurement(for: key) {
            if isRequested(job.input) { requestedMeasurements[key] = measurement }
            job.index += 1
        } else {
            if job.offset == nil {
                if case .code(let language) = section.kind {
                    codeMeasurer.update(
                        code: section.source, language: language, bodySize: context.bodySize, deferMeasurement: true)
                    codeMeasurer.beginIncrementalLayout()
                } else {
                    textMeasurer.update(
                        markdown: section.source, kind: section.kind,
                        bodySize: context.bodySize, bodyWeight: context.bodyWeight)
                    textMeasurer.beginIncrementalLayout(forWidth: context.width)
                }
                job.offset = 0
            }
            if case .code = section.kind {
                let offset = codeMeasurer.advanceIncrementalLayout(from: job.offset ?? 0)
                job.offset = offset
                if offset >= codeMeasurer.incrementalTextLength {
                    codeMeasurer.finishIncrementalLayout()
                    NativeMarkdownCompletedHeightCache.store(
                        codeMeasurer.measuredHeight(forWidth: context.width), for: key,
                        codeSize: codeMeasurer.contentSize)
                    if isRequested(job.input) {
                        requestedMeasurements[key] = .init(
                            height: codeMeasurer.measuredHeight(forWidth: context.width),
                            codeSize: codeMeasurer.contentSize)
                    }
                    job.index += 1
                    job.offset = nil
                }
            } else {
                let offset = textMeasurer.advanceIncrementalLayout(from: job.offset ?? 0)
                job.offset = offset
                if offset >= textMeasurer.incrementalTextLength {
                    let size = textMeasurer.finishIncrementalLayout(forWidth: context.width)
                    NativeMarkdownCompletedHeightCache.store(size.height, for: key)
                    if isRequested(job.input) {
                        requestedMeasurements[key] = .init(height: size.height, codeSize: nil)
                    }
                    job.index += 1
                    job.offset = nil
                }
            }
        }
        if job.index < job.document.sections.count { warmQueue.insert(job, at: 0) }
        return job.index < job.document.sections.count ? .worked : .progressed
    }

    func isReady(messageIDs: [UUID], context: NativeMarkdownDocumentContainerView.MeasurementContext) -> Bool {
        let requested = Set(messageIDs)
        if requested != requestedMessageIDs {
            cancelRequest()
            requestedMessageIDs = requested
        }
        requestedDocumentKeys = Set(messageIDs.flatMap { (inputsByMessage[$0] ?? []).map(\.key) })
        for id in messageIDs {
            if pendingMessages.contains(id) {
                preparedPage = nil
                return false
            }
            for input in inputsByMessage[id] ?? [] {
                guard
                    let document = requestedDocuments[input.key]
                        ?? MarkdownRenderDocumentCache.cached(source: input.source, key: input.key)
                else {
                    preparedPage = nil
                    restartIfIdle()
                    return false
                }
                requestedDocuments[input.key] = document
                for section in document.sections {
                    let key = NativeMarkdownDocumentContainerView.measurementKey(for: section, context: context)
                    guard
                        let measurement = requestedMeasurements[key]
                            ?? NativeMarkdownCompletedHeightCache.measurement(for: key)
                    else {
                        preparedPage = nil
                        restartIfIdle()
                        return false
                    }
                    requestedMeasurements[key] = measurement
                }
            }
        }
        preparedPage = ConversationPreparedPage(documents: requestedDocuments, measurements: requestedMeasurements)
        return true
    }

    func cancelRequest() {
        requestedMessageIDs.removeAll()
        requestedDocumentKeys.removeAll()
        requestedDocuments.removeAll()
        requestedMeasurements.removeAll()
        preparedPage = nil
    }

    private func isRequested(_ input: Input) -> Bool {
        requestedMessageIDs.contains(input.messageID) || requestedDocumentKeys.contains(input.key)
    }

    private func recordPreparationSlice(_ nanoseconds: UInt64) {
        preparationSlices += 1
        maximumPreparationSliceNanoseconds = max(maximumPreparationSliceNanoseconds, nanoseconds)
    }

    private func restartIfIdle() {
        guard task == nil, warmTask == nil else { return }
        identity = nil
        DispatchQueue.main.async { [weak self] in self?.onProgress?() }
    }

    private static func isDraggingDivider(above view: NSView) -> Bool {
        var ancestor: NSView? = view
        while let current = ancestor {
            if let split = current as? FractionPreservingSplitView, split.isDraggingDivider { return true }
            ancestor = current.superview
        }
        return false
    }

    deinit {
        task?.cancel()
        warmTask?.cancel()
    }
}
