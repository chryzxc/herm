import SwiftUI

struct DockProfilePickerList<Header: View, Row: View>: View {
    let bots: [BotSummary]
    @ObservedObject var order: DockProfilePickerOrder
    let style: DockThemePalette
    /// A fixed row above the reorderable bots, such as "All profiles".
    var showsHeader = false
    @ViewBuilder var header: () -> Header
    @ViewBuilder let row: (BotSummary) -> Row

    var body: some View {
        let ordered = order.ordered(bots)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if showsHeader { header() }
                ForEach(Array(ordered.enumerated()), id: \.element.id) { index, bot in
                    HStack(spacing: 0) {
                        row(bot)
                        DockMenu {
                            Button("Move up") { order.move(bot.id, by: -1, in: bots) }
                                .disabled(index == 0)
                            Button("Move down") { order.move(bot.id, by: 1, in: bots) }
                                .disabled(index == ordered.count - 1)
                        } label: {
                            Image(systemName: "ellipsis").frame(width: 28, height: 38)
                        }
                        .fixedSize()
                        .accessibilityLabel("Reorder \(bot.name)")
                        .help("Reorder \(bot.name)")
                    }
                }
            }
            .dockPadding(6)
        }
        .frame(width: 300, height: min(CGFloat(bots.count + (showsHeader ? 1 : 0)) * 40 + 12, 360))
        .background(style.background)
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
