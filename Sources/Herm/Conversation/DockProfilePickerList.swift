import SwiftUI
import UniformTypeIdentifiers

private let profileDragType = UTType(exportedAs: "io.github.chryzxc.Herm.profile-picker-drag", conformingTo: .data)

struct DockProfilePickerList<Header: View, Row: View>: View {
    let bots: [BotSummary]
    @ObservedObject var order: DockProfilePickerOrder
    let style: DockThemePalette
    /// A fixed row above the reorderable bots, such as "All profiles".
    var showsHeader = false
    @ViewBuilder var header: () -> Header
    @ViewBuilder let row: (BotSummary) -> Row
    @State private var draggingID: String?
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
                            .modifier(DockDragCursor(isEnabled: true, isDragging: false))
                            .onDrag {
                                draggingID = bot.id
                                let provider = NSItemProvider()
                                provider.registerDataRepresentation(
                                    forTypeIdentifier: profileDragType.identifier, visibility: .ownProcess
                                ) {
                                    completion in
                                    completion(Data(bot.id.utf8), nil)
                                    return nil
                                }
                                return provider
                            }
                            .focusable()
                            .onMoveCommand { direction in
                                switch direction {
                                case .up: move(bot.id, by: -1)
                                case .down: move(bot.id, by: 1)
                                default: break
                                }
                            }
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
                            .help("Drag to reorder; use arrow keys when focused")
                    }
                    .onDrop(
                        of: [profileDragType],
                        delegate: ProfilePickerDropDelegate(
                            targetID: bot.id, draggingID: $draggingID, order: order, bots: bots,
                            reduceMotion: reduceMotion))
                }
            }
            .dockPadding(6)
        }
        .frame(width: 300, height: min(CGFloat(bots.count + (showsHeader ? 1 : 0)) * 40 + 12, 360))
        .background(style.background)
    }

    private func move(_ id: String, by offset: Int) {
        if reduceMotion {
            order.move(id, by: offset, in: bots)
        } else {
            withAnimation(.dockEase(duration: 0.2)) { order.move(id, by: offset, in: bots) }
        }
    }
}

private struct ProfilePickerDropDelegate: DropDelegate {
    let targetID: String
    @Binding var draggingID: String?
    let order: DockProfilePickerOrder
    let bots: [BotSummary]
    let reduceMotion: Bool

    func validateDrop(info: DropInfo) -> Bool { draggingID != nil }

    func dropEntered(info: DropInfo) {
        guard let draggingID, draggingID != targetID else { return }
        let ids = order.ordered(bots).map(\.id)
        guard let source = ids.firstIndex(of: draggingID), let target = ids.firstIndex(of: targetID) else { return }
        let move = { order.move(draggingID, relativeTo: targetID, after: source < target, in: bots) }
        if reduceMotion { move() } else { withAnimation(.dockEase(duration: 0.2), move) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .copy) }
    func performDrop(info: DropInfo) -> Bool {
        draggingID = nil
        return true
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
