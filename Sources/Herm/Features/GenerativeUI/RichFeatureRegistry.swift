import Foundation

struct RichGenerationContext: Equatable, Sendable {
    var profileID: String?
    var sessionID: String?
    var availableRecords: Set<RichRecordTarget.Kind> = []
    var recordReferences: [RichRecordTarget] = []
}

struct RichFeatureDescriptor: Identifiable, Sendable {
    let id: String
    let version: Int
    let guidance: String
    let example: String
    var recordKind: RichRecordTarget.Kind?

    func isAvailable(in context: RichGenerationContext) -> Bool {
        recordKind.map { context.availableRecords.contains($0) } ?? true
    }
}

/// Every advertised example is decoded through the production format and rendered by its typed block view.
enum RichFeatureRegistry {
    static let local: [RichFeatureDescriptor] = [
        .init(id: "text", version: 1, guidance: "Readable text", example: #"{"type":"text","text":"Explanation"}"#),
        .init(
            id: "table", version: 1, guidance: "String or number cells, matching columns",
            example: #"{"type":"table","columns":["Month","Sales"],"rows":[["January",12]]}"#),
        .init(
            id: "chart", version: 1, guidance: "Bar or line with numeric values",
            example: #"{"type":"chart","style":"bar","points":[{"label":"January","value":12}]}"#),
        .init(
            id: "dataset.table", version: 2, guidance: "Use type table with a typed shared dataset payload",
            example: #"{"id":"table","type":"table","payload":{"dataset":"sales"}}"#),
        .init(
            id: "dataset.chart", version: 2, guidance: "Use type chart with a shared dataset and numeric series IDs",
            example:
                #"{"id":"chart","type":"chart","payload":{"dataset":"sales","label":"month","series":["sales"],"style":"bar"}}"#
        ),
        .init(
            id: "sources", version: 1, guidance: "Public HTTPS source links",
            example: #"{"type":"sources","items":[{"title":"Reference","url":"https://example.com"}]}"#),
        .init(
            id: "gallery", version: 1, guidance: "Inline image data or explicit public HTTPS image links",
            example: #"{"type":"gallery","items":[{"title":"Reference","url":"https://example.com/image.png"}]}"#),
        .init(
            id: "form", version: 1,
            guidance: "Fields: text, number, choice, multipleChoice, boolean; choices need options. Answers go to chat",
            example:
                #"{"type":"form","fields":[{"id":"answer","label":"Answer","type":"text"}],"submitLabel":"Send answer"}"#
        ),
        .init(
            id: "metrics", version: 2, guidance: "At most 20 supplied values and comparisons",
            example:
                #"{"id":"totals","type":"metrics","payload":{"items":[{"id":"sales","label":"Sales","value":"12","unit":"units"}]}}"#
        ),
        .init(
            id: "comparison", version: 2, guidance: "Options against shared criteria",
            example:
                #"{"id":"options","type":"comparison","payload":{"criteria":["Cost"],"options":[{"id":"a","title":"Option A","values":["$12"],"detail":"Example option"}]}}"#
        ),
        .init(
            id: "checklist", version: 2, guidance: "Local selections; user explicitly attaches results to chat",
            example:
                #"{"id":"steps","type":"checklist","payload":{"items":[{"id":"test","title":"Run focused tests"}]}}"#),
        .init(
            id: "timeline", version: 2, guidance: "Ordered or dated items with optional dependency IDs",
            example:
                #"{"id":"plan","type":"timeline","payload":{"items":[{"id":"first","title":"Prepare","date":"2026-10-24"},{"id":"next","title":"Review","dependencies":["first"]}]}}"#
        ),
        .init(
            id: "graph", version: 2, guidance: "Selectable nodes and directed edges; 200 nodes, 500 edges",
            example:
                #"{"id":"architecture","type":"graph","payload":{"nodes":[{"id":"ui","title":"UI"},{"id":"runtime","title":"Runtime"}],"edges":[{"source":"ui","target":"runtime","label":"request"}]}}"#
        ),
        .init(
            id: "tree", version: 2, guidance: "Flat items with optional parent ID; at most 1000 items, no cycles",
            example:
                #"{"id":"payload","type":"tree","payload":{"items":[{"id":"root","title":"Response"},{"id":"status","parent":"root","title":"Status","value":"200"}]}}"#
        ),
        .init(
            id: "imageComparison", version: 2,
            guidance: "Two inline PNG/JPEG/WebP images with synchronized comparison controls",
            example:
                #"{"id":"images","type":"imageComparison","payload":{"before":{"title":"Before","url":"data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGMICAgAAAHkAPEGGOe8AAAAAElFTkSuQmCC"},"after":{"title":"After","url":"data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGPYsmULAAQ8Ah36QelnAAAAAElFTkSuQmCC"}}}"#
        ),
        .init(
            id: "section", version: 2,
            guidance: "Single-level named groups reference block IDs; paired groups become columns at 640pt",
            example:
                #"{"id":"overview","type":"section","payload":{"title":"Overview","blocks":["totals"],"paired":true}}"#),
    ]

    static func descriptors(in context: RichGenerationContext) -> [RichFeatureDescriptor] {
        (local
            + RichRecordTarget.Kind.allCases.map { kind in
                RichFeatureDescriptor(
                    id: "record.\(kind.rawValue)", version: 2,
                    guidance: "Loaded \(kind.rawValue) record; status and navigation resolve from Herm. Available IDs: "
                        + context.recordReferences.filter { $0.kind == kind }.map(\.id).sorted().joined(separator: ", "),
                    example:
                        "{\"id\":\"record\",\"type\":\"record\",\"payload\":{\"kind\":\"\(kind.rawValue)\",\"id\":\"record-id\"}}",
                    recordKind: kind)
            }).filter { $0.isAvailable(in: context) }.sorted { $0.id < $1.id }
    }

    static func instructions(context: RichGenerationContext = RichGenerationContext()) -> String {
        let catalog = descriptors(in: context).map {
            "\($0.id) (v\($0.version)): \($0.guidance). Example: \($0.example)"
        }.joined(separator: "\n")
        return """
            [Herm rendering context v1]
            Generative UI is enabled in Herm. When an interactive or structured view helps, use a fenced `herm-ui` JSON object. Do not require the user to mention Herm UI or HTML.
            For calculators, simulations, interactive graphics and tools whose results change with inputs, return a working self-contained HTML surface. Wire inputs to update results immediately. A savings calculator needs editable balance, contribution, rate and years with a recalculating result.
            Respect explicit requests for plain text, code listings, or project/file changes. Use Markdown when a visual adds no value. Never invent data, verified status, actions, or execution outcomes.
            Envelope: {"version":1,"id":"stable-short-id","title":"Title","fallback":"Readable explanation","kind":"native","blocks":[...]}. Use version 2 for new components, datasets or revisionOf. Native surfaces omit html. HTML uses kind "html", complete inline HTML/CSS/JS in html, and omits blocks. Include a useful fallback. HTML is offline and has no host bridge, credentials, storage, files, tools, downloads, popups or device access. Never request secrets.
            V2 blocks have stable id, type and typed payload. Legacy blocks still work. V2 datasets: [{"id":"sales","columns":[{"id":"month","title":"Month","type":"text"},{"id":"sales","title":"Sales","type":"number","unit":"units"}],"rows":[{"id":"jan","values":["January","12"]}]}]. Table payload: {"dataset":"sales"}; chart payload: {"dataset":"sales","label":"month","series":["sales"],"style":"bar"}. Columns use text, number or ISO8601 date; cells are strings. Share datasets to link selection. metadata may contain assumptions, source, observedAt, fictional. Only use revisionOf when the user supplies an exact artifact reference; copy it unchanged.
            Limits: 1 MiB per surface, 100 blocks, 1000 rows/items/points, 20 table columns. Available blocks:
            \(catalog)
            [/Herm rendering context]
            """
    }

    static let datasetExample =
        #"{"id":"sales","columns":[{"id":"month","title":"Month","type":"text"},{"id":"sales","title":"Sales","type":"number","unit":"units"}],"rows":[{"id":"jan","values":["January","12"]},{"id":"feb","values":["February","18"]}]}"#

    static func exampleSurface(_ descriptor: RichFeatureDescriptor) -> String {
        let blocks =
            descriptor.id == "section"
            ? descriptor.example + "," + local.first { $0.id == "metrics" }!.example : descriptor.example
        let datasets = descriptor.id.hasPrefix("dataset.") ? ",\"datasets\":[" + datasetExample + "]" : ""
        return
            "{\"version\":\(descriptor.version),\"id\":\"example\",\"title\":\"Example\",\"fallback\":\"Example result\",\"kind\":\"native\",\"blocks\":[\(blocks)]\(datasets)}"
    }
}
