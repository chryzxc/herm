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
    @GestureState private var gestureSample: DragSample?
    @State private var drag: DockProfilePickerDrag?
    @State private var scrollTarget = DockScrollTarget()
    /// The scroll view's frame in the same space as the drag, and the pointer inside it.
    @State private var viewport: CGRect = .zero
    @State private var pointer: CGPoint = .zero
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
            .background(DockScrollViewProbe(target: scrollTarget, onDetach: clipDidDetach))
        }
        .frame(width: 300, height: min(CGFloat(bots.count + (showsHeader ? 1 : 0)) * 40 + 12, 360))
        .onGeometryChange(for: CGRect.self) {
            $0.frame(in: .global)
        } action: {
            viewport = $0
        }
        .background(style.background)
        .onChange(of: gestureSample) { previous, sample in
            // SwiftUI resets gesture state on both release and cancellation.
            if let previous, previous.token != sample?.token { endDrag(previous.token) }
            if let sample { updateDrag(sample, isNew: sample.token != previous?.token) }
        }
        .onDisappear {
            if let token = drag?.token { endDrag(token) }
        }
    }

    /// Row height (38) plus stack spacing (2).
    private static var rowPitch: CGFloat { 40 }

    /// Keeps the lifted row under the pointer while the list reflows around it.
    private func liftOffset(for id: String, at index: Int) -> CGFloat {
        guard let drag, drag.id == id else { return 0 }
        return drag.liftOffset(at: index, pitch: Self.rowPitch)
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
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .updating($gestureSample) { value, sample, _ in
                sample = DragSample(
                    token: sample?.token ?? UUID(), id: id, start: sample?.start ?? index,
                    location: value.location, translation: value.translation.height)
            }
    }

    private func updateDrag(_ sample: DragSample, isNew: Bool) {
        guard let clip = scrollTarget.scrollView?.contentView else { return }
        if isNew {
            NSCursor.closedHand.set()
            withAnimation(liftAnimation) {
                drag = DockProfilePickerDrag(
                    token: sample.token, attachment: scrollTarget.attachment, id: sample.id,
                    start: sample.start, slot: sample.start, startOrigin: clip.bounds.minY)
            }
        }
        guard drag?.isCurrent(token: sample.token, attachment: scrollTarget.attachment) == true else { return }
        drag?.translation = sample.translation
        drag?.trackClip(origin: clip.bounds.minY, isFlipped: clip.isFlipped)
        pointer = sample.location
        updateOrder()
        updateEdgeScroll()
    }

    /// Lands the dragged row on the slot the pointer and the list's own travel point at.
    private func updateOrder() {
        guard let state = drag else { return }
        let target = state.target(pitch: Self.rowPitch, count: bots.count)
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
        guard let token = drag?.token,
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
    let attachment: UUID
    let id: String
    let start: Int
    var slot: Int
    let startOrigin: CGFloat
    var translation: CGFloat = 0
    var scrollTravel: CGFloat = 0

    func isCurrent(token: UUID, attachment: UUID) -> Bool {
        self.token == token && self.attachment == attachment
    }

    mutating func trackClip(origin: CGFloat, isFlipped: Bool) {
        scrollTravel = DockEdgeAutoscroll.travel(from: startOrigin, to: origin, isFlipped: isFlipped)
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
        bots: [BotSummary], order: DockProfilePickerOrder, style: DockThemePalette,
        @ViewBuilder row: @escaping (BotSummary) -> Row
    ) {
        self.init(bots: bots, order: order, style: style, header: { EmptyView() }, row: row)
    }
}
