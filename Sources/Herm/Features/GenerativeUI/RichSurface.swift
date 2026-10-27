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
    var datasets: [RichDataset]?
    var metadata: RichSurfaceMetadata?
    var revisionOf: RichArtifactReference?

    func validate() -> Bool {
        guard [1, 2].contains(version), !id.isEmpty, id.count <= 128, !title.isEmpty, title.count <= 256,
            !fallback.isEmpty, fallback.utf8.count <= 65_536
        else { return false }
        switch kind {
        case .native:
            guard html == nil, let blocks, !blocks.isEmpty, blocks.count <= 100 else { return false }
            guard blocks.allSatisfy({ $0.validate() }) else { return false }
            if version == 1 { return blocks.allSatisfy { $0.payload == nil } && datasets == nil }
            guard RichIdentity.unique(blocks.compactMap(\.id)),
                (datasets ?? []).count <= 20, RichIdentity.unique((datasets ?? []).map(\.id)),
                (datasets ?? []).allSatisfy({ $0.validate() })
            else { return false }
            return blocks.allSatisfy { $0.payload?.validate(in: self) ?? true }
        case .html:
            return blocks == nil
                && html.map { !$0.isEmpty && $0.utf8.count <= RichDocument.maximumBytes } == true
        }
    }

    var plainText: String {
        var parts = [title, fallback]
        if metadata?.fictional == true { parts.append("Fictional data") }
        if let assumptions = metadata?.assumptions { parts.append("Assumptions: " + assumptions) }
        if let source = metadata?.source { parts.append("Source: " + source) }
        if let observedAt = metadata?.observedAt { parts.append("Observed: " + observedAt) }
        parts += (blocks ?? []).map(\.plainText)
        parts += (datasets ?? []).map { dataset in
            ([dataset.columns.map(\.title)] + dataset.rows.map(\.values)).map { $0.joined(separator: " | ") }
                .joined(separator: "\n")
        }
        return parts.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}

struct RichBlock: Codable, Equatable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case text, table, sources, gallery, chart, form
        case section, metrics, comparison, checklist, timeline, graph, tree, imageComparison, record, code, findings,
            workflow, command
    }
    let type: Kind
    var text: String?
    var columns: [String]?
    var rows: [[String]]?
    var items: [RichItem]?
    var style: String?
    var points: [RichPoint]?
    var fields: [RichField]?
    var submitLabel: String?
    var id: String?
    var payload: RichBlockPayload?

    func validate() -> Bool {
        if let payload { return id.map { !$0.isEmpty && $0.count <= 128 } == true && payload.validate() }
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
        case .section, .metrics, .comparison, .checklist, .timeline, .graph, .tree, .imageComparison, .record, .code,
            .findings, .workflow, .command:
            return false
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
        if let payload { return payload.plainText }
        return switch type {
        case .section, .metrics, .comparison, .checklist, .timeline, .graph, .tree, .imageComparison, .record, .code,
            .findings, .workflow, .command:
            ""
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
    enum CodingKeys: String, CodingKey {
        case type, text, columns, rows, items, style, points, fields, submitLabel, id, payload
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(type, forKey: .type)
        try values.encodeIfPresent(id, forKey: .id)
        if let payload { try payload.encode(to: values.superEncoder(forKey: .payload)) }
        try values.encodeIfPresent(text, forKey: .text)
        try values.encodeIfPresent(columns, forKey: .columns)
        try values.encodeIfPresent(rows, forKey: .rows)
        try values.encodeIfPresent(items, forKey: .items)
        try values.encodeIfPresent(style, forKey: .style)
        try values.encodeIfPresent(points, forKey: .points)
        try values.encodeIfPresent(fields, forKey: .fields)
        try values.encodeIfPresent(submitLabel, forKey: .submitLabel)
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        type = try values.decode(Kind.self, forKey: .type)
        id = try values.decodeIfPresent(String.self, forKey: .id)
        payload =
            values.contains(.payload)
            ? try RichBlockPayload.decode(type: type, decoder: values.superDecoder(forKey: .payload)) : nil
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

    /// `String.contains` takes milliseconds on a long reply, and streaming rows
    /// and the markdown prefetcher ask on every update; search the bytes.
    static func mentionsSurface(_ text: String) -> Bool {
        var text = text
        return text.withUTF8 { memmem($0.baseAddress, $0.count, "herm-ui", 7) != nil }
    }
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
        guard Self.mentionsSurface(text) else {
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

    static func validationReason(_ source: String) -> String {
        guard !source.isEmpty else { return "The source exceeded the display limit or is unavailable." }
        do {
            let surface = try JSONDecoder().decode(RichSurface.self, from: Data(source.utf8))
            if ![1, 2].contains(surface.version) { return "This reply uses an unsupported format version." }
            return "A component contains invalid data, duplicate identities, or unresolved references."
        } catch DecodingError.keyNotFound(let key, let context) {
            return "A required field is missing at \(fieldPath(context.codingPath + [key]))."
        } catch DecodingError.typeMismatch(_, let context) {
            return "A generated field has an unsupported value type at \(fieldPath(context.codingPath))."
        } catch DecodingError.valueNotFound(_, let context) {
            return "A required value is missing at \(fieldPath(context.codingPath))."
        } catch {
            return "The generated source is incomplete or does not match a supported format."
        }
    }

    private static func fieldPath(_ keys: [any CodingKey]) -> String {
        var path = ""
        for key in keys {
            if let index = key.intValue {
                path += "[\(index)]"
            } else {
                path += (path.isEmpty ? "" : ".") + key.stringValue
            }
        }
        return path.isEmpty ? "reply" : String(path.prefix(256))
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
