import Charts
import SwiftUI

struct RichNativeBlockView: View {
    let block: RichBlock
    let surface: RichSurface
    @ObservedObject var state: RichArtifactPresentationState

    private var blockID: String { block.id ?? block.type.rawValue }
    private var selectionID: String { RichSelectionIdentity.block(blockID) }
    private var selected: String { state.snapshot.selected[selectionID] ?? "" }

    var body: some View {
        Group {
            switch block.payload {
            case .command(let command): RichCommandView(command: command)
            case .code(let code): RichCodeView(code: code)
            case .findings(let findings): RichFindingsView(findings: findings)
            case .workflow(let workflow): RichWorkflowView(workflow: workflow)
            case .metrics(let metrics): metricsView(metrics)
            case .comparison(let comparison): comparisonView(comparison)
            case .checklist(let list): checklistView(list)
            case .timeline(let list): timelineView(list)
            case .graph(let graph):
                RichGraphView(
                    graph: graph, selection: state.selection(selectionID),
                    edgeSelection: state.selection(RichSelectionIdentity.edge(blockID))
                )
            case .tree(let tree): RichTreeView(tree: tree, blockID: blockID, state: state)
            case .imageComparison(let images): RichImageComparisonView(images: images, blockID: blockID, state: state)
            case .table(let table):
                if let dataset = surface.datasets?.first(where: { $0.id == table.dataset }) {
                    RichDatasetTableView(dataset: dataset, blockID: blockID, state: state)
                }
            case .chart(let chart):
                if let dataset = surface.datasets?.first(where: { $0.id == chart.dataset }) {
                    RichDatasetChartView(dataset: dataset, configuration: chart, state: state)
                }
            case .section, .none: EmptyView()
            case .record(let target): RichConnectedRecordView(target: target)
            }
        }
        .dockFont(.body)
        .foregroundStyle(Color.dockPrimaryText)
    }

    private func metricsView(_ metrics: RichMetrics) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), alignment: .leading)], alignment: .leading, spacing: 12) {
            ForEach(metrics.items) { metric in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Circle().fill(DockAccentColor.identity(for: metric.id).fill).frame(width: 6, height: 6)
                        Text(metric.label).foregroundStyle(Color.dockSecondaryText)
                    }
                    Text([metric.value, metric.unit].compactMap { $0 }.joined(separator: " "))
                        .dockFont(.metric, weight: .semibold, design: .rounded).monospacedDigit()
                        .textSelection(.enabled)
                    if let comparison = metric.comparison { Text(comparison).foregroundStyle(Color.dockSecondaryText) }
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .dockCard(padding: 12)
            }
        }
    }

    private func comparisonView(_ comparison: RichComparison) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), alignment: .top)], alignment: .leading, spacing: 12) {
            ForEach(comparison.options) { option in
                VStack(alignment: .leading, spacing: 6) {
                    Button {
                        state.snapshot.selected[selectionID] = option.id
                    } label: {
                        HStack {
                            Text(option.title).multilineTextAlignment(.leading)
                            Spacer(minLength: 8)
                            Image(systemName: selected == option.id ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(Color.dockAccent).accessibilityHidden(true)
                        }
                    }.buttonStyle(
                        .dockSecondary)
                    ForEach(Array(zip(comparison.criteria, option.values).enumerated()), id: \.offset) { _, pair in
                        HStack(alignment: .top) {
                            Text(pair.0).foregroundStyle(Color.dockSecondaryText)
                            Spacer(minLength: 12)
                            Text(pair.1).multilineTextAlignment(.trailing)
                        }
                    }
                    if selected == option.id, let detail = option.detail { Text(detail).textSelection(.enabled) }
                }.dockPadding(12).dockCard(padding: 0)
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(selected == option.id ? Color.dockAccent : .clear, lineWidth: 1.5)
                            .allowsHitTesting(false)
                    }
                    .accessibilityAddTraits(selected == option.id ? .isSelected : [])
            }
        }
    }

    private func checklistView(_ list: RichChoiceList) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            let checked = list.items.filter { state.snapshot.checked.contains(blockID + ":" + $0.id) }.count
            HStack {
                Text("Selected").foregroundStyle(Color.dockSecondaryText)
                Spacer()
                Text("\(checked) of \(list.items.count)").monospacedDigit()
            }
            ProgressView(value: Double(checked), total: Double(list.items.count)).tint(Color.dockAccent)
                .accessibilityLabel("Selected items")
            ForEach(list.items) { item in
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(item.title, isOn: state.checked(blockID + ":" + item.id)).toggleStyle(.dockCheckbox)
                    if let detail = item.detail {
                        Text(detail).foregroundStyle(Color.dockSecondaryText).dockPadding(.leading, 20)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    private func timelineView(_ list: RichChoiceList) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(list.items.enumerated()), id: \.element.id) { index, item in
                HStack(alignment: .top, spacing: 12) {
                    VStack(spacing: 4) {
                        Circle().fill(selected == item.id ? Color.dockAccent : DockAccentColor.teal.fill)
                            .frame(width: 8, height: 8)
                        if index < list.items.count - 1 {
                            Rectangle().fill(Color.dockBorderLight).frame(width: 1, height: 20)
                        }
                    }.frame(width: 8).accessibilityHidden(true)
                    Text(item.date ?? String(index + 1)).foregroundStyle(Color.dockMetadataText)
                        .monospacedDigit().frame(width: 76, alignment: .leading)
                    VStack(alignment: .leading, spacing: 4) {
                        Button(item.title) { state.snapshot.selected[selectionID] = item.id }.buttonStyle(.dockLink)
                        if selected == item.id {
                            if let detail = item.detail { Text(detail).textSelection(.enabled) }
                            if let dependencies = item.dependencies, !dependencies.isEmpty {
                                Text(
                                    "After: "
                                        + dependencies.compactMap { id in list.items.first { $0.id == id }?.title }
                                        .joined(separator: ", ")
                                )
                                .foregroundStyle(Color.dockSecondaryText)
                            }
                        }
                    }
                }.dockPadding(.vertical, 8)
                Divider().overlay(Color.dockBorderLight)
            }
        }
    }
}

struct RichDatasetTableView: View {
    let dataset: RichDataset
    let blockID: String
    @ObservedObject var state: RichArtifactPresentationState
    private var rows: [RichDataset.Row] {
        dataset.displayedRows(
            query: state.snapshot.queries[blockID] ?? "",
            column: state.snapshot.sortColumns[blockID], descending: state.snapshot.descending.contains(blockID))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if dataset.rows.count > 10 {
                TextField("Filter rows", text: state.query(blockID)).textFieldStyle(.dockGlass)
            }
            ScrollView([.horizontal, .vertical]) {
                Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                    GridRow {
                        ForEach(Array(dataset.columns.enumerated()), id: \.element.id) { index, column in
                            Button(column.title + (column.unit.map { " (\($0))" } ?? "")) {
                                if state.snapshot.sortColumns[blockID] == index {
                                    if state.snapshot.descending.contains(blockID) {
                                        state.snapshot.descending.remove(blockID)
                                    } else {
                                        state.snapshot.descending.insert(blockID)
                                    }
                                } else {
                                    state.snapshot.sortColumns[blockID] = index
                                }
                            }.buttonStyle(.dockCompact)
                        }
                    }
                    ForEach(rows) { row in
                        GridRow {
                            ForEach(Array(row.values.enumerated()), id: \.offset) { index, value in
                                Button(value) {
                                    state.snapshot.selected[RichSelectionIdentity.dataset(dataset.id)] = row.id
                                }
                                .buttonStyle(.dockHover)
                                .frame(
                                    maxWidth: .infinity,
                                    alignment: dataset.columns[index].type == .number ? .trailing : .leading
                                )
                                .dockPadding(.vertical, 4)
                                .background(
                                    state.snapshot.selected[RichSelectionIdentity.dataset(dataset.id)] == row.id
                                        ? Color.dockControlSurface : Color.clear
                                )
                                .accessibilityLabel("\(dataset.columns[index].title): \(value). Select row.")
                            }
                        }
                    }
                }.dockPadding(4).dockPadding([.bottom, .trailing], 16)
            }.frame(height: min(320, CGFloat(rows.count + 1) * 34 + 32))
                .dockPadding(.bottom, 4)
            if state.snapshot.sortColumns[blockID] != nil {
                Button("Restore source order") {
                    state.snapshot.sortColumns.removeValue(forKey: blockID)
                    state.snapshot.descending.remove(blockID)
                }.buttonStyle(.dockCompact)
            }
        }
    }
}

private struct RichGraphView: View {
    let graph: RichGraph
    @Binding var selection: String
    @Binding var edgeSelection: String
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView([.horizontal, .vertical]) {
                let positions = RichGraphLayout.positions(graph.nodes.map(\.id))
                ZStack(alignment: .topLeading) {
                    Canvas { context, _ in
                        for edge in graph.edges {
                            guard let source = positions[edge.source], let target = positions[edge.target] else {
                                continue
                            }
                            let (start, end) = RichGraphLayout.endpoints(from: source, to: target)
                            var path = Path()
                            path.move(to: start)
                            if edge.source == edge.target {
                                path.addCurve(
                                    to: end, control1: CGPoint(x: start.x - 40, y: start.y - 65),
                                    control2: CGPoint(x: end.x + 40, y: end.y - 65))
                            } else {
                                path.addLine(to: end)
                            }
                            context.stroke(
                                path, with: .color(Color.dockBorder),
                                style: StrokeStyle(lineWidth: 1, dash: edge.style == .dashed ? [5, 4] : []))
                            let angle = atan2(end.y - start.y, end.x - start.x)
                            var arrow = Path()
                            arrow.move(to: end)
                            arrow.addLine(to: CGPoint(x: end.x - 8 * cos(angle - 0.4), y: end.y - 8 * sin(angle - 0.4)))
                            arrow.move(to: end)
                            arrow.addLine(to: CGPoint(x: end.x - 8 * cos(angle + 0.4), y: end.y - 8 * sin(angle + 0.4)))
                            context.stroke(arrow, with: .color(Color.dockSecondaryText), lineWidth: 1)
                        }
                    }
                    ForEach(graph.nodes) { node in
                        Button(node.title) {
                            selection = node.id
                            edgeSelection = ""
                        }.buttonStyle(.dockSecondary)
                            .lineLimit(2).frame(width: 140, height: 44)
                            .overlay {
                                if let status = node.status {
                                    RoundedRectangle(cornerRadius: 8).strokeBorder(status.color, lineWidth: 1.5)
                                        .allowsHitTesting(false)
                                }
                            }
                            .background {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(selection == node.id ? Color.dockAccent.opacity(0.12) : .clear)
                            }
                            .position(positions[node.id] ?? .zero)
                            .accessibilityValue(node.status?.rawValue.capitalized ?? "")
                            .accessibilityAddTraits(selection == node.id ? .isSelected : [])
                    }
                }.frame(width: 540, height: max(100, CGFloat((graph.nodes.count + 2) / 3) * 100))
                    .dockPadding([.bottom, .trailing], 20)
            }.frame(height: min(400, max(100, CGFloat((graph.nodes.count + 2) / 3) * 100) + 40))
            if let node = graph.nodes.first(where: { $0.id == selection }) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let status = node.status {
                        Text(status.rawValue.capitalized).foregroundStyle(status.color).fixedSize()
                    }
                    Text(node.detail ?? node.title)
                }.textSelection(.enabled)
            }
            if let edge = graph.edges.enumerated().first(where: { edgeSelection == String($0.offset) })?.element {
                Text("\(title(edge.source)) → \(title(edge.target))\(edge.label.map { " · " + $0 } ?? "")")
                    .textSelection(.enabled)
            }
            DisclosureGroup("Connections (\(graph.edges.count))") {
                ForEach(Array(graph.edges.enumerated()), id: \.offset) { index, edge in
                    Button("\(title(edge.source)) → \(title(edge.target))\(edge.label.map { " · " + $0 } ?? "")") {
                        selection = ""
                        edgeSelection = String(index)
                    }.buttonStyle(.dockLink)
                        .accessibilityAddTraits(edgeSelection == String(index) ? .isSelected : [])
                }
            }
        }
    }
    private func title(_ id: String) -> String { graph.nodes.first { $0.id == id }?.title ?? id }
}

private struct RichTreeView: View {
    let tree: RichTree
    let blockID: String
    @ObservedObject var state: RichArtifactPresentationState
    var body: some View { children(nil) }
    private func children(_ parent: String?) -> AnyView {
        AnyView(
            VStack(alignment: .leading, spacing: 8) {
                ForEach(tree.items.filter { $0.parent == parent }) { item in
                    if tree.items.contains(where: { $0.parent == item.id }) {
                        DisclosureGroup(
                            item.title + (item.value.map { ": " + $0 } ?? ""),
                            isExpanded: state.expanded(blockID + ":" + item.id)
                        ) {
                            children(item.id).dockPadding(.leading, 12)
                        }
                        .disclosureGroupStyle(DockDisclosureGroupStyle())
                    } else {
                        Text(item.title + (item.value.map { ": " + $0 } ?? "")).textSelection(.enabled)
                    }
                }
            })
    }
}

private struct RichImageComparisonView: View {
    let images: RichImageComparison
    let blockID: String
    @ObservedObject var state: RichArtifactPresentationState
    private var fraction: Double { min(1, max(0, state.snapshot.numbers[blockID + ":fraction"] ?? 0.5)) }
    private var zoom: Double { min(4, max(1, state.snapshot.numbers[blockID + ":zoom"] ?? 1)) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .leading) {
                    image(images.before)
                    image(images.after).mask(alignment: .leading) { Rectangle().frame(width: 480 * fraction) }
                }.frame(width: 480, height: 300).scaleEffect(zoom, anchor: .topLeading)
                    .frame(width: 480 * zoom, height: 300 * zoom, alignment: .topLeading)
                    .dockPadding([.bottom, .trailing], 20)
            }.frame(height: 340)
                .dockPadding(.bottom, 4)
            Text("\(images.before.title) / \(images.after.title)").foregroundStyle(Color.dockSecondaryText)
            DockSlider(value: state.number(blockID + ":fraction", default: 0.5), range: 0...1)
                .accessibilityLabel("Comparison position")
            DockSlider(value: state.number(blockID + ":zoom", default: 1), range: 1...4).accessibilityLabel("Zoom")
        }
    }
    @ViewBuilder private func image(_ item: RichItem) -> some View {
        if let url = RichResourcePolicy.url(item.url, image: true) {
            if url.scheme == "data" {
                AttachmentThumbnailView(url: url).scaledToFit().frame(width: 480, height: 300)
            } else {
                Link("Open \(item.title)", destination: url).buttonStyle(.dockLink)
            }
        }
    }
}

enum RichGraphLayout {
    static func endpoints(from start: CGPoint, to end: CGPoint) -> (CGPoint, CGPoint) {
        guard start != end else {
            return (CGPoint(x: start.x - 25, y: start.y - 24), CGPoint(x: end.x + 25, y: end.y - 24))
        }
        let dx = end.x - start.x
        let dy = end.y - start.y
        let fraction = min(dx == 0 ? .infinity : 76 / abs(dx), dy == 0 ? .infinity : 28 / abs(dy))
        return (
            CGPoint(x: start.x + dx * fraction, y: start.y + dy * fraction),
            CGPoint(x: end.x - dx * fraction, y: end.y - dy * fraction)
        )
    }
    static func positions(_ ids: [String]) -> [String: CGPoint] {
        Dictionary(
            ids.enumerated().map { index, id in
                (id, CGPoint(x: 90 + (index % 3) * 180, y: 50 + (index / 3) * 100))
            }, uniquingKeysWith: { first, _ in first })
    }
}
