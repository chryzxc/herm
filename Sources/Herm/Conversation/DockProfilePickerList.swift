import AppKit
import SwiftUI

@MainActor
struct DockProfilePickerList<Header: View, Row: View>: View {
    let bots: [BotSummary]
    @ObservedObject var order: DockProfilePickerOrder
    let style: DockThemePalette
    /// A fixed row above the reorderable bots, such as "All profiles".
    var showsHeader = false
    @ViewBuilder var header: () -> Header
    @ViewBuilder let row: (BotSummary) -> Row
    /// The row being dragged, the index it started from, and the pointer's travel.
    @State private var drag: (id: String, start: Int, slot: Int, translation: CGFloat)?
    @State private var scrollTarget = DockScrollTarget()
    /// The scroll view's frame in the same space as the drag, and the pointer inside it.
    @State private var viewport: CGRect = .zero
    @State private var pointerY: CGFloat = 0
    @State private var dragStartOriginY: CGFloat = 0
    @State private var dragIsFlipped = true
    @State private var edgeScroll: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let ordered = order.ordered(bots)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if showsHeader { header() }
                ForEach(Array(ordered.enumerated()), id: \.element.id) { index, bot in
                    HStack(spacing: 0) {
                        row(bot)
                        DockIcon(.dotsSixVertical)
                            .dockFont(.metadata, weight: .semibold)
                            .foregroundStyle(style.secondaryText)
                            .frame(width: 28, height: 38)
                            .contentShape(Rectangle())
                            .modifier(DockDragCursor(isEnabled: true, isDragging: drag?.id == bot.id))
                            // A gesture, not `.onDrag`: an item-provider drag never starts from
                            // inside the popover's scroll view, and a focusable handle only drew a
                            // focus ring on click.
                            .gesture(reorderGesture(for: bot.id, at: index))
                            .accessibilityElement()
                            .accessibilityLabel("Reorder \(bot.name)")
                            .accessibilityValue("\(index + 1) of \(ordered.count)")
                            .accessibilityAdjustableAction { direction in
                                switch direction {
                                case .increment: move(bot.id, by: 1)
                                case .decrement: move(bot.id, by: -1)
                                @unknown default: break
                                }
                            }
                            .help("Drag to reorder")
                    }
                    .modifier(
                        LiftedRow(
                            isLifted: drag?.id == bot.id,
                            scales: DockMotion.isEnabled(reduceMotion: reduceMotion),
                            offset: liftOffset(for: bot.id, at: index), style: style))
                }
            }
            .dockPadding(6)
            .background(DockScrollViewProbe(target: scrollTarget))
        }
        .frame(width: 300, height: min(CGFloat(bots.count + (showsHeader ? 1 : 0)) * 40 + 12, 360))
        .onGeometryChange(for: CGRect.self) {
            $0.frame(in: .global)
        } action: {
            viewport = $0
        }
        .background(style.background)
        .onDisappear { stopEdgeScroll() }
    }

    /// Row height (38) plus stack spacing (2).
    private static var rowPitch: CGFloat { 40 }

    /// Keeps the lifted row under the pointer while the list reflows around it.
    private func liftOffset(for id: String, at index: Int) -> CGFloat {
        guard let drag, drag.id == id else { return 0 }
        return dragDisplacement - CGFloat(index - drag.start) * Self.rowPitch
    }

    private func reorderGesture(for id: String, at index: Int) -> some Gesture {
        // Distance 0 lifts the row as soon as the handle is held. Global space: the
        // handle moves with its row, so local translation would oscillate.
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                if drag?.id != id {
                    NSCursor.closedHand.set()
                    let clip = scrollTarget.scrollView?.contentView
                    dragStartOriginY = clip?.bounds.minY ?? 0
                    dragIsFlipped = clip?.isFlipped ?? true
                    withAnimation(liftAnimation) { drag = (id, index, index, 0) }
                }
                guard drag != nil else { return }
                drag?.translation = value.translation.height
                pointerY = value.location.y
                updateOrder()
                updateEdgeScroll()
            }
            .onEnded { _ in
                endDrag()
            }
    }

    /// Pointer travel plus the travel the list made under a stationary pointer.
    private var dragDisplacement: CGFloat {
        guard let drag else { return 0 }
        return DockEdgeAutoscroll.displacement(
            translation: drag.translation, startOrigin: dragStartOriginY,
            origin: scrollTarget.scrollView?.contentView.bounds.minY ?? dragStartOriginY,
            isFlipped: dragIsFlipped)
    }

    /// Lands the dragged row on the slot the pointer and the list's own travel point at.
    private func updateOrder() {
        guard let state = drag else { return }
        let target = DockProfilePickerReorder.target(
            start: state.start, translation: dragDisplacement, pitch: Self.rowPitch, count: bots.count)
        guard target != state.slot else { return }
        let ordered = order.ordered(bots)
        guard ordered.indices.contains(target), let current = ordered.firstIndex(where: { $0.id == state.id })
        else { return }
        drag?.slot = target
        guard target != current else { return }
        withAnimation(DockMotion.animation(reduceMotion: reduceMotion, duration: 0.16)) {
            order.move(state.id, relativeTo: ordered[target].id, after: target > current, in: bots)
        }
    }

    /// Scrolls the list while the pointer is held in an edge band. One step at a time, so the
    /// slot update always sees the rows the scroll revealed.
    private func updateEdgeScroll() {
        guard drag != nil, scrollTarget.scrollView != nil,
            DockEdgeAutoscroll.direction(pointerY: pointerY, viewport: viewport) != nil
        else { return stopEdgeScroll() }
        guard edgeScroll == nil else { return }
        edgeScroll = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(33))
                guard !Task.isCancelled else { return }
                scrollEdgeStep()
            }
        }
    }

    private func scrollEdgeStep() {
        guard let scrollView = scrollTarget.scrollView, drag != nil,
            let direction = DockEdgeAutoscroll.direction(pointerY: pointerY, viewport: viewport)
        else { return stopEdgeScroll() }
        let clip = scrollView.contentView
        let next = DockEdgeAutoscroll.origin(
            from: clip.bounds.minY, direction: direction, clip: clip.bounds,
            documentHeight: scrollView.documentView?.frame.height ?? 0, isFlipped: clip.isFlipped)
        guard next != clip.bounds.minY else { return stopEdgeScroll() }
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: next))
        scrollView.reflectScrolledClipView(clip)
        updateOrder()
    }

    /// Ends the drag and its edge scroll once, however the drag finishes.
    private func endDrag() {
        stopEdgeScroll()
        if drag != nil { NSCursor.openHand.set() }
        withAnimation(liftAnimation) { drag = nil }
    }

    private func stopEdgeScroll() {
        edgeScroll?.cancel()
        edgeScroll = nil
    }

    private var liftAnimation: Animation? {
        DockMotion.isEnabled(reduceMotion: reduceMotion) ? .smooth(duration: 0.18) : nil
    }

    private func move(_ id: String, by offset: Int) {
        if reduceMotion {
            order.move(id, by: offset, in: bots)
        } else {
            withAnimation(.dockEase(duration: 0.2)) { order.move(id, by: offset, in: bots) }
        }
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
        bots: [BotSummary], order: DockProfilePickerOrder, style: DockThemePalette,
        @ViewBuilder row: @escaping (BotSummary) -> Row
    ) {
        self.init(bots: bots, order: order, style: style, header: { EmptyView() }, row: row)
    }
}
