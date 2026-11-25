import Charts
import SwiftUI

struct RichDatasetChartView: View {
    let dataset: RichDataset
    let configuration: RichDatasetChart
    @ObservedObject var state: RichArtifactPresentationState
    @State private var selectedLabel: String?
    @Environment(\.richGlance) private var glance
    private var labelIndex: Int { dataset.columns.firstIndex { $0.id == configuration.label } ?? 0 }
    private var selectedRow: RichDataset.Row? {
        dataset.rows.first { $0.id == state.snapshot.selected[RichSelectionIdentity.dataset(dataset.id)] }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { geometry in
                ScrollView(.horizontal) {
                    // A glance can't scroll sideways, so its marks share the visible width instead.
                    chart.frame(
                        width: glance
                            ? geometry.size.width
                            : max(geometry.size.width, CGFloat(dataset.rows.count) * 72 + 40)
                    )
                    .dockPadding(.top, 4)
                    .dockPadding(.bottom, 12)
                }
                .scrollIndicators(.never)
            }.frame(height: 200)
            if dataset.rows.isEmpty {
                Text("No data supplied.").dockFont(.metadata).foregroundStyle(Color.dockMetadataText)
            } else if glance {
                if configuration.series.count > 1 { legend }
            } else {
                inspector
            }
        }
    }

    @ViewBuilder private var inspector: some View {
        HStack(alignment: .center, spacing: 12) {
            if configuration.series.count > 1 { legend } else { Spacer(minLength: 0) }
            DockOptionPicker(
                label: "Inspect", selection: state.selection(RichSelectionIdentity.dataset(dataset.id)),
                options: [("", "Choose a row")] + dataset.rows.map { ($0.id, $0.values[labelIndex]) }
            )
            .fixedSize()
        }
        if let row = selectedRow {
            Text(
                zip(dataset.columns, row.values).map { "\($0.title): \($1)\($0.unit.map { " " + $0 } ?? "")" }
                    .joined(separator: " · ")
            )
            .dockFont(.metadata).monospacedDigit()
            .foregroundStyle(Color.dockSecondaryText).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var legend: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 140), alignment: .leading)],
            alignment: .leading, spacing: 8
        ) {
            ForEach(Array(configuration.series.enumerated()), id: \.element) { offset, series in
                if let column = dataset.columns.first(where: { $0.id == series }) {
                    HStack(spacing: 5) {
                        Circle().fill(DockAccentColor.allCases[offset % DockAccentColor.allCases.count].fill)
                            .frame(width: 7, height: 7)
                        Text(column.title + (column.unit.map { " (" + $0 + ")" } ?? ""))
                            .dockFont(.metadata)
                            .foregroundStyle(Color.dockSecondaryText)
                    }.fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Every category, or about eight evenly spaced ones when a glance squeezes many into its width.
    private var axisLabels: [String] {
        Self.axisLabels(dataset.rows.map { $0.values[labelIndex] }, thinned: glance)
    }

    static func axisLabels(_ labels: [String], thinned: Bool) -> [String] {
        guard thinned, labels.count > 12 else { return labels }
        let step = (labels.count + 7) / 8
        return labels.enumerated().filter { $0.offset % step == 0 }.map(\.element)
    }

    /// One series with few bars reads better with values on the marks than against the axis.
    private var annotatesBars: Bool { configuration.series.count == 1 && dataset.rows.count <= 12 }

    private var chart: some View {
        Chart {
            ForEach(configuration.series, id: \.self) { series in
                if let index = dataset.columns.firstIndex(where: { $0.id == series }) {
                    ForEach(dataset.rows) { row in
                        if let value = Double(row.values[index]) {
                            if configuration.style == "area" {
                                AreaMark(
                                    x: .value(dataset.columns[labelIndex].title, row.values[labelIndex]),
                                    y: .value(dataset.columns[index].title, value)
                                )
                                .foregroundStyle(DockAccentColor.teal.fill.opacity(0.22))
                            }
                            if configuration.style == "line" || configuration.style == "area" {
                                LineMark(
                                    x: .value(dataset.columns[labelIndex].title, row.values[labelIndex]),
                                    y: .value(dataset.columns[index].title, value)
                                )
                                .foregroundStyle(by: .value("Series", series))
                                .symbol(by: .value("Series", series))
                                .lineStyle(StrokeStyle(lineWidth: 2))
                            } else if configuration.style == "point" {
                                PointMark(
                                    x: .value(dataset.columns[labelIndex].title, row.values[labelIndex]),
                                    y: .value(dataset.columns[index].title, value)
                                )
                                .foregroundStyle(by: .value("Series", series))
                                .symbol(by: .value("Series", series))
                                .symbolSize(45)
                            } else {
                                BarMark(
                                    x: .value(dataset.columns[labelIndex].title, row.values[labelIndex]),
                                    y: .value(dataset.columns[index].title, value)
                                )
                                .foregroundStyle(by: .value("Series", series))
                                .position(by: .value("Series", series))
                                .cornerRadius(3)
                                .annotation(position: .top, spacing: 3) {
                                    if annotatesBars {
                                        Text(row.values[index]).dockFont(.metadata).monospacedDigit()
                                            .foregroundStyle(Color.dockSecondaryText)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            if !glance, let selectedRow {
                RuleMark(x: .value("Selected", selectedRow.values[labelIndex]))
                    .foregroundStyle(Color.dockSecondaryText)
            }
        }
        .chartForegroundStyleScale(
            domain: configuration.series,
            range: configuration.series.indices.map {
                DockAccentColor.allCases[$0 % DockAccentColor.allCases.count].fill
            }
        )
        .chartLegend(.hidden)
        .chartXSelection(value: $selectedLabel)
        .chartXAxis {
            AxisMarks(values: axisLabels) { value in
                AxisValueLabel {
                    if let label = value.as(String.self) {
                        Text(label).lineLimit(2).multilineTextAlignment(.center).frame(width: 68)
                            .fixedSize(horizontal: false, vertical: true).foregroundStyle(Color.dockMetadataText)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisGridLine().foregroundStyle(Color.dockBorderLight)
                AxisValueLabel().foregroundStyle(Color.dockMetadataText)
            }
        }
        .frame(height: 184)
        .onChange(of: selectedLabel) { _, value in
            if let row = dataset.rows.first(where: { $0.values[labelIndex] == value }) {
                state.snapshot.selected[RichSelectionIdentity.dataset(dataset.id)] = row.id
            }
        }
    }
}
