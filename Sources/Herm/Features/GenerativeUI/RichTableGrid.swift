import SwiftUI

struct RichDatasetTableView: View {
    let dataset: RichDataset
    let blockID: String
    @ObservedObject var state: RichArtifactPresentationState

    var body: some View {
        RichTableGrid(
            dataset: dataset, query: state.query(blockID),
            sortColumn: Binding(
                get: { state.snapshot.sortColumns[blockID] }, set: { state.snapshot.sortColumns[blockID] = $0 }),
            descending: Binding(
                get: { state.snapshot.descending.contains(blockID) },
                set: {
                    if $0 {
                        state.snapshot.descending.insert(blockID)
                    } else {
                        state.snapshot.descending.remove(blockID)
                    }
                }),
            selection: state.selection(RichSelectionIdentity.dataset(dataset.id)))
    }
}

struct RichMarkdownTableView: View {
    let table: RichMarkdownTable
    @State private var query = ""
    @State private var sortColumn: Int?
    @State private var descending = false

    var body: some View {
        RichTableGrid(
            dataset: table.dataset, query: $query, sortColumn: $sortColumn, descending: $descending,
            markdown: table)
    }
}

private struct RichTableGrid: View {
    let dataset: RichDataset
    @Binding var query: String
    @Binding var sortColumn: Int?
    @Binding var descending: Bool
    var selection: Binding<String>?
    var markdown: RichMarkdownTable?
    @Environment(\.markdownOpenURL) private var openLink
    /// Voice previews are read-only: no filter, sorting, selection or nested scrolling.
    @Environment(\.richGlance) private var glance
    @Environment(\.richVoicePosition) private var voicePosition
    @State private var projection = RowProjection()

    @MainActor private final class RowProjection {
        private struct Input: Equatable {
            let dataset: RichDataset
            let query: String
            let sortColumn: Int?
            let descending: Bool
        }
        private var input: Input?
        private var rows: [RichDataset.Row] = []

        func rows(for dataset: RichDataset, query: String, sortColumn: Int?, descending: Bool) -> [RichDataset.Row] {
            let next = Input(dataset: dataset, query: query, sortColumn: sortColumn, descending: descending)
            if next != input {
                rows = dataset.displayedRows(query: query, column: sortColumn, descending: descending)
                input = next
            }
            return rows
        }
    }

    var body: some View {
        // Spoken row numbers always follow source order, independent of chat sorting and filters.
        let rows =
            glance
            ? dataset.rows
            : projection.rows(
                for: dataset, query: query, sortColumn: sortColumn, descending: descending)
        let page = RichVoicePreview.rows(on: voicePosition.page, total: rows.count)
        VStack(alignment: .leading, spacing: DockSpacing.control) {
            if dataset.rows.count > 10, !glance {
                DockSearchField(placeholder: "Filter rows", text: $query)
            }
            Group {
                if glance {
                    // The preview panel scrolls the whole reply, so the table never scrolls on its own.
                    table(Array(rows[page]), rowOffset: page.lowerBound)
                } else if dataset.rows.count > 10 {
                    largeTable(rows)
                } else {
                    ViewThatFits(in: .vertical) {
                        table(rows)
                        ScrollView(.vertical) { table(rows) }.frame(height: 320)
                    }
                    .frame(maxHeight: 320, alignment: .topLeading)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .dockWell(.sunken, role: .pane)
            HStack(spacing: DockSpacing.control) {
                Text(
                    glance && rows.count > RichVoicePreview.rowsPerPage
                        ? "Rows \(page.lowerBound + 1)–\(page.upperBound) of \(rows.count)"
                        : query.isEmpty || glance
                            ? "\(rows.count) \(rows.count == 1 ? "row" : "rows")"
                            : "\(rows.count) of \(dataset.rows.count) rows"
                )
                .dockFont(.metadata).monospacedDigit().foregroundStyle(Color.dockSecondaryText)
                Spacer(minLength: DockSpacing.control)
                if sortColumn != nil, !glance {
                    Button("Restore source order") {
                        sortColumn = nil
                        descending = false
                    }.buttonStyle(.dockLink)
                }
            }
            .frame(minHeight: 20)
        }
        .dockFont(.body)
        .foregroundStyle(Color.dockPrimaryText)
        .environment(\.openURL, openLink)
    }

    private func largeTable(_ rows: [RichDataset.Row]) -> some View {
        GeometryReader { viewport in
            let columns = Array(dataset.columns.enumerated())
            let minimumWidths: [CGFloat] = columns.map { _, column in
                switch column.type {
                case .number: 84
                case .date: 120
                case .text: 132
                }
            }
            let padding = 2 * DockSpacing.group
            let spacing = CGFloat(max(0, columns.count - 1)) * DockSpacing.section
            let minimumWidth = minimumWidths.reduce(padding + spacing, +)
            let extra = max(0, viewport.size.width - minimumWidth)
            let wideColumn = expandingColumn
            let widths = minimumWidths.enumerated().map { index, width in width + (index == wideColumn ? extra : 0) }
            ScrollView(minimumWidth > viewport.size.width ? [.horizontal, .vertical] : .vertical) {
                LazyVStack(alignment: .leading, spacing: DockSpacing.control) {
                    HStack(alignment: .firstTextBaseline, spacing: DockSpacing.section) {
                        ForEach(columns, id: \.element.id) { index, column in
                            header(column, index: index)
                                .frame(width: widths[index], alignment: alignment(column, index: index))
                        }
                    }
                    Divider()
                    ForEach(rows) { row in
                        HStack(alignment: .firstTextBaseline, spacing: DockSpacing.section) {
                            ForEach(columns, id: \.element.id) { index, column in
                                cell(row, column: column, index: index)
                                    .frame(width: widths[index], alignment: alignment(column, index: index))
                            }
                        }
                    }
                    if rows.isEmpty && !query.isEmpty {
                        Text("No matching rows").foregroundStyle(Color.dockSecondaryText)
                    }
                }
                .padding(DockSpacing.group)
                .frame(width: max(minimumWidth, viewport.size.width), alignment: .leading)
            }
        }
        .frame(height: 320)
    }

    private func table(_ rows: [RichDataset.Row], rowOffset: Int? = nil) -> some View {
        // Give each column room for a short header before requiring horizontal scrolling.
        let count = CGFloat(dataset.columns.count)
        let ordinalWidth: CGFloat = rowOffset == nil ? 0 : 30
        let minimumWidth =
            count * 68 + (count - 1) * DockSpacing.section + 2 * DockSpacing.group + DockSpacing.control
            + ordinalWidth
        return ViewThatFits(in: .horizontal) {
            grid(rows, rowOffset: rowOffset).frame(
                minWidth: minimumWidth, idealWidth: minimumWidth, maxWidth: .infinity)
            ScrollView(.horizontal) { grid(rows, rowOffset: rowOffset).frame(width: minimumWidth) }
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func grid(_ rows: [RichDataset.Row], rowOffset: Int?) -> some View {
        Grid(
            alignment: .leadingFirstTextBaseline, horizontalSpacing: DockSpacing.section,
            verticalSpacing: DockSpacing.control
        ) {
            GridRow {
                if rowOffset != nil { Text("#").dockFont(.metadata).foregroundStyle(Color.dockSecondaryText) }
                ForEach(Array(dataset.columns.enumerated()), id: \.element.id) { index, column in
                    header(column, index: index)
                        .gridColumnAlignment(alignment(column, index: index).horizontal)
                }
            }
            Divider().gridCellUnsizedAxes(.horizontal)
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                let number = rowOffset.map { $0 + index }
                let focused = number != nil && number == voicePosition.row
                GridRow {
                    if let number {
                        Text("\(number + 1)")
                            .dockFont(.metadata, weight: focused ? .semibold : .regular)
                            .monospacedDigit()
                            .foregroundStyle(focused ? Color.dockAccent : Color.dockSecondaryText)
                            .accessibilityLabel("Row \(number + 1)")
                            .accessibilityAddTraits(focused ? .isSelected : [])
                    }
                    ForEach(Array(dataset.columns.enumerated()), id: \.element.id) { index, column in
                        cell(row, column: column, index: index)
                            .fontWeight(focused ? .semibold : nil)
                    }
                }
            }
            if rows.isEmpty && !query.isEmpty {
                Text("No matching rows").foregroundStyle(Color.dockSecondaryText)
            }
        }
        .dockPadding(DockSpacing.group)
        .dockPadding([.bottom, .trailing], DockSpacing.control)
    }

    // Let descriptive text use the available reading width while numbers and short labels hug their content.
    private var expandingColumn: Int { dataset.columns.lastIndex { $0.type == .text } ?? 0 }

    private func alignment(_ column: RichDataset.Column, index: Int) -> Alignment {
        switch markdown?.alignments[index] {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        case nil: column.type == .number ? .trailing : .leading
        }
    }

    @ViewBuilder private func header(_ column: RichDataset.Column, index: Int) -> some View {
        let sorted = sortColumn == index
        let label = column.title + (column.unit.map { " (\($0))" } ?? "")
        if glance {
            Text(label).dockFont(.body, weight: .semibold).multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: index == expandingColumn ? .infinity : nil, alignment: alignment(column, index: index))
        } else {
            sortButton(column, index: index, label: label, sorted: sorted)
        }
    }

    private func sortButton(_ column: RichDataset.Column, index: Int, label: String, sorted: Bool) -> some View {
        Button {
            descending = sorted && !descending
            sortColumn = index
        } label: {
            HStack(spacing: DockSpacing.micro) {
                Text(label).dockFont(.body, weight: .semibold).multilineTextAlignment(.leading)
                DockIcon(
                    sorted ? (descending ? .caretDown : .caretUp) : .caretUpDown,
                    size: 12, color: sorted ? .dockPrimaryText : .dockMetadataText)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: index == expandingColumn ? .infinity : nil, alignment: alignment(column, index: index))
        }
        .buttonStyle(.dockHover)
        .accessibilityLabel("Sort by \(label)")
        .accessibilityValue(sorted ? (descending ? "Descending" : "Ascending") : "Unsorted")
    }

    @ViewBuilder private func cell(_ row: RichDataset.Row, column: RichDataset.Column, index: Int) -> some View {
        let value = row.values[index]
        if let selection, !glance {
            let selected = selection.wrappedValue == row.id
            Button {
                selection.wrappedValue = row.id
            } label: {
                HStack(spacing: DockSpacing.tight) {
                    if index == 0 {
                        DockIcon(
                            selected ? .checkCircle : .circle, size: 12,
                            color: selected ? .dockAccent : .dockMetadataText)
                    }
                    Text(value).monospacedDigit()
                }
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: index == expandingColumn ? .infinity : nil, alignment: alignment(column, index: index))
                .multilineTextAlignment(column.type == .number ? .trailing : .leading)
            }
            .buttonStyle(.dockHover)
            .accessibilityLabel("\(column.title): \(value). Select row.")
            .accessibilityAddTraits(selected ? .isSelected : [])
        } else if let markdown, let original = Int(row.id) {
            Text(MarkdownMessageView.linkAffordances(in: markdown.cells[original][index]))
                .monospacedDigit().textSelection(.enabled)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: index == expandingColumn ? .infinity : nil, alignment: alignment(column, index: index))
                .accessibilityLabel("\(column.title): \(value)")
        } else {
            Text(value).monospacedDigit()
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: index == expandingColumn ? .infinity : nil, alignment: alignment(column, index: index))
        }
    }
}
