import Foundation
import Testing

@testable import Herm

struct RichVoicePreviewTests {
    @Test func recognizesBoundedVoiceCommandsWithoutMatchingLongerRequests() {
        #expect(RichVoicePreview.Command("Show the next results.") == .page(1))
        #expect(RichVoicePreview.Command("Previous page") == .page(-1))
        #expect(RichVoicePreview.Command("Read the second option.") == .option(1))
        #expect(RichVoicePreview.Command("Read row twenty-six.") == .row(25))
        #expect(RichVoicePreview.Command("Read row -1") == nil)
        #expect(RichVoicePreview.Command("Zoom in on the map.") == .zoom(1))
        #expect(RichVoicePreview.Command("Read the second option and pick it.") == nil)
        #expect(RichVoicePreview.Command("Zoom in on my calendar.") == nil)
    }

    @Test func nativeDatasetPagesReadAndHighlightsTheSameSourceOrderedRow() throws {
        let result = """
            ```herm-ui
            {"version":2,"id":"r","title":"Results","fallback":"Results","kind":"native",
            "datasets":[{"id":"main","columns":[{"id":"name","title":"Name","type":"text"},
            {"id":"cost","title":"Cost","type":"number","unit":"USD"}],"rows":[
            {"id":"first","values":["First","90"]},{"id":"b","values":["B","80"]},{"id":"c","values":["C","70"]},
            {"id":"d","values":["D","60"]},{"id":"e","values":["E","50"]},{"id":"f","values":["F","40"]},
            {"id":"g","values":["G","30"]},{"id":"last","values":["Last","20"]}]}],
            "blocks":[{"type":"table","id":"main-table","payload":{"dataset":"main"}}]}
            ```
            """
        let preview = RichVoicePreview(RichDocument(result))
        var position = RichVoicePreview.Position()
        #expect(preview.hint(at: position)?.contains("Next results") == true)
        #expect(preview.apply(.page(1), to: &position) == "Showing rows 7 through 8 of 8.")
        #expect(RichVoicePreview.rows(on: position.page, total: 8) == 6..<8)
        #expect(preview.apply(.page(1), to: &position) == "You’re on the last page.")
        #expect(preview.apply(.row(0), to: &position) == "Row 1. Name: First. Cost (USD): 90.")
        #expect(position.page == 0)
        let table = try #require(preview.table)
        #expect(preview.position(position, for: table.key).row == 0)
        #expect(preview.position(position, for: .init(surface: "another", index: 0)).row == nil)
        #expect(preview.apply(.row(100), to: &position) == "This table has 8 rows.")
        #expect(position.row == 0)
    }

    @Test func readsAComparisonBesideAnInteractiveBlockAndBoundsMapZoom() throws {
        let result = """
            ```herm-ui
            {"version":2,"id":"r","title":"Options","fallback":"Options","kind":"native","blocks":[
            {"type":"comparison","id":"opts","payload":{"criteria":["Cost","Travel time"],"options":[
            {"id":"a","title":"Ferry","values":["$30","45 minutes"]},
            {"id":"b","title":"Bus","values":["$12","80 minutes"]}]}},
            {"type":"map","id":"map","payload":{"title":"Port","latitude":10,"longitude":100}},
            {"type":"command","id":"command","payload":{"command":"pwd"}}]}
            ```
            """
        let preview = RichVoicePreview(RichDocument(result, streaming: true))
        var position = RichVoicePreview.Position()
        #expect(preview.apply(.option(1), to: &position) == "Bus. Cost: $12. Travel time: 80 minutes.")
        let comparison = try #require(preview.comparison)
        #expect(preview.position(position, for: comparison.key).option == 1)
        #expect(preview.apply(.page(1), to: &position) == "There’s no table to page through in this preview.")
        for _ in 0..<3 { #expect(preview.apply(.zoom(1), to: &position) == "Zoomed in.") }
        #expect(preview.apply(.zoom(1), to: &position) == "The map is as close as it can go.")
        let map = try #require(preview.map)
        #expect(preview.position(position, for: map).zoom == 3)
        #expect(preview.position(position, for: comparison.key).zoom == 0)
    }
}
