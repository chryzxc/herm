import SwiftUI

struct ResultTextComparison: Equatable, Sendable {
    struct Line: Equatable, Sendable {
        enum Kind: Sendable { case unchanged, added, removed }
        let kind: Kind
        let text: String
    }
    let lines: [Line]
    let usesSeparateSnapshots: Bool
    let identical: Bool

    static func make(previous: String, current: String) -> Self {
        let old = previous.components(separatedBy: "\n")
        let new = current.components(separatedBy: "\n")
        guard old.count <= 400, new.count <= 400 else {
            return Self(lines: [], usesSeparateSnapshots: true, identical: previous == current)
        }
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in new.difference(from: old) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var lines: [Line] = []
        var i = 0
        var j = 0
        while i < old.count || j < new.count {
            if i < old.count, removed.contains(i) {
                lines.append(Line(kind: .removed, text: old[i]))
                i += 1
            } else if j < new.count, inserted.contains(j) {
                lines.append(Line(kind: .added, text: new[j]))
                j += 1
            } else if i < old.count, j < new.count {
                lines.append(Line(kind: .unchanged, text: new[j]))
                i += 1
                j += 1
            } else {
                break
            }
        }
        return Self(lines: lines, usesSeparateSnapshots: false, identical: previous == current)
    }
}

struct EdgeResultComparison: View {
    let previous: EdgeResultContent
    let current: EdgeResultContent
    let comparison: ResultTextComparison
    private var addedOutputs: [ArtifactRecord] {
        current.artifacts.filter { value in !previous.artifacts.contains { $0.value == value.value } }
    }
    private var removedOutputs: [ArtifactRecord] {
        previous.artifacts.filter { value in !current.artifacts.contains { $0.value == value.value } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Two observed reads").dockFont(.body, weight: .semibold)
            readLabel("Previous", content: previous)
            readLabel("Current", content: current)
            if comparison.identical, addedOutputs.isEmpty, removedOutputs.isEmpty {
                Text("No changes in the bounded excerpts or output references.")
            } else if comparison.usesSeparateSnapshots {
                Text("Long excerpts are shown separately to keep comparison responsive.")
                    .foregroundStyle(Color.dockSecondaryText)
                Text("Previous excerpt").fontWeight(.semibold)
                Text(previous.text).textSelection(.enabled)
                Text("Current excerpt").fontWeight(.semibold)
                Text(current.text).textSelection(.enabled)
            } else {
                ForEach(Array(comparison.lines.enumerated()), id: \.offset) { _, line in
                    Text("\(marker(line.kind)) \(line.text)")
                        .foregroundStyle(color(line.kind)).textSelection(.enabled)
                        .accessibilityLabel("\(label(line.kind)): \(line.text)")
                }
            }
            if !addedOutputs.isEmpty || !removedOutputs.isEmpty {
                Text("Output references").fontWeight(.semibold)
                ForEach(addedOutputs) { Text("+ \($0.value)").textSelection(.enabled) }
                ForEach(removedOutputs) { Text("− \($0.value)").textSelection(.enabled) }
            }
            Text(
                "An unchanged path does not prove unchanged file contents. These reads may refer to different turns; supplied reply references identify them only when available."
            )
            .dockFont(.metadata).foregroundStyle(Color.dockSecondaryText)
        }.dockFont(.body)
    }
    private func readLabel(_ label: String, content: EdgeResultContent) -> some View {
        Text(
            "\(label): \(content.loadedAt.formatted(date: .abbreviated, time: .standard))\(content.revisionID.map { " · reply \($0)" } ?? " · reply identity unavailable")"
        )
        .dockFont(.metadata).foregroundStyle(Color.dockSecondaryText)
    }
    private func marker(_ kind: ResultTextComparison.Line.Kind) -> String {
        switch kind {
        case .added: "+"
        case .removed: "−"
        case .unchanged: " "
        }
    }
    private func label(_ kind: ResultTextComparison.Line.Kind) -> String {
        switch kind {
        case .added: "Added"
        case .removed: "Removed"
        case .unchanged: "Unchanged"
        }
    }
    private func color(_ kind: ResultTextComparison.Line.Kind) -> Color {
        switch kind {
        case .added: .dockSuccess
        case .removed: .dockDestructive
        case .unchanged: .dockPrimaryText
        }
    }
}
