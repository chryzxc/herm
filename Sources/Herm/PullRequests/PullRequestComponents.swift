import Foundation
import SwiftUI

struct PullRequestRowView: View {
    let pullRequest: PullRequestRecord
    let isSelected: Bool
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 9) {
                PullRequestBranchIcon(status: iconStatus).padding(.top, -1)
                (Text("#\(pullRequest.displayNumber) ").foregroundStyle(Color.dockMetadataText) + Text(pullRequest.title).foregroundStyle(Color.dockPrimaryText))
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
            }
            Text(pullRequest.headBranch == "unknown" ? pullRequest.repository.id : "\(pullRequest.repository.id) · \(pullRequest.headBranch)")
                .font(.system(size: 11))
                .foregroundStyle(Color.dockMetadataText)
                .lineLimit(1)
                .truncationMode(.middle)
            HStack {
                Text(pullRequest.readinessLabel)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(pullRequest.isDraft ? Color.dockMetadataText : Color.dockAccent)
                    .padding(.horizontal, 6)
                    .frame(height: 16)
                    .background(Capsule().fill((pullRequest.isDraft ? Color.dockSurface4 : Color.dockAccent.opacity(0.16))))
                Spacer()
                if let adds = pullRequest.additions, let dels = pullRequest.deletions {
                    HStack(spacing: 8) {
                        Text("+\(adds)").foregroundStyle(Color.dockSuccess)
                        Text("−\(dels)").foregroundStyle(Color.dockDestructive)
                    }
                    .font(.system(size: 10, design: .monospaced))
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: DockLayout.controlRadius + 1, style: .continuous).fill(isSelected ? Color.dockAccent.opacity(0.16) : (isHovered ? Color.dockSurface4.opacity(0.5) : Color.clear)))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }

    private var iconStatus: PullRequestBranchIcon.Status {
        guard !pullRequest.isDraft else { return .draft }
        if pullRequest.mergeability == .conflicting || pullRequest.checks.contains(where: \.isFailure) || pullRequest.reviewDecision == "CHANGES_REQUESTED" { return .failure }
        return pullRequest.checksAvailable && !pullRequest.checks.isEmpty && pullRequest.checks.allSatisfy(\.isSuccess) ? .success : .neutral
    }
}

struct PullRequestDiffStat: View {
    let additions: Int
    let deletions: Int

    var body: some View {
        HStack(spacing: 5) {
            if additions > 0 { Text("+\(additions)").foregroundStyle(Color.dockSuccess) }
            if deletions > 0 { Text("−\(deletions)").foregroundStyle(Color.dockDestructive) }
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .fixedSize()
    }
}

struct PullRequestFileTreeRow: View {
    let node: PullRequestFileTreeNode
    let file: PullRequestFile?
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                PullRequestFileIcon(path: node.isDirectory ? nil : node.title, size: 14)
                Text(node.title)
                    .font(.system(size: 12, weight: node.isDirectory ? .regular : .medium))
                    .foregroundStyle(isSelected ? Color.dockPrimaryText : (node.isDirectory ? Color.dockMetadataText : Color.dockSecondaryText))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                if let file { PullRequestDiffStat(additions: file.additions, deletions: file.deletions) }
            }
            .padding(.leading, CGFloat(node.depth) * 12 + 8)
            .padding(.trailing, 8)
            .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DockLayout.controlRadius - 2, style: .continuous)
                    .fill(isSelected ? Color.dockAccent.opacity(0.16) : (isHovered && !node.isDirectory ? Color.dockSurface4.opacity(0.5) : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.dockHover)
        .disabled(node.isDirectory)
        .onHover { isHovered = $0 }
        .help(node.id)
    }
}

/// Same language-aware icons as the artifacts list; nil path draws a folder.
struct PullRequestFileIcon: View {
    let path: String?
    let size: CGFloat

    var body: some View {
        Group {
            if let path, let image = ArtifactFileIcon.image(for: (path as NSString).lastPathComponent) {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
            } else {
                DockIcon(path == nil ? .folder : .fileText, size: size - 1, color: Color.dockMetadataText)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct PullRequestDiffLineView: View {
    let line: PullRequestDiffLine
    var counterpart: String? = nil
    var wordDiffsEnabled = false

    var body: some View {
        let tint: Color = line.kind == .addition ? .dockSuccess : (line.kind == .deletion ? .dockDestructive : (line.kind == .hunk ? .dockAccent : .dockSecondaryText))
        let fill: Color = line.kind == .addition ? Color.dockSuccess.opacity(0.13) : (line.kind == .deletion ? Color.dockDestructive.opacity(0.13) : (line.kind == .hunk ? Color.dockAccent.opacity(0.08) : Color.dockSurface2))
        let content = (line.kind == .addition || line.kind == .deletion) ? String(line.text.dropFirst()) : line.text
        let counterpartContent = counterpart.map { value in
            guard let first = value.first, first == "+" || first == "-" else { return value }
            return String(value.dropFirst())
        }
        HStack(spacing: 0) {
            if line.kind == .addition || line.kind == .deletion { Text(String(line.text.prefix(1))).foregroundStyle(tint).fontWeight(.bold) }
            diffWords(content, counterpart: counterpartContent, tint: tint)
        }
        .frame(maxWidth: .infinity, minHeight: 19, alignment: .leading)
        .padding(.horizontal, 10)
        .background(fill)
        .overlay(alignment: .leading) { if line.kind != .context { tint.frame(width: 2) } }
    }

    @ViewBuilder
    private func diffWords(_ content: String, counterpart: String?, tint: Color) -> some View {
        if wordDiffsEnabled, let counterpart, content.count < 500 {
            let otherWords = Set(counterpart.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init))
            let words = content.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
            HStack(spacing: 0) {
                ForEach(Array(words.enumerated()), id: \.offset) { _, word in
                    Text(word)
                        .foregroundStyle(Color.dockSecondaryText)
                        .background(otherWords.contains(word.trimmingCharacters(in: .whitespacesAndNewlines)) ? Color.clear : tint.opacity(0.28))
                    if word != words.last { Text(" ") }
                }
            }
        } else {
            Text(content).foregroundStyle(Color.dockSecondaryText)
        }
    }
}

