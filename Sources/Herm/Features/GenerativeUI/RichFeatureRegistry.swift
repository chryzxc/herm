import Foundation

struct RichGenerationContext: Equatable, Sendable {
    var profileID: String?
    var sessionID: String?
    var availableRecords: Set<RichRecordTarget.Kind> = []
    var recordReferences: [RichRecordTarget] = []
    var terminalDirectory: String?
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
    private static let textBlock = RichFeatureDescriptor(
        id: "text", version: 1, guidance: "Readable text", example: #"{"type":"text","text":"Explanation"}"#)
    private static let tableBlock = RichFeatureDescriptor(
        id: "table", version: 1, guidance: "String or number cells, matching columns",
        example: #"{"type":"table","columns":["Month","Sales"],"rows":[["January",12]]}"#)

    static let local: [RichFeatureDescriptor] = [
        .init(
            id: "map", version: 2,
            guidance:
                "A native map with a named pin from verified place coordinates. Use title, latitude and longitude. Never invent coordinates.",
            example:
                #"{"id":"place","type":"map","payload":{"title":"Greenwich Observatory","latitude":51.4778,"longitude":-0.0014}}"#
        ),
        .init(
            id: "faq", version: 2,
            guidance:
                "Expandable reference questions. Each item has an id, a question in label and a Markdown answer in value.",
            example:
                #"{"id":"questions","type":"faq","payload":{"items":[{"id":"encoding","label":"Which encoding does the export use?","value":"The export uses **UTF-8**."}]}}"#
        ),
        .init(
            id: "breakdown", version: 2,
            guidance:
                "Compare nonnegative amounts in one unit with horizontal bars scaled to the largest supplied value. Keep the intended category order.",
            example:
                #"{"id":"time","type":"breakdown","payload":{"unit":"min","items":[{"id":"read","label":"Reading","value":24},{"id":"practice","label":"Practice","value":36}]}}"#
        ),
        .init(
            id: "callout", version: 2,
            guidance: "One note, tip, important point, warning or caution with a Markdown body",
            example:
                #"{"id":"retention","type":"callout","payload":{"tone":"note","body":"The export includes archived entries."}}"#
        ),
        .init(
            id: "facts", version: 2,
            guidance: "A compact list of supplied label–value pairs for specifications, handoffs or summaries",
            example:
                #"{"id":"format","type":"facts","payload":{"items":[{"id":"format","label":"File format","value":"CSV"},{"id":"encoding","label":"Encoding","value":"UTF-8"}]}}"#
        ),
        .init(
            id: "command", version: 2,
            guidance:
                "One explicit shell command (up to 512 UTF-8 bytes, no control characters or newlines). Run in Terminal is a user click in the original loaded session, in a fresh local shell at the displayed session directory. Use separate ordered blocks for migrations, installs, tests or dev servers. No automatic execution or success claims; code remains copy-only",
            example: #"{"id":"migrate","type":"command","payload":{"command":"bun run db:migrate"}}"#),
        .init(
            id: "code", version: 2, guidance: "Copyable code, commands, config or logs; display only, never executed",
            example:
                #"{"id":"snippet","type":"code","payload":{"language":"sh","filename":"Suggested check","code":"swift test --filter ExampleTests"}}"#
        ),
        .init(
            id: "findings", version: 2,
            guidance:
                "Reviews, research caveats and diagnostics; severity info/warning/critical, detail, optional location and recommendation",
            example:
                #"{"id":"review","type":"findings","payload":{"items":[{"id":"coverage","title":"Missing failure coverage","severity":"warning","detail":"The supplied test only covers success.","location":"Tests/ExampleTests.swift","recommendation":"Cover an unavailable response."}]}}"#
        ),
        .init(
            id: "workflow", version: 2,
            guidance:
                "Task plans, CI snapshots, release checks and runbooks; status proposed/running/passed/failed/blocked/skipped. Every non-proposed status requires supplied evidence; never implies live execution",
            example:
                #"{"id":"checks","type":"workflow","payload":{"items":[{"id":"build","title":"Build","status":"passed","evidence":"Supplied build log: exit 0"},{"id":"review","title":"Review changes","status":"proposed","detail":"Inspect the diff before publishing."}]}}"#
        ),
        textBlock,
        tableBlock,
        .init(
            id: "chart", version: 1, guidance: "Bar or line with numeric values",
            example: #"{"type":"chart","style":"bar","points":[{"label":"January","value":12}]}"#),
        .init(
            id: "dataset.table", version: 2, guidance: "Use type table with a typed shared dataset payload",
            example: #"{"id":"table","type":"table","payload":{"dataset":"sales"}}"#),
        .init(
            id: "dataset.chart", version: 2,
            guidance:
                "Shared dataset and numeric series IDs. Styles: bar for comparisons, line for ordered trends, point for discrete observations, area for one cumulative or volume series. Labels follow supplied row order; include units in columns",
            example:
                #"{"id":"chart","type":"chart","payload":{"dataset":"sales","label":"month","series":["sales"],"style":"bar"}}"#
        ),
        .init(
            id: "dataset.area", version: 2,
            guidance: "Single-series filled trend; ordered supplied values, never inferred forecasts",
            example:
                #"{"id":"trend","type":"chart","payload":{"dataset":"sales","label":"month","series":["sales"],"style":"area"}}"#
        ),
        .init(
            id: "dataset.point", version: 2,
            guidance: "Discrete observations across labelled categories without implying interpolation",
            example:
                #"{"id":"observations","type":"chart","payload":{"dataset":"sales","label":"month","series":["sales"],"style":"point"}}"#
        ),
        .init(
            id: "sources", version: 1, guidance: "Public HTTPS source links",
            example: #"{"type":"sources","items":[{"title":"Reference","url":"https://example.com"}]}"#),
        .init(
            id: "gallery", version: 1,
            guidance: "Inline image data or direct HTTPS image URLs. Use MEDIA: for delivered files and videos",
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
            id: "graph", version: 2,
            guidance:
                "Selectable nodes and directed edges; 200 nodes, 500 edges. Optional node status uses workflow states; edge style solid or dashed",
            example:
                #"{"id":"architecture","type":"graph","payload":{"nodes":[{"id":"ui","title":"UI","status":"passed"},{"id":"runtime","title":"Runtime","status":"failed"}],"edges":[{"source":"ui","target":"runtime","label":"retry","style":"dashed"}]}}"#
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
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return
            (local
            + RichRecordTarget.Kind.allCases.compactMap { kind -> RichFeatureDescriptor? in
                let references = context.recordReferences.filter {
                    $0.kind == kind && RichBlockPayload.record($0).validate()
                }.sorted { $0.id < $1.id }
                guard let target = references.first,
                    let encoded = try? encoder.encode(
                        RichBlock(type: .record, id: "record", payload: .record(target)))
                else { return nil }
                return RichFeatureDescriptor(
                    id: "record.\(kind.rawValue)", version: 2,
                    guidance: "Loaded \(kind.rawValue) record; status and navigation resolve from Herm. Available IDs: "
                        + references.map(\.id).joined(separator: ", "),
                    example: String(decoding: encoded, as: UTF8.self),
                    recordKind: kind)
            }).filter { $0.isAvailable(in: context) }.sorted { $0.id < $1.id }
    }

    private static let markdownGuidance =
        "Ordinary Markdown pipe tables are sortable in Herm. Use a GitHub-style alert such as > [!NOTE] followed by a quoted paragraph for an important aside. For specs, two or more bullets like - **Format:** CSV form a label–value list. These formats work directly in Markdown."

    static let mediaGuidance =
        "For a real image, video, or file, deliver the verified local path or direct public HTTPS media URL on its own MEDIA: line outside code fences. Prefer a file already produced or downloaded by your tools. An image or video delivery counts as the visual. Use source links for web pages, and don't repeat the same asset in a gallery and as a delivery."

    private static let replyGuidance = """
        This turn explicitly requests a Herm artifact. Use one useful fenced `herm-ui` JSON surface with blocks suited to the result, and don't repeat its contents as prose.
        For calculators, simulations, interactive graphics and tools whose results change with inputs, return a working self-contained HTML surface. Wire inputs to update results immediately.
        Honor explicit requests for plain text, raw code, or another exact format. Carry out project and file work normally. A verified media delivery can stand on its own. Never invent data, actions, status, or execution outcomes.
        """

    private static let referenceGuidance = """
        For specialized blocks, call herm_reference with surface "herm.generative-ui" if available. If no reference is available, use the basic native formats or a Markdown table.
        """

    /// Keep the reference available without requesting surfaces on written turns.
    static let rules = """
        Use ordinary Markdown for written chat. Do not emit a generated surface unless this turn explicitly requests a Herm artifact or the spoken-turn instructions ask for a visual. Preserve any explicitly requested output format.
        For spoken turns, follow that turn's instructions for the spoken summary and visual preview.
        \(referenceGuidance)
        """

    /// Envelope, composition rules and the local block catalog. Session records come from `sessionReference`.
    static func reference() -> String {
        """
        \(markdownGuidance)
        \(mediaGuidance)
        Example HTML tool: a savings calculator needs editable balance, contribution, rate and years with a recalculating result.
        Envelope: {"version":1,"id":"stable-short-id","title":"Title","fallback":"Readable explanation","kind":"native","blocks":[...]}. Use version 2 for new components, datasets or revisionOf. Native surfaces omit html. HTML uses kind "html", complete inline HTML/CSS/JS in html, and omits blocks. Include a useful fallback. HTML is offline and has no host bridge, credentials, storage, files, tools, downloads, popups or device access. Never request secrets.
        V2 blocks have stable id, type and typed payload. Legacy blocks still work. V2 datasets: [{"id":"sales","columns":[{"id":"month","title":"Month","type":"text"},{"id":"sales","title":"Sales","type":"number","unit":"units"}],"rows":[{"id":"jan","values":["January","12"]}]}]. Table payload: {"dataset":"sales"}; chart payload: {"dataset":"sales","label":"month","series":["sales"],"style":"bar"}. Columns use text, number or ISO8601 date; dataset cells, metric values, comparison values and tree values are strings. Share datasets to link selection. Optional metadata example: \(metadataExample). assumptions accepts a string or an array of strings; source and observedAt are strings, fictional is a boolean. Supply only known metadata. Only use revisionOf when the user supplies an exact artifact reference; copy it unchanged.
        Compose task-focused views: planning and runbooks use workflow + checklist; debugging and code review use findings + code; research uses sources + comparison; budgets use metrics + shared table/chart; onboarding uses tree + code; suggested shell actions use command blocks for install, migrate, test and start-server steps; release reviews use workflow + findings. Ask for missing requirements with form. Use only the blocks that help the current task, not every component. Workflows and findings are supplied snapshots, never verified runtime records. Non-proposed workflow states require evidence from the input. Use readable headings, short detail, and one primary working surface; avoid decorative dashboards. In HTML use the injected --herm-* theme variables, visible input labels, keyboard-accessible controls, responsive layouts and reduced-motion support. Use color for data identity and meaningful state, pair it with labels or symbols, and keep explanatory text readable.
        Limits: 1 MiB per surface, 100 blocks, 1000 rows/items/points, 20 table columns. Available blocks:
        \(catalog(descriptors(in: RichGenerationContext())))
        """
    }

    static func instructions(
        context: RichGenerationContext = RichGenerationContext(), servedByPlugin: Bool = false
    ) -> String {
        let catalog =
            servedByPlugin
            ? """
            Use one JSON object inside a herm-ui fence. Replace the example content with the actual answer.
            Short answer: \(exampleSurface(textBlock))
            Native table: \(exampleSurface(tableBlock))
            \(mediaGuidance)
            \(referenceGuidance)
            """
            : reference() + (sessionReference(context: context).map { "\n" + $0 } ?? "")
        return "[Herm rendering context v1]\n" + replyGuidance + "\n" + catalog + "\n[/Herm rendering context]"
    }

    static func sessionReference(context: RichGenerationContext) -> String? {
        let records = descriptors(in: context).filter { $0.recordKind != nil }
        var parts: [String] = []
        if let directory = context.terminalDirectory {
            parts.append("Native command blocks can run on this Mac in the session Terminal at: " + directory)
        }
        if !records.isEmpty { parts.append("Record blocks for this chat:\n" + catalog(records)) }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    private static func catalog(_ descriptors: [RichFeatureDescriptor]) -> String {
        descriptors.map { "\($0.id) (v\($0.version)): \($0.guidance). Example: \($0.example)" }
            .joined(separator: "\n")
    }

    static let datasetExample =
        #"{"id":"sales","columns":[{"id":"month","title":"Month","type":"text"},{"id":"sales","title":"Sales","type":"number","unit":"units"}],"rows":[{"id":"jan","values":["January","12"]},{"id":"feb","values":["February","18"]}]}"#

    static let metadataExample =
        #"{"fictional":true,"assumptions":["Illustrative supplied figures"],"source":"Supplied sample","observedAt":"2026-10-24T10:00:00Z"}"#

    static func exampleSurface(_ descriptor: RichFeatureDescriptor) -> String {
        let blocks =
            descriptor.id == "section"
            ? descriptor.example + "," + local.first { $0.id == "metrics" }!.example : descriptor.example
        let datasets = descriptor.id.hasPrefix("dataset.") ? ",\"datasets\":[" + datasetExample + "]" : ""
        return
            "{\"version\":\(descriptor.version),\"id\":\"example\",\"title\":\"Example\",\"fallback\":\"Example result\",\"kind\":\"native\",\"blocks\":[\(blocks)]\(datasets)}"
    }
}
