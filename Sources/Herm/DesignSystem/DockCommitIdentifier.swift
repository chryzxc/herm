import SwiftUI

struct DockCommitCheckEvidence: Equatable {
    let repositoryID: String
    let revision: String
    let checks: [GitHubCheckSummary]
    let isComplete: Bool
}

enum DockCommitCheckStatus: Equatable {
    case failed, running, passed, unknown, incomplete

    var label: String {
        switch self {
        case .failed: "Checks failed"
        case .running: "Checks running"
        case .passed: "Checks passed"
        case .unknown: "Check status unknown"
        case .incomplete: "Check status incomplete"
        }
    }

    var icon: Ph {
        switch self {
        case .failed: .xCircle
        case .running: .clock
        case .passed: .checkCircle
        case .unknown, .incomplete: .warningCircle
        }
    }

    var color: Color {
        switch self {
        case .failed: .dockDestructive
        case .running, .incomplete: .dockWarning
        case .passed: .dockSuccess
        case .unknown: .dockSecondaryText
        }
    }
}

enum DockCommitPresentation {
    static func diffActionLabel(revision: String, repositoryID: String, evidence: DockCommitCheckEvidence?) -> String {
        let status = checkStatus(repositoryID: repositoryID, revision: revision, evidence: evidence)
        let suffix =
            status.map {
                ", " + $0.label
                    + (evidence?.isComplete == false && ($0 == .failed || $0 == .running)
                        ? ", Check status incomplete" : "")
            } ?? ""
        return "Show diff for commit \(revision.prefix(7))" + suffix
    }

    static func checkStatus(
        repositoryID: String?, revision: String, evidence: DockCommitCheckEvidence?
    ) -> DockCommitCheckStatus? {
        guard let evidence, !evidence.checks.isEmpty, evidence.repositoryID == repositoryID,
            [40, 64].contains(revision.utf8.count), revision.utf8.allSatisfy(isHex),
            revision.lowercased() == evidence.revision.lowercased()
        else { return nil }
        if evidence.checks.contains(where: \.isFailure) { return .failed }
        let pending = ["queued", "in_progress", "pending", "requested", "waiting"]
        if evidence.checks.contains(where: {
            pending.contains($0.status.lowercased()) || $0.conclusion?.lowercased() == "pending"
        }) {
            return .running
        }
        if !evidence.isComplete { return .incomplete }
        if evidence.checks.allSatisfy({
            $0.status.lowercased() == "completed" && $0.conclusion?.lowercased() == "success"
        }) {
            return .passed
        }
        return .unknown
    }

    static func text(_ revision: String, length: Int? = 7, scale: CGFloat = 1) -> Text {
        Text(length.map { String(revision.prefix($0)) } ?? revision)
            .font(DockTypography.font(.machineMetadata, scale: scale))
    }

    static func summaryParts(_ value: String) -> (hash: String?, suffix: String) {
        let end = value.firstIndex(of: " ") ?? value.endIndex
        let candidate = String(value[..<end])
        guard (4...64).contains(candidate.utf8.count), candidate.utf8.allSatisfy(isHex) else { return (nil, value) }
        return (candidate, String(value[end...]))
    }

    static func isHex(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
    }
}

struct DockCommitIdentifier: View {
    let revision: String
    var length: Int? = 7
    var repositoryID: String? = nil
    var evidence: DockCommitCheckEvidence? = nil
    @Environment(\.dockWorkspaceScale) private var scale

    var body: some View {
        if !revision.isEmpty {
            let status = DockCommitPresentation.checkStatus(
                repositoryID: repositoryID, revision: revision, evidence: evidence)
            let label = status.map {
                $0.label
                    + (evidence?.isComplete == false && ($0 == .failed || $0 == .running)
                        ? ", Check status incomplete" : "")
            }
            HStack(spacing: 4) {
                DockCommitPresentation.text(revision, length: length, scale: scale)
                if let status, let label {
                    DockIcon(status.icon, size: 11, color: status.color).help(label).accessibilityLabel(label)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .help(revision)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Commit \(revision)" + (label.map { ", " + $0 } ?? ""))
        }
    }
}

struct DockCommitSummary: View {
    let value: String
    @Environment(\.dockWorkspaceScale) private var scale
    var body: some View {
        let parts = DockCommitPresentation.summaryParts(value)
        if let hash = parts.hash {
            DockCommitPresentation.text(hash, length: nil, scale: scale) + Text(parts.suffix)
        } else {
            Text(parts.suffix)
        }
    }
}

struct DockCommitRange: View {
    let before: String
    let after: String
    let hasBefore: Bool
    let hasAfter: Bool
    @Environment(\.dockWorkspaceScale) private var scale
    var body: some View {
        let first = hasBefore ? DockCommitPresentation.text(before, scale: scale) : Text("")
        let separator = hasBefore && hasAfter ? Text("…") : Text("")
        let last = hasAfter ? DockCommitPresentation.text(after, scale: scale) : Text("")
        (first + separator + last).underline()
    }
}
