import Foundation

struct RichSurface: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case native, html }
    let version: Int
    let id: String
    let title: String
    let fallback: String
    let kind: Kind
    var blocks: [RichBlock]?
    var html: String?

    func validate() -> Bool {
        guard version == 1, !id.isEmpty, id.count <= 128, !title.isEmpty, title.count <= 256,
            !fallback.isEmpty, fallback.utf8.count <= 65_536
        else { return false }
        switch kind {
        case .native:
            guard html == nil, let blocks, !blocks.isEmpty, blocks.count <= 100 else { return false }
            return blocks.allSatisfy { $0.validate() }
        case .html:
            return blocks == nil
                && html.map { !$0.isEmpty && $0.utf8.count <= RichDocument.maximumBytes } == true
        }
    }

    var plainText: String {
        ([title, fallback] + (blocks ?? []).map(\.plainText)).filter { !$0.isEmpty }.joined(
            separator: "\n\n")
    }
}

struct RichBlock: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case text, table, sources, gallery, chart, form }
    let type: Kind
    var text: String?
    var columns: [String]?
    var rows: [[String]]?
    var items: [RichItem]?
    var style: String?
    var points: [RichPoint]?
    var fields: [RichField]?
    var submitLabel: String?

    func validate() -> Bool {
        switch type {
        case .text: return text.map { !$0.isEmpty } == true
        case .table:
            guard let columns, !columns.isEmpty, columns.count <= 20, let rows, rows.count <= 1_000 else {
                return false
            }
            return rows.allSatisfy { $0.count == columns.count }
        case .sources, .gallery:
            guard let items, !items.isEmpty, items.count <= 100 else { return false }
            return items.allSatisfy {
                !$0.title.isEmpty && RichResourcePolicy.url($0.url, image: type == .gallery) != nil
            }
        case .chart:
            guard ["bar", "line"].contains(style), let points, !points.isEmpty, points.count <= 1_000
            else { return false }
            return points.allSatisfy { !$0.label.isEmpty && $0.value.isFinite }
        case .form:
            guard let fields, !fields.isEmpty, fields.count <= 64,
                Set(fields.map(\.id)).count == fields.count
            else { return false }
            return fields.allSatisfy { field in
                guard !field.id.isEmpty, field.id.count <= 128, !field.label.isEmpty else { return false }
                if field.type == .choice || field.type == .multipleChoice {
                    guard let options = field.options, !options.isEmpty, options.count <= 100 else {
                        return false
                    }
                    return Set(options).count == options.count && options.allSatisfy { !$0.isEmpty }
                }
                return true
            }
        }
    }

    var plainText: String {
        switch type {
        case .text: text ?? ""
        case .table:
            ([columns ?? []] + (rows ?? [])).map { $0.joined(separator: " | ") }.joined(separator: "\n")
        case .sources, .gallery:
            (items ?? []).map { $0.url.hasPrefix("data:") ? $0.title : "\($0.title): \($0.url)" }.joined(
                separator: "\n")
        case .chart: (points ?? []).map { "\($0.label): \($0.value)" }.joined(separator: "\n")
        case .form: (fields ?? []).map { $0.label }.joined(separator: "\n")
        }
    }
}

extension RichBlock {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        type = try values.decode(Kind.self, forKey: .type)
        text = try values.decodeIfPresent(String.self, forKey: .text)
        columns = try values.decodeIfPresent([String].self, forKey: .columns)
        rows = try values.decodeIfPresent([[RichTableCell]].self, forKey: .rows)?.map { $0.map(\.text) }
        items = try values.decodeIfPresent([RichItem].self, forKey: .items)
        style = try values.decodeIfPresent(String.self, forKey: .style)
        points = try values.decodeIfPresent([RichPoint].self, forKey: .points)
        fields = try values.decodeIfPresent([RichField].self, forKey: .fields)
        submitLabel = try values.decodeIfPresent(String.self, forKey: .submitLabel)
    }
}

/// Table cells are display values; JSON numbers must not invalidate the entire reply.
private struct RichTableCell: Decodable {
    let text: String

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let string = try? value.decode(String.self) {
            text = string
        } else {
            text = try value.decode(Decimal.self).description
        }
    }
}

struct RichItem: Codable, Equatable, Sendable {
    let title: String
    let url: String
}
struct RichPoint: Codable, Equatable, Sendable {
    let label: String
    let value: Double
}
struct RichField: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case text, number, choice, multipleChoice, boolean }
    let id: String
    let label: String
    let type: Kind
    var required: Bool?
    var options: [String]?
}

enum RichResourcePolicy {
    static func url(_ value: String, image: Bool = false) -> URL? {
        guard value.count <= RichDocument.maximumBytes, let url = URL(string: value),
            url.user == nil, url.password == nil
        else { return nil }
        if image,
            ["data:image/png;base64,", "data:image/jpeg;base64,", "data:image/webp;base64,"].contains(
                where: value.hasPrefix)
        {
            return url
        }
        guard url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty,
            host.lowercased() != "localhost", !host.lowercased().hasSuffix(".localhost"),
            !host.lowercased().hasSuffix(".local"), !host.contains(":"),
            host.range(of: #"^[0-9.]+$"#, options: .regularExpression) == nil
        else { return nil }
        return url
    }
}

/// Assistant-only extension of the canonical fence grammar. GitHub/user Markdown stays ordinary Markdown.
struct RichDocument: Equatable, Sendable {
    static let maximumBytes = 1_048_576
    enum Segment: Equatable, Sendable {
        case markdown(String)
        case surface(RichSurface, source: String)
        case unavailable(String, source: String)
        case pending
    }
    let segments: [Segment]
    var hasSurfaces: Bool {
        segments.contains {
            if case .markdown = $0 { return false }
            return true
        }
    }
    var plainText: String {
        segments.compactMap { segment in
            switch segment {
            case .markdown(let text): return text
            case .surface(let surface, _): return surface.plainText
            case .unavailable(let text, _): return text
            case .pending: return nil
            }
        }.joined(separator: "\n\n")
    }

    init(_ text: String, streaming: Bool = false) {
        guard text.contains("herm-ui") else {
            segments = [.markdown(text)]
            return
        }
        var result: [Segment] = []
        var surfaceIDs = Set<String>()
        var markdown: [String] = []
        var code: [String] = []
        var fence: MarkdownFence?
        var rich = false
        var overLimit = false
        var bytes = 0
        func flush() {
            if !markdown.isEmpty {
                result.append(.markdown(markdown.joined(separator: "\n")))
                markdown = []
            }
        }
        for line in text.components(separatedBy: "\n") {
            if let current = fence {
                if current.isClosed(by: line) {
                    if rich {
                        if streaming {
                            result.append(.pending)
                        } else {
                            let segment = Self.decode(code.joined(separator: "\n"), overLimit: overLimit)
                            if case .surface(let surface, let source) = segment,
                                !surfaceIDs.insert(surface.id).inserted
                            {
                                result.append(.unavailable(surface.fallback, source: source))
                            } else {
                                result.append(segment)
                            }
                        }
                    } else {
                        markdown.append(line)
                    }
                    fence = nil
                    rich = false
                    code = []
                    bytes = 0
                    overLimit = false
                } else if rich {
                    bytes += line.utf8.count + 1
                    if bytes <= Self.maximumBytes { code.append(line) } else { overLimit = true }
                } else {
                    markdown.append(line)
                }
            } else if let opening = MarkdownFence(opening: line) {
                fence = opening
                rich = opening.language == "herm-ui"
                if rich { flush() } else { markdown.append(line) }
            } else {
                markdown.append(line)
            }
        }
        if rich {
            result.append(
                streaming
                    ? .pending
                    : .unavailable(
                        "Interactive content was incomplete.", source: code.joined(separator: "\n")))
        }
        flush()
        segments = result
    }

    private static func decode(_ source: String, overLimit: Bool) -> Segment {
        guard !overLimit, source.utf8.count <= maximumBytes else {
            return .unavailable("Interactive content exceeded the display limit.", source: "")
        }
        let data = Data(source.utf8)
        if let surface = try? JSONDecoder().decode(RichSurface.self, from: data), surface.validate() {
            return .surface(surface, source: source)
        }
        let fallback =
            (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["fallback"] as? String
        return .unavailable(
            String((fallback ?? "This interactive format is unavailable.").prefix(65_536)), source: source
        )
    }
}

enum RichPromptContext {
    static let instructions = """
        [Herm rendering context v1]
        Generative UI is enabled in Herm. This is the user's default reply-format preference. When an interactive or structured view helps, use a fenced `herm-ui` JSON object. Do not wait for the user to mention Herm UI, HTML, or this format.
        For calculators, simulations, interactive graphics, and tools whose results change with inputs, return a working self-contained HTML surface using kind "html". Put the complete HTML/CSS/JS document in html and omit blocks. Wire inputs to update results immediately. Deliver the interactive result rather than a code listing or instructions to save an HTML file, unless the user explicitly requests source code or a file.
        For example, "Create a savings calculator with starting balance, monthly contribution, annual interest rate, and years" requires an HTML surface with editable inputs and a recalculating projected balance, even without an explicit UI request.
        Use native blocks for useful tables, charts, sources, galleries, and forms. Use ordinary Markdown for simple answers where a visual view adds no value. Respect explicit requests for plain text, code listings, or project/file changes; this preference does not replace requested work with a preview.
        Always include a useful plain-text fallback. Do not invent execution outcomes. Schema: {"version":1,"id":"stable-short-id","title":"Title","fallback":"Readable explanation","kind":"native","blocks":[...]}. Blocks: {"type":"text","text":"..."}; {"type":"table","columns":["Name"],"rows":[["Value"]]}; {"type":"sources","items":[{"title":"Source","url":"https://..."}]}; gallery uses the same items with HTTPS or inline PNG/JPEG/WebP images; {"type":"chart","style":"bar" or "line","points":[{"label":"A","value":1}]}; {"type":"form","submitLabel":"Send answer","fields":[{"id":"name","label":"Name","type":"text","required":true}]}. Table rows are arrays of string or number cells, matching the columns. Chart style must be "bar" or "line" and each point has a string label and numeric value. Native surfaces omit html; HTML surfaces omit blocks. Do not add unsupported block types. Field types: text, number, choice, multipleChoice, boolean; choice fields require string options. Form answers return as a user message, never execute tools directly. Limits: 100 blocks, 1000 rows/points per block, 1 MiB per surface.
        HTML runs only when opened, without network, files, credentials, tools, downloads, popups or persistent storage; inline all resources and avoid eval. Never request secrets in generated forms.
        [/Herm rendering context]
        """
    static let suffix = "\n\n" + instructions
    static func prepare(_ text: String) -> String { text.hasSuffix(suffix) ? text : text + suffix }
    static func display(_ text: String) -> String {
        text.hasSuffix(suffix) ? String(text.dropLast(suffix.count)) : text
    }
}
