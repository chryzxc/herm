import SwiftUI

struct ObservedRequestReview: View {
    var closeAction: (() -> Void)?
    let comparison: ObservedRequestComparison
    @State private var selected: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        DockExpandedPage(
            title: "Local changes since request", subtitle: "Captured local changes · includes edits outside Herm",
            close: { if let closeAction { closeAction() } else { dismiss() } }
        ) {
            HSplitView {
                List(comparison.patches, id: \.path, selection: $selected) { patch in
                    Text(patch.path).dockFont(.body).lineLimit(1).truncationMode(.middle).help(patch.path)
                        .tag(patch.path)
                }
                .scrollContentBackground(.hidden).background(Color.dockCanvas)
                .frame(minWidth: 220, idealWidth: 280, maxWidth: 360)
                if let patch = comparison.patches.first(where: { $0.path == selected }) {
                    ScrollView {
                        SharedDiffView(
                            patch: patch.text, path: patch.path, projectPath: comparison.path,
                            owningSession: comparison.origin.session
                        ).padding(12)
                    }
                } else {
                    Text("Choose a changed file.").dockFont(.body).frame(maxWidth: .infinity)
                }
            }
        }.background(Color.dockCanvas).frame(minWidth: 800, idealWidth: 1100, minHeight: 560, idealHeight: 740)
            .onAppear { selected = comparison.patches.first?.path }
    }
}
