import AppKit
import Combine
import os
import SwiftUI

struct ConversationTranscriptRowDescriptor: Identifiable, Equatable {
    enum Kind: Equatable {
        case startup
        case historyPlaceholder
        case message
        case streaming
        case approval
        case activity
    }

    let id: String
    let revision: Int
    let kind: Kind

    init(id: String, revision: Int = 0, kind: Kind) {
        self.id = id
        self.revision = revision
        self.kind = kind
    }
}

private extension ConversationTranscriptRowDescriptor.Kind {
    var identifier: String {
        switch self {
        case .startup: "startup"
        case .historyPlaceholder: "history"
        case .message: "message"
        case .streaming: "streaming"
        case .approval: "approval"
        case .activity: "activity"
        }
    }
}

struct ConversationTranscriptAnchor: Equatable {
    let rowID: String
    let offset: CGFloat
}

struct ConversationTranscriptDiagnostics: Equatable {
    var mountedCellCount = 0
    var reusedCellCount = 0
    var allocatedCellsByClass: [String: Int] = [:]
    var mountedCellsByClass: [String: Int] = [:]
    var nativeCellAllocations = 0
    var hostingViewAllocations = 0
    var measurementRequests = 0
    var measurementCacheHits = 0
    var synchronousMeasurements = 0
    var deferredMeasurements = 0
    var maxQueuedWork = 0
    var batchedHeightUpdates = 0
    var fullReloadCount = 0
    var targetedInvalidationCount = 0
    var tailAdjustmentCount = 0
    var browsingOriginChanges = 0
    var liveScrollFrames = 0
    var state = "pinned"
    var presentedMessageCount = 0
}

struct ConversationVirtualizedTranscript: NSViewRepresentable {
    let rows: [ConversationTranscriptRowDescriptor]
    let sessionID: String?
    let scrollRequest: Int
    let streamingText: StreamingText?
    let nativeSnapshots: [String: ConversationNativeRowSnapshot]
    let onImagePreview: (NSImage) -> Void
    let onTopReached: (ConversationTranscriptAnchor) -> Void
    let onPinnedChange: (Bool) -> Void
    let makeRow: (ConversationTranscriptRowDescriptor) -> AnyView

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeScrollView()
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(
            rows: rows,
            sessionID: sessionID,
            scrollRequest: scrollRequest,
            streamingText: streamingText,
            nativeSnapshots: nativeSnapshots,
            onImagePreview: onImagePreview,
            onTopReached: onTopReached,
            onPinnedChange: onPinnedChange,
            makeRow: makeRow
        )
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        private final class Cell: NSTableCellView {
            var hosted: NSHostingView<AnyView>?
            var native: ConversationNativeMessageCell?
            var representedRevision = 0
            var representedID: String?
            var representedWidth: CGFloat = 0

            func setContent(
                _ content: AnyView,
                width: CGFloat,
                id: String,
                revision: Int
            ) {
                let normalizedWidth = width.rounded(.up)
                if representedID == id,
                   representedRevision == revision,
                   abs(representedWidth - normalizedWidth) < 1,
                   hosted != nil {
                    hosted?.rootView = content
                    return
                }
                let view: NSHostingView<AnyView>
                if let existing = hosted {
                    view = existing
                } else {
                    view = NSHostingView(rootView: content)
                    view.translatesAutoresizingMaskIntoConstraints = false
                    addSubview(view)
                    NSLayoutConstraint.activate([
                        view.leadingAnchor.constraint(equalTo: leadingAnchor),
                        view.trailingAnchor.constraint(equalTo: trailingAnchor),
                        view.topAnchor.constraint(equalTo: topAnchor),
                        view.bottomAnchor.constraint(equalTo: bottomAnchor)
                    ])
                    hosted = view
                }
                view.rootView = content
                view.isHidden = false
                native?.isHidden = true
                representedID = id
                representedRevision = revision
                representedWidth = normalizedWidth
                view.frame.size.width = max(1, width)
            }

            func setNativeContent(
                _ snapshot: ConversationNativeRowSnapshot,
                width: CGFloat,
                id: String,
                revision: Int,
                imageAction: ((NSImage) -> Void)?
            ) {
                let normalizedWidth = width.rounded(.up)
                if representedID == id,
                   representedRevision == revision,
                   abs(representedWidth - normalizedWidth) < 1,
                   let native {
                    hosted?.isHidden = true
                    native.isHidden = false
                    native.setSnapshot(snapshot, revision: revision, width: width, imageAction: imageAction)
                    return
                }
                let value: ConversationNativeMessageCell
                if let existing = native {
                    value = existing
                } else {
                    value = ConversationNativeMessageCell()
                    value.translatesAutoresizingMaskIntoConstraints = false
                    addSubview(value)
                    NSLayoutConstraint.activate([
                        value.leadingAnchor.constraint(equalTo: leadingAnchor),
                        value.trailingAnchor.constraint(equalTo: trailingAnchor),
                        value.topAnchor.constraint(equalTo: topAnchor),
                        value.bottomAnchor.constraint(equalTo: bottomAnchor)
                    ])
                    native = value
                }
                hosted?.isHidden = true
                value.isHidden = false
                representedID = id
                representedRevision = revision
                representedWidth = normalizedWidth
                value.setSnapshot(snapshot, revision: revision, width: width, imageAction: imageAction)
            }

            func updateStreamingText(_ text: String) {
                native?.updateStreamingText(text)
            }

        }

        private weak var scrollView: NSScrollView?
        private let tableView = NSTableView()
        private var rows: [ConversationTranscriptRowDescriptor] = []
        private var sessionID: String?
        private var lastScrollRequest = 0
        private var streamingSubscription: AnyCancellable?
        private weak var streamingText: StreamingText?
        private var onTopReached: ((ConversationTranscriptAnchor) -> Void)?
        private var onPinnedChange: ((Bool) -> Void)?
        private var makeRow: ((ConversationTranscriptRowDescriptor) -> AnyView)?
        private var nativeSnapshots: [String: ConversationNativeRowSnapshot] = [:]
        private var streamingRowID: String?
        private var onImagePreview: ((NSImage) -> Void)?
        private let layoutStore = ConversationRowLayoutStore()
        private var rowIndexByID: [String: Int] = [:]
        private var layoutPreparationScheduled = false
        private var deferredLayoutPreparation = false
        private var pendingHeightIndexes = IndexSet()
        private var heightUpdateScheduled = false
        private var isLiveScrolling = false
        private var deferredRows: [ConversationTranscriptRowDescriptor]?
        private var deferredWidthChange = false
        private var deferredStreamingText: String?
        private var pendingNativeStreamingText: String?
        private var nativeLayoutUpdateScheduled = false
        private var pendingAnchor: ConversationTranscriptAnchor?
        private var isPinned = true
        private var topTriggerArmed = false
        private var tailAdjustmentScheduled = false
        private var observations: [NSObjectProtocol] = []
        private var isApplyingScroll = false
        private var lastTableWidth: CGFloat = 0
        private(set) var diagnostics = ConversationTranscriptDiagnostics()
        private let performanceLog = OSLog(
            subsystem: Bundle.main.bundleIdentifier ?? "HermesAgentDock",
            category: "ConversationTranscript"
        )

        var diagnosticsSnapshot: ConversationTranscriptDiagnostics { diagnostics }

        func makeScrollView() -> NSScrollView {
            let scrollView = NSScrollView()
            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = false
            scrollView.autohidesScrollers = true
            scrollView.drawsBackground = false
            scrollView.contentView.postsBoundsChangedNotifications = true
            scrollView.contentView.postsFrameChangedNotifications = true

            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("conversation"))
            tableView.addTableColumn(column)
            tableView.headerView = nil
            tableView.intercellSpacing = .zero
            tableView.usesAlternatingRowBackgroundColors = false
            tableView.selectionHighlightStyle = .none
            tableView.allowsEmptySelection = true
            tableView.allowsMultipleSelection = false
            tableView.delegate = self
            tableView.dataSource = self
            tableView.rowHeight = 72
            tableView.autoresizingMask = [.width, .height]

            scrollView.documentView = tableView
            tableView.frame.size.width = max(1, scrollView.contentSize.width)
            self.scrollView = scrollView
            observeBoundsChanges(of: scrollView)
            return scrollView
        }

        func update(
            rows: [ConversationTranscriptRowDescriptor],
            sessionID: String?,
            scrollRequest: Int,
            streamingText: StreamingText?,
            nativeSnapshots: [String: ConversationNativeRowSnapshot],
            onImagePreview: @escaping (NSImage) -> Void,
            onTopReached: @escaping (ConversationTranscriptAnchor) -> Void,
            onPinnedChange: @escaping (Bool) -> Void,
            makeRow: @escaping (ConversationTranscriptRowDescriptor) -> AnyView
        ) {
            self.onTopReached = onTopReached
            self.onPinnedChange = onPinnedChange
            self.makeRow = makeRow
            self.nativeSnapshots = nativeSnapshots
            self.onImagePreview = onImagePreview
            self.streamingText = streamingText
            if self.streamingSubscription == nil, let streamingText {
                self.streamingSubscription = streamingText.$text
                    .receive(on: RunLoop.main)
                    .sink { [weak self] _ in self?.streamingTextChanged() }
            }

            if self.sessionID != sessionID {
                self.sessionID = sessionID
                layoutStore.removeAll(keepingCapacity: true)
                deferredRows = nil
                deferredWidthChange = false
                deferredStreamingText = nil
                pendingNativeStreamingText = nil
                nativeLayoutUpdateScheduled = false
                pendingAnchor = nil
                isPinned = true
                topTriggerArmed = false
                self.rows = rows
                rebuildRowIndex()
                tableView.reloadData()
                diagnostics.fullReloadCount += 1
                diagnostics.presentedMessageCount = rows.filter { $0.kind == .message || $0.kind == .streaming }.count
                DispatchQueue.main.async { [weak self] in self?.scrollToBottom(animated: false) }
            } else if self.rows != rows {
                applyRows(rows)
            }

            if !isLiveScrolling { scheduleLayoutPreparation() }

            if scrollRequest != lastScrollRequest {
                lastScrollRequest = scrollRequest
                scrollToBottom(animated: false)
            }
        }

        private func applyRows(_ newRows: [ConversationTranscriptRowDescriptor]) {
            if isLiveScrolling {
                deferredRows = newRows
                return
            }
            let oldRows = rows
            rows = newRows
            rebuildRowIndex()
            let oldIDs = oldRows.map(\.id)
            let newIDs = newRows.map(\.id)
            if oldIDs == newIDs {
                let changed = zip(oldRows, newRows).enumerated().compactMap { index, pair in
                    pair.0 == pair.1 ? nil : index
                }
                for index in changed { invalidateHeight(for: newRows[index].id) }
                if !changed.isEmpty {
                    tableView.reloadData(forRowIndexes: IndexSet(changed), columnIndexes: IndexSet(integer: 0))
                    diagnostics.targetedInvalidationCount += changed.count
                }
            } else if applyStructuralDiff(from: oldIDs, to: newIDs) == false {
                // Complex changes are rare (normally only a session replacement,
                // which is handled above). Keep the table valid if an unexpected
                // reorder arrives, but expose it in diagnostics for tests.
                tableView.reloadData()
                diagnostics.fullReloadCount += 1
            }
            diagnostics.presentedMessageCount = newRows.filter { $0.kind == .message || $0.kind == .streaming }.count
            restorePendingAnchorIfNeeded()
            scheduleLayoutPreparation()
            if isPinned { scheduleTailAdjustment() }
        }

        private func invalidateHeight(for rowID: String) {
            layoutStore.keys
                .filter { $0.rowID == rowID }
                .forEach { layoutStore.removeValue(forKey: $0) }
        }

        private func rebuildRowIndex() {
            rowIndexByID.removeAll(keepingCapacity: true)
            streamingRowID = nil
            for (index, row) in rows.enumerated() {
                rowIndexByID[row.id] = index
                if row.kind == .streaming { streamingRowID = row.id }
            }
        }

        private func applyStructuralDiff(from oldIDs: [String], to newIDs: [String]) -> Bool {
            let oldSet = Set(oldIDs)
            let newSet = Set(newIDs)
            let removed = oldIDs.enumerated().compactMap { index, id in
                newSet.contains(id) ? nil : index
            }
            let inserted = newIDs.enumerated().compactMap { index, id in
                oldSet.contains(id) ? nil : index
            }
            guard oldIDs.filter({ newSet.contains($0) }) == newIDs.filter({ oldSet.contains($0) }) else {
                return false
            }
            tableView.beginUpdates()
            if !removed.isEmpty {
                tableView.removeRows(at: IndexSet(removed), withAnimation: [])
            }
            if !inserted.isEmpty {
                tableView.insertRows(at: IndexSet(inserted), withAnimation: [])
            }
            tableView.endUpdates()
            diagnostics.targetedInvalidationCount += removed.count + inserted.count
            return true
        }

        private func scheduleLayoutPreparation() {
            guard !isLiveScrolling else {
                deferredLayoutPreparation = true
                return
            }
            guard !layoutPreparationScheduled else { return }
            layoutPreparationScheduled = true
            diagnostics.deferredMeasurements += 1
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.layoutPreparationScheduled = false
                self.prepareNativeLayoutsInBudget()
            }
        }

        private func prepareNativeLayoutsInBudget() {
            let signpostID = OSSignpostID(log: performanceLog)
            os_signpost(.begin, log: performanceLog, name: "LayoutPreparation", signpostID: signpostID)
            let width = max(1, tableView.bounds.width.rounded(.up))
            let scale = max(1, NSScreen.main?.backingScaleFactor ?? 2)
            let visible = tableView.rows(in: tableView.visibleRect)
            let visibleStart = visible.location == NSNotFound ? 0 : visible.location
            let visibleEnd = min(rows.count, visibleStart + visible.length + 12)
            let indexes = Array(visibleStart..<visibleEnd) + Array(0..<min(rows.count, 60))
            var changedIndexes = IndexSet()
            let start = CFAbsoluteTimeGetCurrent()
            for index in indexes where index < rows.count {
                let row = rows[index]
                guard let snapshot = nativeSnapshots[row.id] else { continue }
                let rowID = row.id
                let revision = row.revision
                let key = ConversationRowLayoutKey(
                    sessionID: sessionID,
                    rowID: rowID,
                    revision: revision,
                    width: Int(width),
                    scale: Int(scale.rounded())
                )
                if layoutStore[key] == nil {
                    layoutStore[key] = ConversationRowLayoutEngine.layout(snapshot: snapshot, width: width, scale: scale)
                    diagnostics.measurementRequests += 1
                    changedIndexes.insert(index)
                } else {
                    diagnostics.measurementCacheHits += 1
                }
                if (CFAbsoluteTimeGetCurrent() - start) >= 0.002 { break }
            }
            if !changedIndexes.isEmpty, !isLiveScrolling {
                diagnostics.batchedHeightUpdates += 1
                scheduleHeightUpdate(changedIndexes)
                if isPinned { scheduleTailAdjustment() }
            }
            if deferredLayoutPreparation {
                deferredLayoutPreparation = false
                scheduleLayoutPreparation()
            }
            os_signpost(.end, log: performanceLog, name: "LayoutPreparation", signpostID: signpostID)
        }

        private func observeBoundsChanges(of scrollView: NSScrollView) {
            observations.append(NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleBoundsChange() }
            })
            observations.append(NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: tableView,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.tableWidthChanged() }
            })
            observations.append(NotificationCenter.default.addObserver(
                forName: NSScrollView.willStartLiveScrollNotification,
                object: scrollView,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isLiveScrolling = true
                    // A live-scroll gesture is user-owned. Stop automatic
                    // following before the first bounds notification arrives.
                    self.isPinned = false
                    self.diagnostics.state = "browsing"
                    self.onPinnedChange?(false)
                }
            })
            observations.append(NotificationCenter.default.addObserver(
                forName: NSScrollView.didEndLiveScrollNotification,
                object: scrollView,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.isLiveScrolling = false
                    if let rows = self?.deferredRows {
                        self?.deferredRows = nil
                        self?.applyRows(rows)
                    }
                    if self?.deferredWidthChange == true {
                        self?.deferredWidthChange = false
                        self?.tableWidthChanged()
                    }
                    if let text = self?.deferredStreamingText {
                        self?.deferredStreamingText = nil
                        self?.applyStreamingText(text)
                    }
                    if let pending = self?.pendingHeightIndexes, !pending.isEmpty {
                        self?.scheduleHeightUpdate(pending)
                    }
                    self?.deferredLayoutPreparation = false
                    self?.scheduleLayoutPreparation()
                }
            })
        }

        private func scheduleHeightUpdate(_ indexes: IndexSet) {
            guard !indexes.isEmpty else { return }
            pendingHeightIndexes.formUnion(indexes)
            guard !heightUpdateScheduled else { return }
            heightUpdateScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.heightUpdateScheduled = false
                guard !self.isLiveScrolling else { return }
                let pending = self.pendingHeightIndexes
                self.pendingHeightIndexes.removeAll()
                guard !pending.isEmpty else { return }
                self.tableView.noteHeightOfRows(withIndexesChanged: pending)
            }
        }

        private func streamingTextChanged() {
            if isLiveScrolling {
                deferredStreamingText = streamingText?.text ?? ""
                return
            }
            applyStreamingText(streamingText?.text ?? "")
        }

        private func applyStreamingText(_ text: String) {
            guard let streamingRowID,
                  rowIndexByID[streamingRowID] != nil else { return }
            pendingNativeStreamingText = text
            guard !nativeLayoutUpdateScheduled else { return }
            let signpostID = OSSignpostID(log: performanceLog)
            os_signpost(.begin, log: performanceLog, name: "StreamingTailUpdate", signpostID: signpostID)
            nativeLayoutUpdateScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.nativeLayoutUpdateScheduled = false
                let latestText = self.pendingNativeStreamingText ?? text
                self.pendingNativeStreamingText = nil
                guard !self.isLiveScrolling,
                      let streamingRowID = self.streamingRowID,
                      let index = self.rowIndexByID[streamingRowID] else {
                    os_signpost(.end, log: self.performanceLog, name: "StreamingTailUpdate", signpostID: signpostID)
                    return
                }
                if let cell = self.tableView.view(atColumn: 0, row: index, makeIfNecessary: false) as? Cell {
                    cell.updateStreamingText(latestText)
                }
                let rowID = streamingRowID
                if case .streaming(let id, let timestamp, let modelName, let duration, _) = self.nativeSnapshots[rowID] {
                    self.nativeSnapshots[rowID] = .streaming(
                        id: id,
                        timestamp: timestamp,
                        modelName: modelName,
                        responseDuration: duration,
                        text: latestText
                    )
                }
                self.invalidateHeight(for: self.rows[index].id)
                self.scheduleHeightUpdate(IndexSet(integer: index))
                self.scheduleLayoutPreparation()
                self.scheduleTailAdjustment()
                os_signpost(.end, log: self.performanceLog, name: "StreamingTailUpdate", signpostID: signpostID)
            }
        }

        private func tableWidthChanged() {
            guard !isLiveScrolling else {
                deferredWidthChange = true
                return
            }
            let width = tableView.bounds.width.rounded(.up)
            guard width > 0, width != lastTableWidth else { return }
            lastTableWidth = width
            tableView.tableColumns.first?.width = width
            layoutStore.removeAll(keepingCapacity: true)
            scheduleHeightUpdate(IndexSet(integersIn: 0..<rows.count))
            scheduleLayoutPreparation()
        }

        private func handleBoundsChange() {
            guard !isApplyingScroll else { return }
            if isLiveScrolling { diagnostics.liveScrollFrames += 1 }
            if !isLiveScrolling { scheduleLayoutPreparation() }
            let atBottom = isAtBottom()
            if atBottom != isPinned {
                isPinned = atBottom
                diagnostics.state = atBottom ? "pinned" : "browsing"
                onPinnedChange?(atBottom)
            }
            if tableView.visibleRect.minY > 80 { topTriggerArmed = true }
            guard tableView.visibleRect.minY <= 24,
                  topTriggerArmed,
                  let anchor = visibleAnchor(),
                  rows.contains(where: { $0.kind != .historyPlaceholder }) else { return }
            topTriggerArmed = false
            pendingAnchor = anchor
            onTopReached?(anchor)
        }

        private func visibleAnchor() -> ConversationTranscriptAnchor? {
            let rowsInView = tableView.rows(in: tableView.visibleRect)
            guard rowsInView.location != NSNotFound,
                  rowsInView.location < rows.count else { return nil }
            let index = rowsInView.location
            let rect = tableView.rect(ofRow: index)
            return ConversationTranscriptAnchor(
                rowID: rows[index].id,
                offset: tableView.visibleRect.minY - rect.minY
            )
        }

        private func restorePendingAnchorIfNeeded() {
            guard let anchor = pendingAnchor,
                  let index = rows.firstIndex(where: { $0.id == anchor.rowID }) else { return }
            pendingAnchor = nil
            DispatchQueue.main.async { [weak self] in
                guard let self, let scrollView = self.scrollView else { return }
                self.tableView.layoutSubtreeIfNeeded()
                var bounds = scrollView.contentView.bounds
                bounds.origin.y = self.tableView.rect(ofRow: index).minY - anchor.offset
                let legal = scrollView.contentView.constrainBoundsRect(bounds)
                self.isApplyingScroll = true
                scrollView.contentView.scroll(to: legal.origin)
                scrollView.reflectScrolledClipView(scrollView.contentView)
                self.isApplyingScroll = false
                self.isPinned = self.isAtBottom()
                self.diagnostics.state = self.isPinned ? "pinned" : "browsing"
            }
        }

        private func scheduleTailAdjustment() {
            guard isPinned, !tailAdjustmentScheduled else { return }
            tailAdjustmentScheduled = true
            diagnostics.tailAdjustmentCount += 1
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.tailAdjustmentScheduled = false
                if self.isPinned { self.scrollToBottom(animated: false) }
            }
        }

        private func isAtBottom() -> Bool {
            guard let scrollView else { return true }
            let bounds = scrollView.contentView.bounds
            let legal = scrollView.contentView.constrainBoundsRect(bounds)
            return abs(bounds.maxY - legal.maxY) <= 1
        }

        func scrollToBottom(animated: Bool) {
            guard let scrollView else { return }
            tableView.layoutSubtreeIfNeeded()
            var bounds = scrollView.contentView.bounds
            let legal = scrollView.contentView.constrainBoundsRect(bounds)
            bounds.origin = legal.origin
            isApplyingScroll = true
            if animated {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.22
                    scrollView.contentView.animator().setBoundsOrigin(bounds.origin)
                }
            } else {
                scrollView.contentView.scroll(to: bounds.origin)
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
            isApplyingScroll = false
            isPinned = true
            onPinnedChange?(true)
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let identifier = NSUserInterfaceItemIdentifier(
                "conversation-cell-\(reuseClass(for: row))"
            )
            let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? Cell
            let cell = reused ?? {
                let value = Cell()
                value.identifier = identifier
                diagnostics.allocatedCellsByClass[identifier.rawValue, default: 0] += 1
                return value
            }()
            if reused != nil { diagnostics.reusedCellCount += 1 }
            let visibleRows = tableView.rows(in: tableView.visibleRect)
            diagnostics.mountedCellCount = visibleRows.location == NSNotFound ? 0 : visibleRows.length
            diagnostics.mountedCellsByClass[identifier.rawValue] = diagnostics.mountedCellsByClass[identifier.rawValue, default: 0] + 1
            guard row < rows.count else { return cell }
            let signpostID = OSSignpostID(log: performanceLog)
            os_signpost(.begin, log: performanceLog, name: "CellConfiguration", signpostID: signpostID)
            let rowID = rows[row].id
            let revision = rows[row].revision
            if let native = nativeSnapshots[rowID] {
                if cell.native == nil { diagnostics.nativeCellAllocations += 1 }
                cell.setNativeContent(
                    native,
                    width: tableView.bounds.width,
                    id: rowID,
                    revision: revision,
                    imageAction: onImagePreview
                )
                os_signpost(.end, log: performanceLog, name: "CellConfiguration", signpostID: signpostID)
                return cell
            }
            guard let makeRow else {
                os_signpost(.end, log: performanceLog, name: "CellConfiguration", signpostID: signpostID)
                return cell
            }
            if cell.hosted == nil { diagnostics.hostingViewAllocations += 1 }
            cell.setContent(
                makeRow(rows[row]),
                width: tableView.bounds.width,
                id: rowID,
                revision: revision
            )
            os_signpost(.end, log: performanceLog, name: "CellConfiguration", signpostID: signpostID)
            return cell
        }

        private func reuseClass(for row: Int) -> String {
            guard row < rows.count else { return "fallback" }
            guard let snapshot = nativeSnapshots[rows[row].id] else {
                return rows[row].kind.identifier
            }
            switch snapshot {
            case .streaming:
                return "streaming"
            case .message(let message):
                if message.isError { return "error" }
                return message.role == .user ? "user" : "assistant"
            }
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard row < rows.count else { return 1 }
            if nativeSnapshots[rows[row].id] != nil {
                let layoutKey = ConversationRowLayoutKey(
                    sessionID: sessionID,
                    rowID: rows[row].id,
                    revision: rows[row].revision,
                    width: Int(tableView.bounds.width.rounded(.up)),
                    scale: Int((NSScreen.main?.backingScaleFactor ?? 2).rounded())
                )
                if let layout = layoutStore[layoutKey] { return layout.height }
                return estimatedHeight(for: rows[row])
            }
            return estimatedHeight(for: rows[row])
        }

        private func estimatedHeight(for row: ConversationTranscriptRowDescriptor) -> CGFloat {
            switch row.kind {
            case .startup: return 300
            case .historyPlaceholder: return 50
            case .approval: return 180
            case .activity: return 42
            case .message, .streaming: return 72
        }
    }
}
}
