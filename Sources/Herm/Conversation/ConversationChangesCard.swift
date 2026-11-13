import SwiftUI

/// The runtime supplies bounded edit previews, which may omit files or lines.
struct ConversationChangesCard: View {
    let files: [ConversationChangeSummary.File]
    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(files) { file in
                let isOpen = expanded.contains(file.path)
                let fileName = (file.path as NSString).lastPathComponent
                VStack(alignment: .leading, spacing: 6) {
                    Button {
                        if isOpen { expanded.remove(file.path) } else { expanded.insert(file.path) }
                    } label: {
                        HStack(spacing: 8) {
                            PullRequestFileIcon(path: file.path, size: 14)
                            Text(fileName).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 8)
                            let lines = file.previews.flatMap { $0.components(separatedBy: "\n") }
                            let added = lines.filter { $0.hasPrefix("+") && !$0.hasPrefix("+++") }.count
                            let removed = lines.filter { $0.hasPrefix("-") && !$0.hasPrefix("---") }.count
                            HStack(spacing: 6) {
                                Text("+\(added)").foregroundStyle(Color.dockSuccess)
                                Text("−\(removed)").foregroundStyle(Color.dockDestructive)
                            }
                            .dockFont(.metadata, weight: .medium)
                            .monospacedDigit()
                            .fixedSize()
                            DockIcon(isOpen ? .caretDown : .caretRight, size: 10, color: Color.dockMetadataText)
                        }
                        .dockPadding(.horizontal, 8)
                        .dockPadding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.dockHover)
                    .accessibilityLabel("\(isOpen ? "Hide" : "Show") diff preview for \(fileName)")
                    .accessibilityHint("Line counts reflect the available diff preview.")
                    if isOpen {
                        ScrollView(.vertical) {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(file.previews.enumerated()), id: \.offset) { _, preview in
                                    ForEach(PullRequestDiffPresentation.lines(preview)) { line in
                                        PullRequestDiffLineView(line: line, wraps: true)
                                    }
                                }
                            }
                            .dockFont(.body, design: .monospaced)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 280)
                        .dockPadding(4)
                        .clipShape(DockThemeShape(cornerRadius: DockLayout.controlRadius, role: .control))
                        .dockWell()
                    }
                }
            }
        }
        .dockFont(.body)
        .foregroundStyle(Color.dockSecondaryText)
        .dockPadding(4)
        .dockWell()
    }
}
