import Foundation

struct RichDataset: Codable, Equatable, Sendable, Identifiable {
    struct Column: Codable, Equatable, Sendable, Identifiable {
        enum Kind: String, Codable, Sendable { case text, number, date }
        let id: String
        let title: String
        let type: Kind
        var unit: String?
    }
    struct Row: Codable, Equatable, Sendable, Identifiable {
        let id: String
        let values: [String]
    }
    let id: String
    let columns: [Column]
    let rows: [Row]

    static func displayTable(id: String, columns: [String], rows: [[String]]) -> Self {
        RichDataset(
            id: id,
            columns: columns.enumerated().map { index, title in
                RichDataset.Column(
                    id: String(index), title: title,
                    type: !rows.isEmpty && rows.allSatisfy { Double($0[index])?.isFinite == true } ? .number : .text)
            }, rows: rows.enumerated().map { RichDataset.Row(id: String($0.offset), values: $0.element) })
    }

    func validate() -> Bool {
        guard !id.isEmpty, !columns.isEmpty, columns.count <= 20, rows.count <= 1_000,
            RichIdentity.unique(columns.map(\.id)), RichIdentity.unique(rows.map(\.id))
        else { return false }
        guard columns.allSatisfy({ !$0.title.isEmpty && $0.title.count <= 256 }) else { return false }
        return rows.allSatisfy { row in
            guard row.values.count == columns.count else { return false }
            return zip(columns, row.values).allSatisfy { column, value in
                switch column.type {
                case .text: return true
                case .number: return Double(value)?.isFinite == true
                case .date: return Self.dateValue(value) != nil
                }
            }
        }
    }

    static func dateValue(_ text: String) -> Date? {
        (try? Date(text, strategy: .iso8601))
            ?? (try? Date(text, strategy: .iso8601.year().month().day().dateSeparator(.dash)))
            ?? (try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
    }

    func displayedRows(query: String, column: Int?, descending: Bool) -> [Row] {
        let filtered =
            query.isEmpty
            ? rows
            : rows.filter {
                $0.values.contains { $0.localizedCaseInsensitiveContains(query) }
            }
        guard let column, columns.indices.contains(column) else { return filtered }
        switch columns[column].type {
        case .number:
            return Self.sortRows(filtered, descending: descending) { Double($0.values[column]) ?? 0 }
        case .date:
            return Self.sortRows(filtered, descending: descending) { Self.dateValue($0.values[column]) ?? .distantPast }
        case .text:
            return filtered.sorted { left, right in
                let order = left.values[column].localizedStandardCompare(right.values[column])
                return descending ? order == .orderedDescending : order == .orderedAscending
            }
        }
    }

    private static func sortRows<Key: Comparable>(_ rows: [Row], descending: Bool, key: (Row) -> Key) -> [Row] {
        rows.map { (row: $0, value: key($0)) }.sorted {
            descending ? $0.value > $1.value : $0.value < $1.value
        }.map(\.row)
    }
}

enum RichIdentity {
    static func unique(_ ids: [String]) -> Bool {
        ids.allSatisfy { !$0.isEmpty && $0.count <= 128 } && Set(ids).count == ids.count
    }
}

struct RichSection: Codable, Equatable, Sendable {
    let title: String
    let blocks: [String]
    var paired: Bool?
}
struct RichMetric: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let label: String
    let value: String
    var unit: String?
    var comparison: String?
}
struct RichMetrics: Codable, Equatable, Sendable { let items: [RichMetric] }
struct RichChoiceItem: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let title: String
    var detail: String?
    var date: String?
    var dependencies: [String]?
}
struct RichChoiceList: Codable, Equatable, Sendable { let items: [RichChoiceItem] }
struct RichComparison: Codable, Equatable, Sendable {
    struct Option: Codable, Equatable, Sendable, Identifiable {
        let id: String
        let title: String
        let values: [String]
        var detail: String?
    }
    let criteria: [String]
    let options: [Option]
}
struct RichGraph: Codable, Equatable, Sendable {
    struct Node: Codable, Equatable, Sendable, Identifiable {
        let id: String
        let title: String
        var detail: String?
        /// Reported state of the node, shared with workflow items; never a live runtime status.
        var status: RichWorkflow.Item.Status?
    }
    struct Edge: Codable, Equatable, Sendable {
        enum Style: String, Codable, Sendable { case solid, dashed }
        let source: String
        let target: String
        var label: String?
        var style: Style?
    }
    let nodes: [Node]
    let edges: [Edge]
}
struct RichTree: Codable, Equatable, Sendable {
    struct Item: Codable, Equatable, Sendable, Identifiable {
        let id: String
        let title: String
        var value: String?
        var parent: String?
    }
    let items: [Item]
    func validate() -> Bool {
        guard items.count <= 1_000, RichIdentity.unique(items.map(\.id)) else { return false }
        let parents = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.parent) })
        for item in items {
            var seen: Set<String> = [item.id]
            var parent = item.parent
            while let id = parent {
                guard parents.keys.contains(id), seen.insert(id).inserted else { return false }
                parent = parents[id] ?? nil
            }
        }
        return true
    }
}
struct RichImageComparison: Codable, Equatable, Sendable {
    let before: RichItem
    let after: RichItem
}
struct RichDatasetTable: Codable, Equatable, Sendable { let dataset: String }
struct RichDatasetChart: Codable, Equatable, Sendable {
    let dataset: String
    let label: String
    let series: [String]
    let style: String
}
struct RichRecordTarget: Codable, Equatable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable { case pullRequest, issue, kanban, calendar, usage, trace }
    let kind: Kind
    let id: String
}

/// V2 payloads stay typed; legacy fields are decoded only for V1-compatible blocks.
enum RichBlockPayload: Equatable, Sendable {
    case command(RichCommand)
    case code(RichCode)
    case callout(RichCallout)
    case facts(RichFacts)
    case faq(RichFacts)
    case breakdown(RichBreakdown)
    case findings(RichFindings)
    case workflow(RichWorkflow)
    case section(RichSection)
    case metrics(RichMetrics)
    case comparison(RichComparison)
    case checklist(RichChoiceList)
    case timeline(RichChoiceList)
    case graph(RichGraph)
    case tree(RichTree)
    case imageComparison(RichImageComparison)
    case table(RichDatasetTable)
    case chart(RichDatasetChart)
    case record(RichRecordTarget)

    static func decode(type: RichBlock.Kind, decoder: Decoder) throws -> Self {
        let value = try decoder.singleValueContainer()
        switch type {
        case .command: return .command(try value.decode(RichCommand.self))
        case .code: return .code(try value.decode(RichCode.self))
        case .callout: return .callout(try value.decode(RichCallout.self))
        case .facts: return .facts(try value.decode(RichFacts.self))
        case .faq: return .faq(try value.decode(RichFacts.self))
        case .breakdown: return .breakdown(try value.decode(RichBreakdown.self))
        case .findings: return .findings(try value.decode(RichFindings.self))
        case .workflow: return .workflow(try value.decode(RichWorkflow.self))
        case .section: return .section(try value.decode(RichSection.self))
        case .metrics: return .metrics(try value.decode(RichMetrics.self))
        case .comparison: return .comparison(try value.decode(RichComparison.self))
        case .checklist: return .checklist(try value.decode(RichChoiceList.self))
        case .timeline: return .timeline(try value.decode(RichChoiceList.self))
        case .graph: return .graph(try value.decode(RichGraph.self))
        case .tree: return .tree(try value.decode(RichTree.self))
        case .imageComparison: return .imageComparison(try value.decode(RichImageComparison.self))
        case .table: return .table(try value.decode(RichDatasetTable.self))
        case .chart: return .chart(try value.decode(RichDatasetChart.self))
        case .record: return .record(try value.decode(RichRecordTarget.self))
        default:
            throw DecodingError.dataCorruptedError(
                in: value, debugDescription: "This block does not support a payload.")
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .command(let value): try value.encode(to: encoder)
        case .code(let value): try value.encode(to: encoder)
        case .callout(let value): try value.encode(to: encoder)
        case .facts(let value): try value.encode(to: encoder)
        case .faq(let value): try value.encode(to: encoder)
        case .breakdown(let value): try value.encode(to: encoder)
        case .findings(let value): try value.encode(to: encoder)
        case .workflow(let value): try value.encode(to: encoder)
        case .section(let value): try value.encode(to: encoder)
        case .metrics(let value): try value.encode(to: encoder)
        case .comparison(let value): try value.encode(to: encoder)
        case .checklist(let value), .timeline(let value): try value.encode(to: encoder)
        case .graph(let value): try value.encode(to: encoder)
        case .tree(let value): try value.encode(to: encoder)
        case .imageComparison(let value): try value.encode(to: encoder)
        case .table(let value): try value.encode(to: encoder)
        case .chart(let value): try value.encode(to: encoder)
        case .record(let value): try value.encode(to: encoder)
        }
    }

    func validate(in surface: RichSurface? = nil) -> Bool {
        switch self {
        case .command(let value): return value.validate()
        case .code(let value): return value.validate()
        case .callout(let value): return value.validate()
        case .facts(let value): return value.validate()
        case .faq(let value): return value.validate()
        case .breakdown(let value): return value.validate()
        case .findings(let value): return value.validate()
        case .workflow(let value): return value.validate()
        case .section(let value):
            guard !value.title.isEmpty, !value.blocks.isEmpty, RichIdentity.unique(value.blocks) else { return false }
            guard let surface else { return true }
            return value.blocks.allSatisfy { id in
                surface.blocks?.contains { $0.id == id && $0.type != .section } == true
            }
        case .metrics(let value):
            return !value.items.isEmpty && value.items.count <= 20 && RichIdentity.unique(value.items.map(\.id))
                && value.items.allSatisfy { !$0.label.isEmpty && !$0.value.isEmpty }
        case .comparison(let value):
            return !value.criteria.isEmpty && value.criteria.count <= 20 && !value.options.isEmpty
                && value.options.count <= 1_000 && RichIdentity.unique(value.options.map(\.id))
                && value.options.allSatisfy { !$0.title.isEmpty && $0.values.count == value.criteria.count }
        case .checklist(let value), .timeline(let value):
            let ids = Set(value.items.map(\.id))
            return !value.items.isEmpty && value.items.count <= 1_000 && RichIdentity.unique(value.items.map(\.id))
                && value.items.allSatisfy {
                    !$0.title.isEmpty && ($0.dependencies ?? []).allSatisfy { ids.contains($0) }
                }
        case .graph(let value):
            let ids = Set(value.nodes.map(\.id))
            return !value.nodes.isEmpty && value.nodes.count <= 200 && value.edges.count <= 500
                && RichIdentity.unique(value.nodes.map(\.id)) && value.nodes.allSatisfy { !$0.title.isEmpty }
                && value.edges.allSatisfy { ids.contains($0.source) && ids.contains($0.target) }
        case .tree(let value): return value.validate()
        case .imageComparison(let value):
            return [value.before, value.after].allSatisfy {
                !$0.title.isEmpty && RichResourcePolicy.url($0.url, image: true)?.scheme == "data"
            }
        case .table(let value):
            return surface.map { $0.datasets?.contains { $0.id == value.dataset } == true } ?? !value.dataset.isEmpty
        case .chart(let value):
            guard ["bar", "line", "area", "point"].contains(value.style), RichIdentity.unique(value.series),
                !value.series.isEmpty
            else {
                return false
            }
            guard value.style != "area" || value.series.count == 1 else { return false }
            guard let surface else { return true }
            guard let dataset = surface.datasets?.first(where: { $0.id == value.dataset }),
                dataset.columns.contains(where: { $0.id == value.label })
            else { return false }
            return value.series.allSatisfy { id in dataset.columns.contains { $0.id == id && $0.type == .number } }
        case .record(let value): return !value.id.isEmpty && value.id.count <= 256
        }
    }

    var plainText: String {
        switch self {
        case .command(let value): return value.command
        case .code(let value): return value.plainText
        case .callout(let value): return value.plainText
        case .facts(let value): return value.plainText
        case .faq(let value): return value.plainText
        case .breakdown(let value): return value.plainText
        case .findings(let value): return value.items.map(\.plainText).joined(separator: "\n\n")
        case .workflow(let value): return value.items.map(\.plainText).joined(separator: "\n\n")
        case .section(let value): return value.title
        case .metrics(let value):
            return value.items.map { "\($0.label): \($0.value) \($0.unit ?? "")" }.joined(separator: "\n")
        case .comparison(let value):
            return value.options.map {
                "\($0.title): " + zip(value.criteria, $0.values).map { "\($0): \($1)" }.joined(separator: ", ")
            }.joined(separator: "\n")
        case .checklist(let value), .timeline(let value):
            return value.items.map { "\($0.title)\n\($0.detail ?? "")" }.joined(separator: "\n")
        case .graph(let value):
            return value.nodes.map { node in
                node.status.map { "\($0.rawValue.capitalized): \(node.title)" } ?? node.title
            }.joined(separator: "\n")
        case .tree(let value): return value.items.map { "\($0.title): \($0.value ?? "")" }.joined(separator: "\n")
        case .imageComparison(let value): return "\(value.before.title) / \(value.after.title)"
        case .table(let value): return "Dataset: \(value.dataset)"
        case .chart(let value): return "Dataset: \(value.dataset), \(value.series.joined(separator: ", "))"
        case .record(let value): return "\(value.kind.rawValue): \(value.id)"
        }
    }
}

struct RichSurfaceMetadata: Codable, Equatable, Sendable {
    var assumptions: String?
    var source: String?
    var observedAt: String?
    var fictional: Bool?
}

extension RichSurfaceMetadata {
    private enum CodingKeys: String, CodingKey { case assumptions, source, observedAt, fictional }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if let text = try? values.decode(String.self, forKey: .assumptions) {
            assumptions = text
        } else {
            let items = try values.decodeIfPresent([String].self, forKey: .assumptions)
            assumptions = items.flatMap { $0.isEmpty ? nil : $0.joined(separator: "\n") }
        }
        source = try values.decodeIfPresent(String.self, forKey: .source)
        observedAt = try values.decodeIfPresent(String.self, forKey: .observedAt)
        fictional = try values.decodeIfPresent(Bool.self, forKey: .fictional)
    }
}
