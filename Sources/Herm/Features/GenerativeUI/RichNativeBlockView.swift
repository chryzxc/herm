import Charts
import SwiftUI

struct RichNativeBlockView: View {
    let block: RichBlock
    let surface: RichSurface
    @ObservedObject var state: RichArtifactPresentationState

    private var blockID: String { block.id ?? block.type.rawValue }
    private var selectionID: String { RichSelectionIdentity.block(blockID) }
    private var selected: String { state.snapshot.selected[selectionID] ?? "" }
    @Environment(\.richGlance) private var glance
    @Environment(\.richVoicePosition) private var voicePosition

    var body: some View {
        Group {
            switch block.payload {
            case .command(let command): RichCommandView(command: command)
            case .callout(let callout): RichCalloutView(callout: callout)
            case .breakdown(let breakdown): RichBreakdownView(breakdown: breakdown)
            case .map(let map): RichMapView(place: map, interactive: !glance)
            case .faq(let questions):
                VStack(alignment: .leading, spacing: DockSpacing.control) {
                    ForEach(questions.items) { item in
                        DisclosureGroup(isExpanded: state.expanded(blockID + ":" + item.id)) {
                            MarkdownMessageView(markdown: item.value).equatable().dockPadding(
                                .vertical, DockSpacing.tight)
                        } label: {
                            Text(item.label).dockFont(.body, weight: .semibold).multilineTextAlignment(.leading)
                        }.disclosureGroupStyle(DockDisclosureGroupStyle())
                        if item.id != questions.items.last?.id { Divider() }
                    }
                }
            case .facts(let facts): RichFactsView(facts: facts)
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

    /// One quiet inset holding every value; tiles are separated by space, not boxes.
    private func metricsView(_ metrics: RichMetrics) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 128), spacing: 20, alignment: .topLeading)],
            alignment: .leading, spacing: 16
        ) {
            ForEach(metrics.items) { metric in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Circle().fill(DockAccentColor.identity(for: metric.id).fill).frame(width: 6, height: 6)
                            .accessibilityHidden(true)
                        Text(metric.label).dockFont(.metadata).foregroundStyle(Color.dockSecondaryText)
                            .lineLimit(2)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(metric.value).dockFont(.metric, weight: .semibold, design: .rounded)
                        if let unit = metric.unit {
                            Text(unit).dockFont(.rowTitle, weight: .medium).foregroundStyle(Color.dockSecondaryText)
                        }
                    }
                    .monospacedDigit()
                    .textSelection(.enabled)
                    if let comparison = metric.comparison {
                        Text(comparison).dockFont(.metadata).foregroundStyle(Color.dockMetadataText)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .accessibilityElement(children: .combine)
            }
        }
        .dockPadding(14)
        .dockWell(role: .pane)
    }

    /// Options as columns against shared criteria rows; the chosen column is tinted.
    private func comparisonView(_ comparison: RichComparison) -> some View {
        let selected =
            glance
            ? voicePosition.option.flatMap { index in
                comparison.options.indices.contains(index) ? comparison.options[index].id : nil
            } : self.selected
        let grid = Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                Color.clear.frame(width: 1, height: 1).gridCellUnsizedAxes(.vertical)
                ForEach(Array(comparison.options.enumerated()), id: \.element.id) { index, option in
                    comparisonHeader(option, number: index + 1, isSelected: selected == option.id)
                        .background(selected == option.id ? Color.dockAccent.opacity(0.08) : .clear)
                }
            }
            ForEach(Array(comparison.criteria.enumerated()), id: \.offset) { row, criterion in
                Divider().overlay(Color.dockBorderLight).gridCellUnsizedAxes(.horizontal)
                GridRow {
                    Text(criterion).foregroundStyle(Color.dockSecondaryText)
                        .dockPadding(.vertical, 8).dockPadding(.trailing, 12)
                    ForEach(comparison.options) { option in
                        Text(option.values.indices.contains(row) ? option.values[row] : "—")
                            .monospacedDigit()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .dockPadding(.vertical, 8).dockPadding(.horizontal, 10)
                            .background(selected == option.id ? Color.dockAccent.opacity(0.08) : .clear)
                    }
                }
            }
        }
        .textSelection(.enabled)
        return VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                grid.frame(maxWidth: .infinity, alignment: .leading)
                if glance {
                    compactComparison(comparison, selected: selected)
                } else {
                    ScrollView(.horizontal) { grid.fixedSize().dockPadding(.bottom, 12) }
                }
            }
            if let option = comparison.options.first(where: { $0.id == selected }), let detail = option.detail {
                Text(detail).foregroundStyle(Color.dockSecondaryText).textSelection(.enabled)
            }
        }
    }

    private func compactComparison(_ comparison: RichComparison, selected: String?) -> some View {
        let key = RichVoicePreview.BlockKey(
            surface: surface.id, index: surface.blocks?.firstIndex { $0.id == block.id } ?? 0)
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(comparison.options.enumerated()), id: \.element.id) { index, option in
                let isSelected = option.id == selected
                let anchor = RichVoicePreview.OptionAnchor(block: key, index: index)
                VStack(alignment: .leading, spacing: DockSpacing.micro) {
                    comparisonLabel(option, number: index + 1, isSelected: isSelected)
                    ForEach(Array(comparison.criteria.enumerated()), id: \.offset) { row, criterion in
                        HStack(alignment: .firstTextBaseline, spacing: DockSpacing.section) {
                            Text(criterion).foregroundStyle(Color.dockSecondaryText)
                            Spacer(minLength: DockSpacing.control)
                            Text(option.values.indices.contains(row) ? option.values[row] : "—")
                                .monospacedDigit().multilineTextAlignment(.trailing)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .dockPadding(.horizontal, DockSpacing.group)
                .dockPadding(.vertical, DockSpacing.control)
                .id(anchor)
                if option.id != comparison.options.last?.id {
                    Divider().overlay(Color.dockBorderLight).dockPadding(.horizontal, DockSpacing.group)
                }
            }
        }
        .dockWell(.sunken, role: .pane)
    }

    private func comparisonLabel(_ option: RichComparison.Option, number: Int, isSelected: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DockSpacing.tight) {
            if glance {
                Text("\(number)").dockFont(.metadata, weight: .semibold).monospacedDigit()
                    .foregroundStyle(Color.dockSecondaryText)
                    .accessibilityLabel("Option \(number)")
            }
            Text(option.title).fontWeight(.semibold).multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            if isSelected {
                DockIcon(.checkCircle, size: 13, weight: .fill, color: .dockAccent).accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder private func comparisonHeader(
        _ option: RichComparison.Option, number: Int, isSelected: Bool
    ) -> some View {
        let label = comparisonLabel(option, number: number, isSelected: isSelected)
            .dockPadding(.horizontal, 10).dockPadding(.vertical, 8)
        if glance {
            label
        } else {
            Button {
                state.snapshot.selected[selectionID] = isSelected ? nil : option.id
            } label: {
                label.contentShape(Rectangle())
            }
            .buttonStyle(.dockHover)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
    }

    private func checklistView(_ list: RichChoiceList) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            let checked = list.items.filter { state.snapshot.checked.contains(blockID + ":" + $0.id) }.count
            HStack(spacing: 10) {
                DockProgressBar(fraction: list.items.isEmpty ? 0 : Double(checked) / Double(list.items.count))
                    .accessibilityLabel("Selected items")
                Text("\(checked) of \(list.items.count) selected").dockFont(.metadata).monospacedDigit()
                    .foregroundStyle(Color.dockSecondaryText).fixedSize()
            }
            ForEach(list.items) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Toggle(item.title, isOn: state.checked(blockID + ":" + item.id)).toggleStyle(.dockCheckbox)
                    if let detail = item.detail {
                        Text(detail).dockFont(.metadata).foregroundStyle(Color.dockSecondaryText)
                            .dockPadding(.leading, 22).textSelection(.enabled)
                    }
                }
            }
        }
    }

    /// A continuous rail of dated steps; details stay visible, selection only tints the marker.
    private func timelineView(_ list: RichChoiceList) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(list.items.enumerated()), id: \.element.id) { index, item in
                let last = index == list.items.count - 1
                let row = HStack(alignment: .top, spacing: 12) {
                    VStack(spacing: 0) {
                        Circle()
                            .fill(selected == item.id ? Color.dockAccent : DockAccentColor.teal.fill)
                            .frame(width: 9, height: 9)
                            .dockPadding(.top, 4)
                        if !last {
                            Rectangle().fill(Color.dockBorder).frame(width: 1.5).frame(maxHeight: .infinity)
                                .dockPadding(.top, 3)
                        }
                    }
                    .frame(width: 10)
                    .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(item.title).fontWeight(.semibold).multilineTextAlignment(.leading)
                            Spacer(minLength: 8)
                            Text(item.date ?? "Step \(index + 1)").dockFont(.metadata).monospacedDigit()
                                .foregroundStyle(Color.dockMetadataText).fixedSize()
                        }
                        if let detail = item.detail {
                            Text(detail).foregroundStyle(Color.dockSecondaryText).multilineTextAlignment(.leading)
                        }
                        if let dependencies = item.dependencies, !dependencies.isEmpty {
                            Text(
                                "After "
                                    + dependencies.compactMap { id in list.items.first { $0.id == id }?.title }
                                    .joined(separator: ", ")
                            )
                            .dockFont(.metadata).foregroundStyle(Color.dockMetadataText)
                        }
                    }
                    .dockPadding(.bottom, last ? 0 : 14)
                }
                .fixedSize(horizontal: false, vertical: true)
                if glance {
                    row
                } else {
                    Button {
                        state.snapshot.selected[selectionID] = selected == item.id ? nil : item.id
                    } label: {
                        row.contentShape(Rectangle())
                    }
                    .buttonStyle(.dockHover)
                    .accessibilityAddTraits(selected == item.id ? .isSelected : [])
                }
            }
        }
    }
}

private struct RichGraphView: View {
    let graph: RichGraph
    @Binding var selection: String
    @Binding var edgeSelection: String
    @Environment(\.richGlance) private var glance
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
                        nodeLabel(node).lineLimit(2).frame(width: 140, height: 44)
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
            if !glance, !graph.edges.isEmpty { connections }
        }
    }
    @ViewBuilder private func nodeLabel(_ node: RichGraph.Node) -> some View {
        if glance {
            Text(node.title).dockFont(.body, weight: .medium).multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, maxHeight: .infinity).dockWell(.raised, role: .pane)
        } else {
            Button(node.title) {
                selection = node.id
                edgeSelection = ""
            }.buttonStyle(.dockSecondary)
        }
    }
    private var connections: some View {
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
    private func title(_ id: String) -> String { graph.nodes.first { $0.id == id }?.title ?? id }
}

private struct RichTreeView: View {
    let tree: RichTree
    let blockID: String
    @ObservedObject var state: RichArtifactPresentationState
    @Environment(\.richGlance) private var glance
    var body: some View { children(nil) }
    private func children(_ parent: String?) -> AnyView {
        AnyView(
            VStack(alignment: .leading, spacing: 8) {
                ForEach(tree.items.filter { $0.parent == parent }) { item in
                    if glance, tree.items.contains(where: { $0.parent == item.id }) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(item.title + (item.value.map { ": " + $0 } ?? "")).fontWeight(.semibold)
                            children(item.id).dockPadding(.leading, 12)
                        }
                    } else if tree.items.contains(where: { $0.parent == item.id }) {
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
    @Environment(\.richGlance) private var glance
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
            if !glance {
                DockSlider(value: state.number(blockID + ":fraction", default: 0.5), range: 0...1)
                    .accessibilityLabel("Comparison position")
                DockSlider(value: state.number(blockID + ":zoom", default: 1), range: 1...4).accessibilityLabel("Zoom")
            }
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
