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
                    Text(metadata.assignment)
                        .foregroundStyle(issue.assignees.isEmpty ? Color.dockSecondaryText : Color.dockReview)
                        .lineLimit(1).truncationMode(.tail)
                }.dockFont(.metadata)
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
        if isOpen { return .dockInfo }
        return state.lowercased() == "closed" ? .dockMerged : .dockSecondaryText
    }
    var presentationIcon: Ph { isOpen ? .record : (state.lowercased() == "closed" ? .checkCircle : .question) }
    var isOpen: Bool { state.caseInsensitiveCompare("open") == .orderedSame }
}
