import SwiftUI

struct RichRevisionComparisonView: View {
    let previous: RichGeneratedArtifact
    let current: RichGeneratedArtifact
    let close: () -> Void

    var body: some View {
        DockExpandedPage(title: "Compare versions", subtitle: current.surface.title, close: close) {
            let comparison = ResultTextComparison.make(
                previous: previous.surface.plainText, current: current.surface.plainText)
            if comparison.usesSeparateSnapshots {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(
                            "These versions exceed the inline comparison limit. Readable results are shown separately."
                        )
                        .dockFont(.body).foregroundStyle(Color.dockSecondaryText)
                        Text("Previous").fontWeight(.semibold)
                        MarkdownMessageView(markdown: String(previous.surface.plainText.prefix(48_000)))
                        Text("Current").fontWeight(.semibold)
                        MarkdownMessageView(markdown: String(current.surface.plainText.prefix(48_000)))
                    }.dockPadding(16)
                }
            } else if comparison.identical {
                Text(
                    "The readable results are identical. Use View source on each version to inspect presentation changes."
                )
                .dockFont(.body).foregroundStyle(Color.dockSecondaryText).dockPadding(16)
            } else {
                SharedDiffView(
                    patch: Self.patch(
                        comparison, previous: previous.surface.plainText, current: current.surface.plainText),
                    path: "artifact.txt")
            }
        }
    }

    static func patch(_ comparison: ResultTextComparison, previous: String, current: String) -> String {
        let oldCount = previous.components(separatedBy: "\n").count
        let newCount = current.components(separatedBy: "\n").count
        let rows = comparison.lines.map { line in
            let marker: String
            switch line.kind {
            case .unchanged: marker = " "
            case .added: marker = "+"
            case .removed: marker = "-"
            }
            return marker + line.text
        }
        return "--- previous/artifact.txt\n+++ current/artifact.txt\n@@ -1,\(oldCount) +1,\(newCount) @@\n"
            + rows.joined(separator: "\n")
    }
}
