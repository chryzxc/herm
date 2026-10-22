import Foundation
import SwiftUI

/// Path-based grouping, not a claim about the meaning of a diff's contents.
enum PullRequestChangeCategory: String, CaseIterable, Identifiable, Sendable {
    case code = "Code", tests = "Tests", mocks = "Mocks & fixtures", docs = "Docs", config = "Configuration", other = "Other"
    var id: String { rawValue }

    static func classify(_ path: String) -> Self {
        let parts = path.lowercased().split(separator: "/").map(String.init)
        let name = parts.last ?? ""
        let ext = (name as NSString).pathExtension
        if parts.contains(where: { ["mocks", "mock", "__mocks__", "fixtures", "__fixtures__", "stubs", "testdata"].contains($0) })
            || name.hasPrefix("mock") || name.contains(".mock.") || name.hasSuffix("mock.swift") { return .mocks }
        if parts.contains(where: { ["tests", "test", "__tests__", "spec", "specs", "e2e"].contains($0) || $0.hasSuffix("tests") })
            || name.hasPrefix("test_") || name.contains(".test.") || name.contains(".spec.")
            || name.hasSuffix("tests.swift") || name.hasSuffix("test.swift") || name.hasSuffix("_test.go") { return .tests }
        if parts.contains("docs") || ["md", "mdx", "rst", "adoc"].contains(ext) || ["readme", "license", "changelog"].contains(name) { return .docs }
        if parts.contains(".github") || ["json", "yaml", "yml", "toml", "ini", "cfg", "lock", "xcconfig"].contains(ext)
            || ["package.swift", "makefile", "dockerfile", ".gitignore", ".editorconfig"].contains(name) { return .config }
        if ["swift", "m", "mm", "h", "c", "cpp", "rs", "go", "py", "js", "jsx", "ts", "tsx", "vue", "svelte", "html", "css", "scss", "rb", "java", "kt", "sh", "sql", "php", "cs", "dart"].contains(ext) { return .code }
        return .other
    }

    var color: Color {
        switch self {
        case .code: .dockInfo
        case .tests: .dockSuccess
        case .mocks: .dockMerged
        case .docs: DockAccentColor.amber.color
        case .config: DockAccentColor.cyan.color
        case .other: .dockSecondaryText
        }
    }
}

struct PullRequestChangeGroup: Identifiable, Equatable {
    let category: PullRequestChangeCategory
    var files = 0
    var additions = 0
    var deletions = 0
    var id: PullRequestChangeCategory { category }

    static func summarize(_ files: [PullRequestFile]) -> [Self] {
        var groups: [PullRequestChangeCategory: Self] = [:]
        for file in files {
            let category = PullRequestChangeCategory.classify(file.path)
            var group = groups[category] ?? Self(category: category)
            group.files += 1
            group.additions += file.additions
            group.deletions += file.deletions
            groups[category] = group
        }
        return PullRequestChangeCategory.allCases.compactMap { groups[$0] }
    }
}

struct PullRequestChangeBreakdownView: View {
    let files: [PullRequestFile]?
    let expectedCount: Int?
    let isCurrent: Bool
    let isLoading: Bool
    let onReviewFiles: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DockSectionHeader(title: "Changes", style: DockThemePalette(theme: DockThemeRuntime.current)) {
                Button("Review files", action: onReviewFiles).buttonStyle(.dockLink)
            }
            if isCurrent, let files {
                if files.isEmpty {
                    Text(expectedCount == 0 ? "No changed files." : "File breakdown unavailable. Refresh to retry.")
                        .foregroundStyle(Color.dockSecondaryText)
                } else {
                    let groups = PullRequestChangeGroup.summarize(files)
                    HStack(spacing: 8) {
                        Text("\(files.count) \(files.count == 1 ? "file" : "files")\(expectedCount == files.count ? "" : " loaded")")
                        Spacer(minLength: 0)
                        Text("+\(groups.reduce(0) { $0 + $1.additions })").foregroundStyle(Color.dockSuccess)
                        Text("−\(groups.reduce(0) { $0 + $1.deletions })").foregroundStyle(Color.dockDestructive)
                    }.monospacedDigit()
                    Divider().overlay(Color.dockBorderLight)
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                        ForEach(groups) { group in
                            GridRow {
                                HStack(spacing: 6) {
                                    Circle().fill(group.category.color).frame(width: 6, height: 6)
                                    Text(group.category.rawValue)
                                    Text("\(group.files)").foregroundStyle(Color.dockMetadataText)
                                    Spacer(minLength: 0)
                                }
                                Text("+\(group.additions)").foregroundStyle(Color.dockSuccess)
                                    .gridColumnAlignment(.trailing)
                                Text("−\(group.deletions)").foregroundStyle(Color.dockDestructive)
                                    .gridColumnAlignment(.trailing)
                            }
                        }
                    }.monospacedDigit()
                    Text("Grouped by file path").dockFont(.metadata).foregroundStyle(Color.dockMetadataText)
                    if expectedCount != files.count {
                        Text(expectedCount.map { "Showing \(files.count) of \($0) files. Totals cover loaded files only." } ?? "File coverage is unknown. Totals cover loaded files only.")
                            .foregroundStyle(Color.dockWarning).fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                Text(isLoading ? "Loading file breakdown…" : "File breakdown unavailable or outdated. Refresh to retry.")
                    .foregroundStyle(Color.dockSecondaryText).fixedSize(horizontal: false, vertical: true)
            }
        }.dockFont(.body).foregroundStyle(Color.dockPrimaryText)
            .frame(maxWidth: .infinity, alignment: .leading).dockCard(padding: 12)
    }
}

extension PullRequestRecord {
    var presentationIcon: Ph {
        if mergedAt != nil { return .gitMerge }
        if state == "closed" { return .xCircle }
        if isDraft { return .pencilSimple }
        return .gitPullRequest
    }

    /// Leading mark is lifecycle only; readiness stays in its own labeled badge.
    var presentationColor: Color {
        if mergedAt != nil { return .dockMerged }
        if state == "closed" { return .dockDestructive }
        if isDraft { return .dockSecondaryText }
        return .dockSuccess
    }
}

extension PullRequestRecord {
    var reviewColor: Color {
        switch reviewDecision {
        case "APPROVED": .dockSuccess
        case "CHANGES_REQUESTED": DockAccentColor.pink.color
        case "REVIEW_REQUIRED": DockCategoryTone.review.color
        default: .dockSecondaryText
        }
    }

    /// Keep precedence identical to readinessLabel, including terminal lifecycle.
    var readinessColor: Color {
        if mergedAt != nil { return .dockMerged }
        if state == "closed" { return .dockDestructive }
        if mergeability == .conflicting { return .dockWarning }
        if isDraft { return .dockSecondaryText }
        if checks.contains(where: \.isFailure) { return .dockDestructive }
        if reviewDecision == "CHANGES_REQUESTED" { return reviewColor }
        if checks.contains(where: \.isPending) { return DockStatusTone.working.color }
        guard checksAvailable else { return .dockSecondaryText }
        if reviewDecision == "REVIEW_REQUIRED" { return reviewColor }
        if !checks.isEmpty && !checks.allSatisfy(\.isSuccess) { return .dockSecondaryText }
        return checks.isEmpty ? .dockSecondaryText : .dockSuccess
    }
}
