import Foundation
import Testing

@testable import Herm

@Suite("RichPassiveVisual")
@MainActor
struct RichPassiveVisualTests {
    private func reply(_ blocks: String, kind: String = "native") -> String {
        "Here you go.\n```herm-ui\n"
            + #"{"version":1,"id":"s","title":"T","fallback":"Readable","kind":"\#(kind)","blocks":[\#(blocks)]}"#
            + "\n```"
    }

    @Test func chartsTablesAndDiagramsPreview() {
        let chart = reply(#"{"type":"chart","style":"bar","points":[{"label":"A","value":1}]}"#)
        let table = reply(#"{"type":"table","columns":["A"],"rows":[["1"]]}"#)
        #expect(RichDocument(chart).hasVoiceVisuals)
        #expect(RichDocument(table).hasVoiceVisuals)
        #expect(RichDocument("```mermaid\ngraph TD; A-->B\n```").hasVoiceVisuals)
        #expect(VoicePassiveVisual.contains(chart))
    }

    @Test func formsAndActionsStayInChat() {
        let form = reply(#"{"type":"form","fields":[{"id":"q","label":"Which charts?","type":"text"}]}"#)
        let mixed = reply(
            #"{"type":"chart","style":"bar","points":[{"label":"A","value":1}]},"#
                + #"{"type":"form","fields":[{"id":"q","label":"More?","type":"boolean"}]}"#)
        #expect(!RichDocument(form).hasVoiceVisuals)
        #expect(RichDocument(mixed).hasVoiceVisuals)
        #expect(VoicePassiveVisual.contains(mixed))
        #expect(!VoicePassiveVisual.contains(form))
        let command =
            "```herm-ui\n"
            + #"{"version":2,"id":"a","title":"Run","fallback":"Copy","kind":"native","blocks":[{"type":"command","id":"c","payload":{"command":"pwd"}}]}"#
            + "\n```"
        #expect(!RichDocument(command).hasVoiceVisuals)
        for kind in [RichBlock.Kind.form, .checklist, .command, .record] {
            #expect(kind.asksForInput)
            #expect(!kind.isVisual)
        }
    }

    @Test func inlineHTMLWidgetsStayInChat() {
        // Hermes widgets are live HTML that can send prompts, like an HTML surface.
        let widget = "Here it is.\n::preview{file=\"/tmp/report.html\"}"
        #expect(!RichDocument(widget).hasVoiceVisuals)
        let mixed = RichDocument(widget + "\n```mermaid\ngraph TD; A-->B\n```")
        #expect(mixed.hasVoiceVisuals)
        #expect(mixed.segments.filter(\.showsInVoiceGlance) == [.diagram("graph TD; A-->B")])
        #expect(!RichDocument(reply("", kind: "html")).hasVoiceVisuals)
    }

    @Test func textOnlySurfacesHaveNothingToShow() {
        #expect(!RichDocument(reply(#"{"type":"text","text":"Spoken instead."}"#)).hasVoiceVisuals)
        #expect(!RichBlock.Kind.text.isVisual)
        #expect(!RichBlock.Kind.section.isVisual)
        #expect(RichBlock.Kind.metrics.isVisual)
    }

    @Test func glanceChartsThinCrowdedLabels() {
        let labels = (1...30).map(String.init)
        #expect(RichDatasetChartView.axisLabels(labels, thinned: false) == labels)
        #expect(RichDatasetChartView.axisLabels(Array(labels.prefix(12)), thinned: true).count == 12)
        let thinned = RichDatasetChartView.axisLabels(labels, thinned: true)
        #expect(thinned.first == "1")
        #expect((6...8).contains(thinned.count))
    }

    @Test func plainTextAndUnavailableAreNotVisuals() {
        #expect(!VoicePassiveVisual.contains("Just words."))
        #expect(!RichDocument("```herm-ui\n{not json}\n```").hasVoiceVisuals)
    }
}
