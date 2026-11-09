import AppKit
import Testing

@testable import Herm

@MainActor
struct MermaidDiagramTests {
    let flowchart = """
        flowchart LR
         A[Production branch and baseline] --> B[Reproduce source failures]
         B --> C[Build and focused verification]
        """

    @Test func finishedMermaidFencesBecomeDiagrams() {
        let text = "Run graph\n\n```mermaid\n\(flowchart)\n```\n\nCost"
        let document = RichDocument(text)
        #expect(document.segments == [.markdown("Run graph\n"), .diagram(flowchart), .markdown("\nCost")])
        #expect(document.plainText.contains("```mermaid\n" + flowchart + "\n```"))
        #expect(RichDocument.mentionsSurface(text))
    }

    @Test func streamingAndUnclosedFencesStayCode() {
        let open = "```mermaid\n\(flowchart)"
        #expect(RichDocument(open + "\n```", streaming: true).segments == [.markdown(open + "\n```")])
        #expect(RichDocument(open).segments == [.markdown(open)])
        #expect(
            RichDocument("```swift\nlet mermaid = 1\n```").segments == [.markdown("```swift\nlet mermaid = 1\n```")])
    }

    @Test func rendersOfflineAndReportsInvalidSource() async throws {
        let image = try await MermaidRenderer.shared.render(flowchart, dark: true)
        #expect(image.size.width > 200 && image.size.height > 20)
        #expect(MermaidRenderer.shared.cached(flowchart, dark: true) === image)
        await #expect(throws: MermaidRenderer.Failure.self) {
            _ = try await MermaidRenderer.shared.render("flowchart LR\n A --> [[[", dark: false)
        }
    }
}
