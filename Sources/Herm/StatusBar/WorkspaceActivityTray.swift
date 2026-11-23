import SwiftUI

/// A short glance at workspace activity. The full Activity page owns the detail.
struct WorkspaceActivityTray: View {
    let preview: StatusBarLayout.Preview
    @ObservedObject var state: EdgeNotchState
    let perform: (StatusBarEntry.Action) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                DockIcon(preview.icon, size: 14, color: .dockSecondaryText).accessibilityHidden(true)
                Text(preview.title).dockFont(.rowTitle).accessibilityAddTraits(.isHeader)
            }
            .dockPadding(.horizontal, 16)
            .dockPadding(.vertical, 12)

            Color.dockBorder.frame(height: DockLayout.hairline)

            VStack(alignment: .leading, spacing: 8) {
                Text(preview.headline).dockFont(.body, weight: .medium)
                if let detail = preview.detail {
                    Text(detail).dockFont(.metadata).foregroundStyle(Color.dockSecondaryText)
                        .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(preview.rows) { row in
                    previewRow(row)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .dockPadding(.horizontal, 16)
            .dockPadding(.vertical, 12)

            if preview.footerAction != .none {
                Color.dockBorder.frame(height: DockLayout.hairline)
                Button {
                    perform(preview.footerAction)
                } label: {
                    HStack(spacing: 5) {
                        Text(preview.footerTitle)
                        DockIcon(.arrowRight, size: 11).accessibilityHidden(true)
                    }
                }
                .buttonStyle(.dockLink)
                .dockPadding(.horizontal, 16)
                .dockPadding(.vertical, 10)
            }
        }
        .dockButtonSize(.compact)
        .frame(width: 344)
        .foregroundStyle(Color.dockPrimaryText)
    }

    @ViewBuilder private func previewRow(_ row: StatusBarLayout.Preview.Row) -> some View {
        let label = HStack(alignment: .top, spacing: 8) {
            previewIcon(row)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title).dockFont(.rowTitle).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if !row.status.isEmpty {
                    Text(row.status).dockFont(.metadata).lineLimit(1)
                        .foregroundStyle(Color.dockSecondaryText)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if row.action != .none {
                DockIcon(.caretRight, size: 10, color: .dockSecondaryText)
                    .frame(height: 16)
                    .accessibilityHidden(true)
            }
        }
        if row.action == .none {
            label.accessibilityElement(children: .combine)
        } else {
            Button {
                perform(row.action)
            } label: {
                label.contentShape(Rectangle())
            }
            .buttonStyle(.dockHover)
            .help("Open \(row.title)")
        }
    }

    @ViewBuilder private func previewIcon(_ row: StatusBarLayout.Preview.Row) -> some View {
        if let bot = bot(for: row) {
            BotAvatarView(bot: bot, imageData: state.avatarImages[bot.id], size: 20, orbits: false, live: false)
                .accessibilityLabel(bot.name)
        } else {
            DockIcon(row.icon, size: 13, color: .dockSecondaryText)
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)
        }
    }

    private func bot(for row: StatusBarLayout.Preview.Row) -> BotSummary? {
        if let id = row.botID ?? row.task?.botProfileID {
            return state.bots.first { $0.id == id }
        }
        return row.task?.bot(in: state.bots)
    }
}
