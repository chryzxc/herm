import AppKit
import SwiftUI
import Testing
import WebKit

@testable import Herm

@MainActor
struct RichTemplateContractTests {
    @Test func assumptionsAcceptTextListsAndOptionalValues() throws {
        for (json, expected): (String, String?) in [
            (#"{"assumptions":"Supplied assumption"}"#, "Supplied assumption"),
            (#"{"assumptions":["First assumption","Second assumption"]}"#, "First assumption\nSecond assumption"),
            (#"{"assumptions":[]}"#, nil), (#"{"assumptions":null}"#, nil), ("{}", nil),
        ] {
            let metadata = try JSONDecoder().decode(RichSurfaceMetadata.self, from: Data(json.utf8))
            #expect(metadata.assumptions == expected)
            #expect(
                try JSONDecoder().decode(RichSurfaceMetadata.self, from: JSONEncoder().encode(metadata)) == metadata)
        }
    }

    @Test(arguments: ["42", "true", "{}", "[42]", "[null]", #"["Supplied",true]"#])
    func malformedAssumptionsRemainUnavailable(_ json: String) {
        let source =
            #"{"version":2,"id":"invalid","title":"Invalid","fallback":"Readable fallback","kind":"native","metadata":{"assumptions":\#(json)},"blocks":[{"type":"text","text":"Supplied text"}]}"#
        #expect(
            RichDocument("```herm-ui\n" + source + "\n```").segments == [
                .unavailable("Readable fallback", source: source)
            ])
        #expect(RichDocument.validationReason(source).contains("metadata.assumptions"))
    }

    @Test func suppliedBudgetRendersAndIndexesWithoutChangingItsSource() throws {
        let source = RichTemplateFixtures.monthlyBudget
        let surface = try JSONDecoder().decode(RichSurface.self, from: Data(source.utf8))
        #expect(surface.validate())
        #expect(surface.blocks?.map(\.type) == [.metrics, .chart, .table])
        #expect(surface.metadata?.fictional == true)
        #expect(surface.plainText.contains("Savings is shown separately from expenses."))
        #expect(surface.plainText.contains("Remaining is income minus listed expenses and savings."))
        #expect(RichDocument("```herm-ui\n" + source + "\n```").segments == [.surface(surface, source: source)])
        let records = ArtifactService.extract(
            session: .init(
                id: "budget-session", title: "Budget", preview: "", startedAt: nil, messageCount: 1, source: "test"),
            messages: [["role": "assistant", "id": 42, "text": "```herm-ui\n" + source + "\n```"]])
        let generated = try #require(records.first?.generated)
        #expect(generated.source == source)
        #expect(generated.surface == surface)
        #expect(try RichArtifactExport.document(source: source) == Data(source.utf8))
    }

    @Test func connectedExamplesReferenceAvailableRecords() throws {
        let references = RichRecordTarget.Kind.allCases.map {
            RichRecordTarget(kind: $0, id: "loaded-\($0.rawValue)-\"quoted\"")
        }
        let context = RichGenerationContext(
            availableRecords: Set(RichRecordTarget.Kind.allCases), recordReferences: references)
        #expect(
            RichFeatureRegistry.instructions(context: context) == RichFeatureRegistry.instructions(context: context))
        for feature in RichFeatureRegistry.descriptors(in: context) where feature.recordKind != nil {
            let surface = try JSONDecoder().decode(
                RichSurface.self, from: Data(RichFeatureRegistry.exampleSurface(feature).utf8))
            #expect(surface.validate())
            guard case .record(let target) = surface.blocks?.first?.payload else {
                Issue.record("Connected example did not contain a record: \(feature.id)")
                continue
            }
            #expect(references.contains(target), "Advertised example must use a resolvable ID: \(feature.id)")
        }
        let withoutRecords = RichGenerationContext(availableRecords: Set(RichRecordTarget.Kind.allCases))
        #expect(RichFeatureRegistry.descriptors(in: withoutRecords).allSatisfy { $0.recordKind == nil })
        #expect(
            RichFeatureRegistry.descriptors(in: .init(recordReferences: references)).allSatisfy { $0.recordKind == nil }
        )
    }

    @Test func diagnosticsIdentifyTheInvalidFieldWithoutDiscardingTheFallback() {
        let badCell = RichTemplateFixtures.monthlyBudget.replacingOccurrences(of: #""4000""#, with: "4000")
        #expect(RichDocument.validationReason(badCell).contains("datasets[0].rows[0].values[1]"))
        // Required fields must fail closed instead of quietly omitting a component.
        let missing =
            #"{"version":2,"id":"missing","title":"Missing","fallback":"Readable","kind":"native","blocks":[{"id":"metrics","type":"metrics","payload":{}}]}"#
        #expect(RichDocument.validationReason(missing).contains("blocks[0].payload.items"))
        #expect(RichDocument("```herm-ui\n" + badCell + "\n```").plainText.hasPrefix("Income: $4,000"))
    }

    @Test func everyCatalogAndRecipeSampleUsesTheProductionPresentationPath() throws {
        let samples = try RichTemplateFixtures.samples()
        #expect(Set(samples.map(\.id)).count == samples.count)
        for sample in samples {
            let surface = try JSONDecoder().decode(RichSurface.self, from: Data(sample.source.utf8))
            #expect(surface.validate(), "Invalid template: \(sample.id)")
            let fenced = "```herm-ui\n" + sample.source + "\n```"
            #expect(
                RichDocument(fenced).segments == [.surface(surface, source: sample.source)],
                "Template rejected: \(sample.id)")
            #expect(RichDocument(fenced, streaming: true).segments == [.pending])
            #expect(GenerativeUIIntegration.readableText(ChatMessage(role: .hermes, text: fenced)) == surface.plainText)
            #expect(try RichArtifactExport.document(source: sample.source) == Data(sample.source.utf8))
            let previousHTML = GeneratedHTMLCoordinator.shared.activeKey
            let outputs = ArtifactService.extract(
                session: .init(
                    id: "templates", title: "Templates", preview: "", startedAt: nil, messageCount: 1, source: "test"),
                messages: [["role": "assistant", "id": 42, "text": fenced]])
            #expect(
                outputs.contains { $0.generated?.source == sample.source },
                "Template absent from Artifacts: \(sample.id)")
            #expect(GeneratedHTMLCoordinator.shared.activeKey == previousHTML)
        }
        let dataRecipe = try #require(samples.first { $0.id == "recipe-data" })
        let data = try JSONDecoder().decode(RichSurface.self, from: Data(dataRecipe.source.utf8))
        #expect(data.blocks?.map(\.type) == [.table, .chart])
    }

    @Test func imageComparisonExamplesContainDecodableImages() throws {
        let example = try #require(RichFeatureRegistry.local.first { $0.id == "imageComparison" })
        let surface = try JSONDecoder().decode(
            RichSurface.self, from: Data(RichFeatureRegistry.exampleSurface(example).utf8))
        guard case .imageComparison(let images) = surface.blocks?.first?.payload else {
            Issue.record("Missing image comparison example")
            return
        }
        for image in [images.before, images.after] {
            let data = try #require(
                Data(base64Encoded: String(image.url.split(separator: ",", maxSplits: 1).last ?? "")))
            #expect(NSImage(data: data) != nil)
        }
    }
}

enum RichTemplateFixtures {
    struct Sample {
        let id: String
        let source: String
    }

    static func samples() throws -> [Sample] {
        let context = RichGenerationContext(
            availableRecords: Set(RichRecordTarget.Kind.allCases),
            recordReferences: RichRecordTarget.Kind.allCases.map { .init(kind: $0, id: "loaded-" + $0.rawValue) })
        var result = RichFeatureRegistry.descriptors(in: context).map {
            Sample(id: "catalog-" + $0.id, source: RichFeatureRegistry.exampleSurface($0))
        }
        result += RichGenerationRecipes.all.map {
            Sample(id: "recipe-" + $0.id, source: RichGenerationRecipes.fixture(for: $0))
        }
        result.append(Sample(id: "supplied-budget", source: monthlyBudget))
        let variants = [
            RichSurface(
                version: 1, id: "form-controls", title: "Form controls", fallback: "Choose your answers", kind: .native,
                blocks: [
                    RichBlock(
                        type: .form,
                        fields: [
                            .init(id: "text", label: "Notes", type: .text),
                            .init(id: "number", label: "Count", type: .number),
                            .init(id: "choice", label: "Choice", type: .choice, options: ["One", "Two"]),
                            .init(id: "multiple", label: "Multiple", type: .multipleChoice, options: ["One", "Two"]),
                            .init(id: "boolean", label: "Include details", type: .boolean),
                        ])
                ]),
            RichSurface(
                version: 1, id: "line-chart", title: "Line chart", fallback: "Two supplied observations", kind: .native,
                blocks: [
                    RichBlock(
                        type: .chart, style: "line",
                        points: [.init(label: "First", value: 1), .init(label: "Second", value: 2)])
                ]),
        ]
        result += try variants.map {
            Sample(id: "variant-" + $0.id, source: String(decoding: try JSONEncoder().encode($0), as: UTF8.self))
        }
        let dataset = RichDataset(
            id: "timings",
            columns: [
                .init(id: "name", title: "Build", type: .text),
                .init(id: "current", title: "Current", type: .number, unit: "s"),
                .init(id: "previous", title: "Previous", type: .number, unit: "s"),
            ], rows: [.init(id: "a", values: ["Main", "42", "50"]), .init(id: "b", values: ["Feature", "67", "60"])])
        for style in ["bar", "line"] {
            let surface = RichSurface(
                version: 2, id: "multi-series-" + style, title: "Build times",
                fallback: "Supplied current and previous build times", kind: .native,
                blocks: [
                    .init(type: .table, id: "table", payload: .table(.init(dataset: dataset.id))),
                    .init(
                        type: .chart, id: "chart",
                        payload: .chart(
                            .init(dataset: dataset.id, label: "name", series: ["current", "previous"], style: style))),
                ], datasets: [dataset])
            result.append(
                Sample(
                    id: "variant-" + surface.id,
                    source: String(decoding: try JSONEncoder().encode(surface), as: UTF8.self)))
        }
        let paired = RichSurface(
            version: 2, id: "paired", title: "Paired sections", fallback: "Supplied metric and local checklist",
            kind: .native,
            blocks: [
                .init(
                    type: .section, id: "overview",
                    payload: .section(.init(title: "Overview", blocks: ["totals", "steps"], paired: true))),
                .init(
                    type: .metrics, id: "totals",
                    payload: .metrics(.init(items: [.init(id: "count", label: "Supplied count", value: "12")]))),
                .init(
                    type: .checklist, id: "steps",
                    payload: .checklist(.init(items: [.init(id: "review", title: "Review supplied data")]))),
            ])
        result.append(
            Sample(id: "variant-paired", source: String(decoding: try JSONEncoder().encode(paired), as: UTF8.self)))
        var repository = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { repository.deleteLastPathComponent() }
        let documentation = try String(
            contentsOf: repository.appendingPathComponent("docs/generative-ui.md"), encoding: .utf8)
        let document = RichDocument(documentation)
        let documented = document.segments.compactMap { segment -> Sample? in
            if case .surface(let surface, let source) = segment {
                return Sample(id: "docs-" + surface.id, source: source)
            }
            return nil
        }
        #expect(
            documented.count == documentation.components(separatedBy: "```herm-ui").count - 1,
            "A documented template failed validation")
        result += documented
        return result
    }

    static let monthlyBudget =
        #"{"version":2,"id":"monthly-budget","title":"Monthly Budget","fallback":"Income: $4,000. Listed expenses: $2,140. Savings: $600. Remaining after listed expenses and savings: $1,260. The table can be sorted by clicking a column header.","kind":"native","metadata":{"fictional":true,"assumptions":["Savings is shown separately from expenses.","Remaining is income minus listed expenses and savings."]},"datasets":[{"id":"budget","columns":[{"id":"item","title":"Category","type":"text"},{"id":"amount","title":"Monthly amount","type":"number","unit":"USD"},{"id":"share","title":"Share of income","type":"number","unit":"%"}],"rows":[{"id":"income","values":["Income","4000","100"]},{"id":"rent","values":["Rent","1400","35"]},{"id":"groceries","values":["Groceries","450","11.25"]},{"id":"transport","values":["Transport","200","5"]},{"id":"subscriptions","values":["Subscriptions","90","2.25"]},{"id":"savings","values":["Savings","600","15"]},{"id":"remaining","values":["Unassigned remaining","1260","31.5"]}]}],"blocks":[{"id":"metrics","type":"metrics","payload":{"items":[{"id":"income","label":"Monthly income","value":"$4,000"},{"id":"expenses","label":"Listed expenses","value":"$2,140"},{"id":"savings","label":"Savings","value":"$600"},{"id":"remaining","label":"Unassigned remaining","value":"$1,260"}]}},{"id":"chart","type":"chart","payload":{"dataset":"budget","label":"item","series":["amount"],"style":"bar"}},{"id":"table","type":"table","payload":{"dataset":"budget"}}]}"#
}
