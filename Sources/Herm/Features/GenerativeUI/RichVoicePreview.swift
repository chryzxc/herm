import Foundation

/// The read-only controls supported by the same validated document used by chat.
struct RichVoicePreview: Sendable {
    struct BlockKey: Hashable, Sendable {
        let surface: String
        let index: Int
    }

    struct OptionAnchor: Hashable, Sendable {
        let block: BlockKey
        let index: Int
    }

    struct Table: Sendable {
        let key: BlockKey
        let columns: [String]
        let rows: [[String]]
    }

    struct Position: Equatable, Sendable {
        var page = 0
        var row: Int?
        var option: Int?
        var zoom = 0
    }

    struct Navigation: Equatable, Sendable {
        var messageID: UUID?
        var position = Position()
    }

    enum Command: Equatable {
        case page(Int)
        case row(Int)
        case option(Int)
        case zoom(Int)

        init?(_ speech: String) {
            let normalized = AssistantIntent.normalized(speech)
                .trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines))
            let words = normalized.split(whereSeparator: \.isWhitespace).map(String.init)
            let phrase = words.joined(separator: " ")
            switch phrase {
            case "next results", "show next results", "show the next results", "next page", "show the next page":
                self = .page(1)
            case "previous results", "show previous results", "show the previous results", "previous page",
                "show the previous page":
                self = .page(-1)
            case "zoom in", "zoom in on the map": self = .zoom(1)
            case "zoom out", "zoom out on the map": self = .zoom(-1)
            default:
                guard words.first == "read" else { return nil }
                let target = words.dropFirst().filter { $0 != "the" }
                guard (2...3).contains(target.count) else { return nil }
                let ordinals = [
                    "first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth",
                ]
                for (noun, command) in [("row", Self.row), ("option", Self.option)]
                where target.first == noun || target.last == noun {
                    let word = target.filter { $0 != noun }.joined(separator: " ")
                    let ordinal = ordinals.firstIndex(of: word).map { $0 + 1 }
                    let number =
                        Int(word)
                        ?? AssistantIntent.number(word).flatMap { Int(NSDecimalNumber(decimal: $0).stringValue) }
                    guard let index = ordinal ?? number, (1...1_000).contains(index) else { return nil }
                    self = command(index - 1)
                    return
                }
                return nil
            }
        }
    }

    static let rowsPerPage = 6
    static let zoomRange = -3...3

    let document: RichDocument
    var isVisual: Bool { !document.segments.isEmpty }
    private(set) var table: Table?
    private(set) var comparison: (key: BlockKey, value: RichComparison)?
    private(set) var map: BlockKey?

    init(_ reply: RichDocument) {
        document = reply.voiceGlance
        for segment in document.segments {
            guard case .surface(let surface, _) = segment, let blocks = surface.blocks else { continue }
            for (index, block) in blocks.enumerated() {
                let key = BlockKey(surface: surface.id, index: index)
                switch block.payload {
                case .table(let reference) where table == nil:
                    if let dataset = surface.datasets?.first(where: { $0.id == reference.dataset }),
                        !dataset.rows.isEmpty
                    {
                        let columns = dataset.columns.map { $0.title + ($0.unit.map { " (\($0))" } ?? "") }
                        table = Table(key: key, columns: columns, rows: dataset.rows.map(\.values))
                    }
                case .none where block.type == .table && table == nil:
                    if let columns = block.columns, let rows = block.rows, !rows.isEmpty {
                        table = Table(key: key, columns: columns, rows: rows)
                    }
                case .comparison(let value) where comparison == nil:
                    comparison = (key, value)
                case .map where map == nil:
                    map = key
                default:
                    break
                }
            }
        }
    }

    static func rows(on page: Int, total: Int) -> Range<Int> {
        guard total > 0 else { return 0..<0 }
        let page = min(max(page, 0), (total - 1) / rowsPerPage)
        let start = page * rowsPerPage
        return start..<min(total, start + rowsPerPage)
    }

    func position(_ position: Position, for key: BlockKey) -> Position {
        if table?.key == key { return Position(page: position.page, row: position.row) }
        if comparison?.key == key { return Position(option: position.option) }
        if map == key { return Position(zoom: position.zoom) }
        return Position()
    }

    func hint(at position: Position) -> String? {
        var examples: [String] = []
        if let table {
            let rows = Self.rows(on: position.page, total: table.rows.count)
            if rows.upperBound < table.rows.count {
                examples.append("“Next results”")
            } else if rows.lowerBound > 0 {
                examples.append("“Previous results”")
            } else {
                examples.append("“Read row one”")
            }
        }
        if let comparison {
            if let current = position.option, comparison.value.options.count > 1 {
                let next = (current + 1) % comparison.value.options.count
                examples.append("“Read option \(next + 1)”")
            } else {
                examples.append("“Read the first option”")
            }
        }
        if map != nil { examples.append(position.zoom == Self.zoomRange.upperBound ? "“Zoom out”" : "“Zoom in”") }
        return examples.isEmpty ? nil : "Say " + examples.prefix(2).joined(separator: " or ")
    }

    /// Change only local preview state. Spoken details come from the displayed data.
    func apply(_ command: Command, to position: inout Position) -> String {
        switch command {
        case .page(let offset):
            guard let table else { return "There’s no table to page through in this preview." }
            let current = Self.rows(on: position.page, total: table.rows.count)
            let next = Self.rows(on: current.lowerBound / Self.rowsPerPage + offset, total: table.rows.count)
            guard next != current else { return offset > 0 ? "You’re on the last page." : "You’re on the first page." }
            position.page = next.lowerBound / Self.rowsPerPage
            position.row = nil
            return "Showing rows \(next.lowerBound + 1) through \(next.upperBound) of \(table.rows.count)."
        case .row(let index):
            guard let table else { return "There’s no table to read in this preview." }
            guard table.rows.indices.contains(index) else { return "This table has \(table.rows.count) rows." }
            position.page = index / Self.rowsPerPage
            position.row = index
            return "Row \(index + 1). " + Self.readout(labels: table.columns, values: table.rows[index])
        case .option(let index):
            guard let value = comparison?.value else { return "There’s no comparison in this preview." }
            guard value.options.indices.contains(index) else {
                return "This comparison has \(value.options.count) options."
            }
            position.option = index
            let option = value.options[index]
            return "\(option.title.prefix(90)). " + Self.readout(labels: value.criteria, values: option.values)
        case .zoom(let offset):
            guard map != nil else { return "There’s no map in this preview." }
            let zoom = position.zoom + offset
            guard Self.zoomRange.contains(zoom) else {
                return offset > 0 ? "The map is as close as it can go." : "The map is as far out as it can go."
            }
            position.zoom = zoom
            return offset > 0 ? "Zoomed in." : "Zoomed out."
        }
    }

    private static func readout(labels: [String], values: [String]) -> String {
        let fields = zip(labels, values).prefix(6).map {
            "\($0.0.prefix(40)): \($0.1.isEmpty ? "blank" : String($0.1.prefix(90)))"
        }
        let remainder = min(labels.count, values.count) - fields.count
        return fields.joined(separator: ". ") + "." + (remainder > 0 ? " There are \(remainder) more fields." : "")
    }
}
