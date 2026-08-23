import Foundation

struct PlanArtifactHeading: Identifiable, Equatable {
    let level: Int
    let title: String
    let line: Int
    let anchor: String

    var id: String { "\(line):\(anchor)" }
}

struct PlanArtifactTask: Identifiable, Equatable {
    let label: String
    let line: Int
    let text: String

    var id: String { "\(line):\(label)" }
}

struct PlanArtifactPresentation: Equatable {
    let title: String
    let headings: [PlanArtifactHeading]
    let tasks: [PlanArtifactTask]
    let acceptanceIDs: [String]
    let dependencySummary: String?
    let comments: [PlanReviewComment]
    let summary: PlanArtifactSummary

    var staleCommentCount: Int { comments.filter { $0.isStale(comparedWith: summary.sha256) }.count }

    static func make(document: PlanArtifactDocument, comments: [PlanReviewComment] = []) -> Self {
        let lines = document.contents.components(separatedBy: .newlines)
        var headings: [PlanArtifactHeading] = []
        var tasks: [PlanArtifactTask] = []
        var acceptance = Set<String>()
        var dependencySummary: String?
        var inDependencyBlock = false
        var dependencyLines: [String] = []

        for (index, line) in lines.enumerated() {
            let lineNumber = index + 1
            if line.hasPrefix("```") {
                if inDependencyBlock && !dependencyLines.isEmpty { dependencySummary = dependencyLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) }
                inDependencyBlock.toggle()
                continue
            }
            if inDependencyBlock {
                if dependencyLines.count < 8 { dependencyLines.append(line) }
                continue
            }
            if let match = line.firstMatch(of: /^(#{1,6})\s+(.+?)\s*#*$/) {
                let rawTitle = String(match.2).trimmingCharacters(in: .whitespaces)
                let anchor = rawTitle.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: "-")
                headings.append(PlanArtifactHeading(level: match.1.count, title: rawTitle, line: lineNumber, anchor: anchor))
            }
            if let match = line.firstMatch(of: /^(?:[-*]\s+)?(?:###?\s+)?(?:Task\s+)?(P\d+(?:\.\d+)+)\s*:?\s*(.*)$/) {
                tasks.append(PlanArtifactTask(label: String(match.1), line: lineNumber, text: String(match.2).trimmingCharacters(in: .whitespaces)))
            }
            for match in line.matches(of: /\bAC-\d{2}\b/) { acceptance.insert(String(match.0)) }
        }

        return Self(title: document.summary.title, headings: headings, tasks: tasks, acceptanceIDs: acceptance.sorted(), dependencySummary: dependencySummary, comments: comments, summary: document.summary)
    }
}
