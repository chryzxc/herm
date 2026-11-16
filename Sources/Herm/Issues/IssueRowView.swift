import Foundation
import SwiftUI

struct GitHubIssueRowMetadata: Equatable {
    let repository: String
    let assignment: String
    let updated: String?

    var values: [String] {
        [repository, assignment, updated]
            .compactMap { value in
                guard let value else { return nil }
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
    }

    static func make(repository: String, assignees: [String], updated: String?, viewer: String? = nil) -> Self {
        let names =
            assignees
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { name in viewer.map { name.caseInsensitiveCompare($0) == .orderedSame } == true ? "you" : name }
        let assignment = names.isEmpty ? "Unassigned" : "Assigned to \(names.joined(separator: ", "))"
        return Self(repository: repository, assignment: assignment, updated: updated)
    }
}

struct IssueRowView: View {
    let issue: GitHubIssueRecord
    let isSelected: Bool
    var viewer: String?
    @State private var isHovered = false

    var body: some View {
        let metadata = GitHubIssueRowMetadata.make(
            repository: issue.repository.id,
            assignees: issue.assignees,
            updated: issue.updatedAt.map { HumanDateFormatting.relative($0) },
            viewer: viewer
        )
        HStack(alignment: .top, spacing: 10) {
            DockIcon(issue.presentationIcon, size: 16, color: issue.presentationColor)
                .frame(width: 30, height: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text("#\(issue.displayNumber)").foregroundStyle(Color.dockMetadataText)
                    Spacer(minLength: 4)
                    if let updated = metadata.updated { Text(updated).foregroundStyle(Color.dockMetadataText) }
                }.dockFont(.machineMetadata)
                Text(issue.title)
                    .dockFont(.body, weight: .semibold)
                    .foregroundStyle(Color.dockPrimaryText)
                    .lineLimit(2).multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) {
                    Text(issue.state.capitalized)
                        .foregroundStyle(Color.dockSecondaryText)
                    Spacer(minLength: 0)
                    ForEach(Array(issue.assignees.prefix(3).enumerated()), id: \.offset) { _, login in
                        let url = issue.assigneeAvatars.first {
                            $0.login.caseInsensitiveCompare(login) == .orderedSame
                        }?.avatarURL
                        AsyncImage(url: url) { phase in
                            if let image = phase.image {
                                image.resizable().scaledToFill()
                            } else {
                                DockIcon(.user, size: 11, color: .dockMetadataText)
                                    .frame(width: 20, height: 20).background(Color.dockSurface2)
                            }
                        }
                        .frame(width: 20, height: 20).clipShape(Circle())
                        .help(login).accessibilityLabel(login)
                    }
                    if issue.assignees.count > 3 {
                        Text("+\(issue.assignees.count - 3)").foregroundStyle(Color.dockMetadataText)
                            .help(issue.assignees.dropFirst(3).joined(separator: ", "))
                    }
                }.dockFont(.metadata)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(issue.state.capitalized), \(metadata.assignment)")
                if issue.typeName != nil || !issue.labelRecords.isEmpty {
                    DockChipFlow(spacing: 6) {
                        if let typeName = issue.typeName { DockMetadataPill(text: typeName, compact: true) }
                        ForEach(Array(issue.labelRecords.prefix(3).enumerated()), id: \.offset) { _, label in
                            DockMetadataPill(text: label.name, colorHex: label.color, compact: true)
                        }
                        if issue.labelRecords.count > 3 {
                            DockMetadataPill(text: "+\(issue.labelRecords.count - 3)", compact: true)
                                .help(issue.labelRecords.map(\.name).joined(separator: ", "))
                        }
                    }
                }
            }
        }
        .dockPadding(.horizontal, 12).dockPadding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            DockThemeShape(cornerRadius: DockLayout.controlRadius + 1)
                .dockSelectionFill(
                    isSelected,
                    fallback: isSelected
                        ? Color.dockAccent.opacity(0.12) : (isHovered ? Color.dockSurface4.opacity(0.45) : Color.clear))
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}

extension GitHubIssueRecord {
    var presentationColor: Color {
        if isOpen { return .dockSuccess }
        if state.lowercased() == "closed" && stateReason?.lowercased() == "not_planned" { return .dockSecondaryText }
        return state.lowercased() == "closed" ? .dockMerged : .dockSecondaryText
    }
    var presentationIcon: Ph {
        if isOpen { return .record }
        if state.lowercased() != "closed" { return .question }
        return stateReason?.lowercased() == "not_planned" ? .minusCircle : .checkCircle
    }
    var isOpen: Bool { state.caseInsensitiveCompare("open") == .orderedSame }
}
