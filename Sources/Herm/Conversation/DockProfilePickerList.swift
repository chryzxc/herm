import AppKit
import SwiftUI

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
                            .gesture(reorderGesture(for: bot.id, at: index, count: ordered.count))
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
        }
        .frame(width: 300, height: min(CGFloat(bots.count + (showsHeader ? 1 : 0)) * 40 + 12, 360))
        .background(style.background)
    }

    /// Row height (38) plus stack spacing (2).
    private static var rowPitch: CGFloat { 40 }

    /// Keeps the lifted row under the pointer while the list reflows around it.
    private func liftOffset(for id: String, at index: Int) -> CGFloat {
        guard let drag, drag.id == id else { return 0 }
        return drag.translation - CGFloat(index - drag.start) * Self.rowPitch
    }

    private func reorderGesture(for id: String, at index: Int, count: Int) -> some Gesture {
        // Distance 0 lifts the row as soon as the handle is held. Global space: the
        // handle moves with its row, so local translation would oscillate.
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                if drag?.id != id {
                    NSCursor.closedHand.set()
                    withAnimation(liftAnimation) { drag = (id, index, index, 0) }
                }
                guard let start = drag?.start else { return }
                drag?.translation = value.translation.height
                let target = DockProfilePickerReorder.target(
                    start: start, translation: value.translation.height, pitch: Self.rowPitch, count: count)
                guard target != drag?.slot else { return }
                let ordered = order.ordered(bots)
                guard ordered.indices.contains(target), let current = ordered.firstIndex(where: { $0.id == id }) else {
                    return
                }
                drag?.slot = target
                guard target != current else { return }
                withAnimation(DockMotion.animation(reduceMotion: reduceMotion, duration: 0.16)) {
                    order.move(id, relativeTo: ordered[target].id, after: target > current, in: bots)
                }
            }
            .onEnded { _ in
                withAnimation(liftAnimation) { drag = nil }
                NSCursor.openHand.set()
            }
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
