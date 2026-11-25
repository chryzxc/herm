import AppKit
import SwiftUI

enum DockBotRailMetrics {
    static let width: CGFloat = 72
    static let rowSize: CGFloat = 52
    static let avatarSize: CGFloat = 38
}

@MainActor
struct DockProfilePickerList<Header: View, Row: View>: View {
    let bots: [BotSummary]
    @ObservedObject var order: DockProfilePickerOrder
    let style: DockThemePalette
    var isRail = false
    /// A fixed row above the reorderable bots, such as "All profiles".
    var showsHeader = false
    @ViewBuilder var header: () -> Header
    @ViewBuilder let row: (BotSummary) -> Row
    @GestureState private var gestureSample: DragSample?
    @State private var drag: DockProfilePickerDrag?
    @State private var scrollTarget = DockScrollTarget()
    /// The scroll view's frame and the drag pointer in the same coordinate space.
    @State private var viewport: CGRect = .zero
    @State private var pointer: CGPoint = .zero
    @State private var edgeScroll: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dockWorkspaceScale) private var workspaceScale

    var body: some View {
        picker
            .onGeometryChange(for: CGRect.self) {
                $0.frame(in: .global)
            } action: {
                viewport = $0
            }
            .onChange(of: gestureSample) { previous, sample in
                // SwiftUI resets gesture state on both release and cancellation.
                if let previous, previous.token != sample?.token { endDrag(previous.token) }
                if let sample { updateDrag(sample, isNew: sample.token != previous?.token) }
            }
            .onDisappear {
                if let token = drag?.token { endDrag(token) }
            }
    }

    @ViewBuilder
    private var picker: some View {
        if isRail {
            pickerScroll
        } else {
            pickerScroll
                .frame(width: 300, height: min(CGFloat(bots.count + (showsHeader ? 1 : 0)) * rowPitch + 12, 360))
                .background(style.background)
        }
    }

    private var pickerScroll: some View {
        let ordered = order.ordered(bots)
        return ScrollView(.vertical, showsIndicators: !isRail) {
            LazyVStack(alignment: isRail ? .center : .leading, spacing: rowSpacing) {
                if showsHeader { header() }
                ForEach(Array(ordered.enumerated()), id: \.element.id) { index, bot in
                    reorderableRow(bot, index: index, count: ordered.count)
                        .modifier(
                            LiftedRow(
                                isLifted: drag?.id == bot.id,
                                scales: DockMotion.isEnabled(reduceMotion: reduceMotion),
                                offset: liftOffset(for: bot.id, at: index), style: style))
                }
            }
            .dockPadding(6)
            .frame(maxWidth: isRail ? .infinity : nil)
            .background(
                DockScrollViewProbe(target: scrollTarget, onAttach: clipDidAttach, onDetach: clipDidDetach))
        }
    }

    @ViewBuilder
    private func reorderableRow(_ bot: BotSummary, index: Int, count: Int) -> some View {
        if isRail {
            row(bot)
                .frame(height: rowHeight)
                .modifier(DockDragCursor(isEnabled: count > 1, isDragging: drag?.id == bot.id))
                // A click selects the bot. Once the drag starts, it owns the rest of the press.
                .highPriorityGesture(reorderGesture(for: bot.id, at: index))
                .accessibilityAdjustableAction { adjust(bot.id, direction: $0) }
        } else {
            HStack(spacing: 0) {
                row(bot)
                DockIcon(.dotsSixVertical)
                    .dockFont(.metadata, weight: .semibold)
                    .foregroundStyle(style.secondaryText)
                    .frame(width: 28, height: rowHeight)
                    .contentShape(Rectangle())
                    .modifier(DockDragCursor(isEnabled: true, isDragging: drag?.id == bot.id))
                    .gesture(reorderGesture(for: bot.id, at: index))
                    .accessibilityElement()
                    .accessibilityLabel("Reorder \(bot.name)")
                    .accessibilityValue("\(index + 1) of \(count)")
                    .accessibilityAdjustableAction { adjust(bot.id, direction: $0) }
                    .help("Drag to reorder")
            }
        }
    }

    private var rowSpacing: CGFloat { isRail ? DockWorkspaceScale.spacing(6, scale: workspaceScale) : 2 }
    private var rowHeight: CGFloat { isRail ? DockBotRailMetrics.rowSize : 38 }
    private var rowPitch: CGFloat { rowHeight + rowSpacing }

    /// Keeps the lifted row under the pointer while the list reflows around it.
    private func liftOffset(for id: String, at index: Int) -> CGFloat {
        guard let drag, drag.id == id else { return 0 }
        return drag.liftOffset(at: index, pitch: rowPitch)
    }

    private struct DragSample: Equatable {
        let token: UUID
        let id: String
        let start: Int
        let location: CGPoint
        let translation: CGFloat
    }

    private func reorderGesture(for id: String, at index: Int) -> some Gesture {
        // Distance 0 lifts the row as soon as the handle is held. Global space: the
        // handle moves with its row, so local translation would oscillate.
        DragGesture(minimumDistance: isRail ? 6 : 0, coordinateSpace: .global)
            .updating($gestureSample) { value, sample, _ in
                guard !isRail || bots.count > 1 else { return }
                sample = DragSample(
                    token: sample?.token ?? UUID(), id: id, start: sample?.start ?? index,
                    location: value.location, translation: value.translation.height)
            }
    }

    private func updateDrag(_ sample: DragSample, isNew: Bool) {
        if isNew {
            NSCursor.closedHand.set()
            withAnimation(liftAnimation) {
                drag = DockProfilePickerDrag(token: sample.token, id: sample.id, start: sample.start)
            }
        }
        guard drag?.token == sample.token else { return }
        if let attachment = drag?.attachment, attachment != scrollTarget.attachment { return }
        drag?.translation = sample.translation
        trackCurrentClip()
        pointer = sample.location
        updateOrder()
        updateEdgeScroll()
    }

    private func trackCurrentClip() {
        guard let clip = scrollTarget.scrollView?.contentView else { return }
        let origin = clip.bounds.minY
        if drag?.attachment == nil { drag?.bindClip(origin: origin, attachment: scrollTarget.attachment) }
        drag?.trackClip(origin: origin, isFlipped: clip.isFlipped)
    }

    private func updateOrder() {
        guard var state = drag else { return }
        withAnimation(DockMotion.animation(reduceMotion: reduceMotion, duration: 0.16)) {
            state.updateOrder(order, in: bots, pitch: rowPitch)
            if state.slot != drag?.slot { drag?.slot = state.slot }
        }
    }

    /// Scrolls the list while the pointer is held near or past a vertical edge. One step at a time, so the
    /// slot update always sees the rows the scroll revealed.
    private func updateEdgeScroll() {
        guard let token = drag?.token,
            drag?.isCurrent(token: token, attachment: scrollTarget.attachment) == true,
            DockEdgeAutoscroll.direction(pointer: pointer, viewport: viewport) != nil
        else { return stopEdgeScroll() }
        guard edgeScroll == nil else { return }
        edgeScroll = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(33))
                guard !Task.isCancelled, drag?.token == token else { return }
                scrollEdgeStep(token)
            }
        }
    }

    private func scrollEdgeStep(_ token: UUID) {
        guard drag?.isCurrent(token: token, attachment: scrollTarget.attachment) == true,
            let scrollView = scrollTarget.scrollView
        else { return endDrag(token) }
        guard let direction = DockEdgeAutoscroll.direction(pointer: pointer, viewport: viewport)
        else { return stopEdgeScroll() }
        let delta = DockEdgeAutoscroll.scrollStep(in: scrollView, toward: direction)
        // Scrolling may synchronously change the AppKit view hierarchy.
        guard drag?.isCurrent(token: token, attachment: scrollTarget.attachment) == true else { return endDrag(token) }
        guard delta != 0 else { return stopEdgeScroll() }
        let clip = scrollView.contentView
        // Publish actual travel even on ticks that don't cross a row boundary.
        drag?.trackClip(origin: clip.bounds.minY, isFlipped: clip.isFlipped)
        updateOrder()
    }

    private func clipDidAttach() {
        guard let token = drag?.token, drag?.attachment == nil else { return }
        let attachment = scrollTarget.attachment
        // The probe can attach during a SwiftUI update, even with the pointer stationary.
        Task { @MainActor in
            guard drag?.token == token, drag?.attachment == nil,
                scrollTarget.attachment == attachment
            else { return }
            trackCurrentClip()
            updateEdgeScroll()
        }
    }

    private func clipDidDetach() {
        guard let token = drag?.token else { return }
        // AppKit can detach during a SwiftUI update; end outside that update and only for this drag.
        Task { @MainActor in endDrag(token) }
    }

    /// Ends the drag and its edge scroll once, however the drag finishes.
    private func endDrag(_ token: UUID) {
        guard drag?.token == token else { return }
        stopEdgeScroll()
        pointer = .zero
        withAnimation(liftAnimation) { drag = nil }
        // Hover owns the open-hand cursor; don't push or pop its cursor stack here.
        NSCursor.arrow.set()
    }

    private func stopEdgeScroll() {
        edgeScroll?.cancel()
        edgeScroll = nil
    }

    private var liftAnimation: Animation? {
        DockMotion.isEnabled(reduceMotion: reduceMotion) ? .smooth(duration: 0.18) : nil
    }

    private func adjust(_ id: String, direction: AccessibilityAdjustmentDirection) {
        switch direction {
        case .increment: move(id, by: 1)
        case .decrement: move(id, by: -1)
        @unknown default: break
        }
    }

    private func move(_ id: String, by offset: Int) {
        if reduceMotion {
            order.move(id, by: offset, in: bots)
        } else {
            withAnimation(.dockEase(duration: 0.2)) { order.move(id, by: offset, in: bots) }
        }
    }
}

/// View state shared by lift and slot selection. Clip travel changes independently of the slot.
struct DockProfilePickerDrag {
    let token: UUID
    let id: String
    let start: Int
    var slot: Int
    var translation: CGFloat = 0
    private(set) var attachment: UUID?
    private var startOrigin: CGFloat?
    private var scrollTravel: CGFloat = 0

    init(token: UUID, id: String, start: Int) {
        self.token = token
        self.id = id
        self.start = start
        slot = start
    }

    func isCurrent(token: UUID, attachment: UUID) -> Bool {
        self.token == token && self.attachment == attachment
    }

    /// The first clip sample sets a baseline; its existing offset isn't drag travel.
    mutating func bindClip(origin: CGFloat, attachment: UUID) {
        guard self.attachment == nil else { return }
        self.attachment = attachment
        startOrigin = origin
    }

    mutating func trackClip(origin: CGFloat, isFlipped: Bool) {
        guard let startOrigin else { return }
        scrollTravel = DockEdgeAutoscroll.travel(from: startOrigin, to: origin, isFlipped: isFlipped)
    }

    /// Lands the dragged row on the slot the pointer and the list's own travel point at.
    @MainActor
    mutating func updateOrder(_ order: DockProfilePickerOrder, in bots: [BotSummary], pitch: CGFloat) {
        let target = self.target(pitch: pitch, count: bots.count)
        guard target != slot else { return }
        let ordered = order.ordered(bots)
        guard ordered.indices.contains(target), let current = ordered.firstIndex(where: { $0.id == id })
        else { return }
        slot = target
        guard target != current else { return }
        order.move(id, relativeTo: ordered[target].id, after: target > current, in: bots)
    }

    func target(pitch: CGFloat, count: Int) -> Int {
        DockProfilePickerReorder.target(
            start: start, translation: translation + scrollTravel, pitch: pitch, count: count)
    }

    func liftOffset(at index: Int, pitch: CGFloat) -> CGFloat {
        translation + scrollTravel - CGFloat(index - start) * pitch
    }
}

/// Raises the row being dragged above its neighbours and lets it follow the pointer;
/// releasing springs it back into its new slot.
private struct LiftedRow: ViewModifier {
    let isLifted: Bool
    let scales: Bool
    let offset: CGFloat
    let style: DockThemePalette

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(style.surface4)
                    .opacity(isLifted ? 1 : 0)
            )
            .scaleEffect(isLifted && scales ? 1.012 : 1)
            .offset(y: offset)
            .zIndex(isLifted ? 1 : 0)
    }
}

enum DockProfilePickerReorder {
    /// The index a row dragged `translation` points from `start` lands on.
    static func target(start: Int, translation: CGFloat, pitch: CGFloat, count: Int) -> Int {
        guard count > 0, pitch > 0 else { return start }
        return min(max(start + Int((translation / pitch).rounded()), 0), count - 1)
    }
}

extension DockProfilePickerList where Header == EmptyView {
    init(
        bots: [BotSummary], order: DockProfilePickerOrder, style: DockThemePalette, isRail: Bool = false,
        @ViewBuilder row: @escaping (BotSummary) -> Row
    ) {
        self.init(bots: bots, order: order, style: style, isRail: isRail, header: { EmptyView() }, row: row)
    }
}
