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
        let names = assignees
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
            DockIcon(.record, size: 14, color: issue.isOpen ? DockStatusTone.complete.color : Color.dockMetadataText)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 5) {
                Text(issue.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isSelected ? Color.dockPrimaryText : Color.dockPrimaryText.opacity(0.9))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 5) {
                    Text("#\(issue.displayNumber)")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                    Text("·")
                    Text(metadata.assignment)
                    if let updated = metadata.updated {
                        Text("·")
                        Text(updated)
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(Color.dockMetadataText)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous)
                .fill(isSelected ? Color.dockAccent.opacity(0.12) : (isHovered ? Color.dockSurface4.opacity(0.45) : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous)
                .stroke(Color.dockAccent.opacity(isSelected ? 0.35 : 0), lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}

extension GitHubIssueRecord {
    var isOpen: Bool { state.caseInsensitiveCompare("open") == .orderedSame }
}

