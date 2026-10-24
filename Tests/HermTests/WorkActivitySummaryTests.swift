import Foundation
import Testing

@testable import Herm

struct WorkActivitySummaryTests {
    @Test func emptyPeriodsDoNotRequestGeneration() {
        #expect(WorkActivitySummaryInput(range: WorkRange(), scope: "Day").prompt == nil)
    }

    @Test func samplesAreBoundedButCountsStayComplete() throws {
        var range = WorkRange()
        range.commits = (0..<30).map {
            WorkCommit(repo: "/private/repository", hash: "hash\($0)", subject: "Change \($0)", date: .distantPast)
        }
        let input = WorkActivitySummaryInput(range: range, scope: "Month")
        let prompt = try #require(input.prompt)
        #expect(prompt.contains("30 commits"))
        #expect(prompt.contains("Commit: Change 7"))
        #expect(!prompt.contains("Commit: Change 8"))
        #expect(!prompt.contains("/private/repository"))
        #expect(!prompt.contains("hash0"))
        #expect(prompt.contains("Scope: Month"))
    }

    @Test func sensitiveMetadataIsScrubbedBeforeGeneration() throws {
        var range = WorkRange()
        range.commits = [
            WorkCommit(repo: "Herm", hash: "abc", subject: "Fix token=example-private-value", date: .distantPast)
        ]
        let prompt = try #require(WorkActivitySummaryInput(range: range, scope: "Day").prompt)
        #expect(!prompt.contains("example-private-value"))
    }

    @Test func periodIdentityIncludesDatesAndScope() {
        var range = WorkRange()
        range.hasUsage = true
        range.tokens = 42
        let first = Date(timeIntervalSince1970: 1_700_000_000)
        range.points = [.init(date: first, shipped: 0, sessions: 0, runs: 0, hasFailure: false)]
        let day = WorkActivitySummaryInput(range: range, scope: "Day")
        #expect(day.prompt?.contains("42 tokens") == true)
        #expect(day != WorkActivitySummaryInput(range: range, scope: "Week"))
        range.points = [
            .init(date: first.addingTimeInterval(86400), shipped: 0, sessions: 0, runs: 0, hasFailure: false)
        ]
        #expect(day != WorkActivitySummaryInput(range: range, scope: "Day"))
    }

    @Test @MainActor func cleaningPreservesMarkdownParagraphsAndBullets() throws {
        let markdown = """
            Improved privacy disclosures and training reports.

            - **Privacy:** Clarified activity logging and audit records.
            - **Reports:** Fixed unsigned training records in exports.
            """
        let cleaned = try #require(OnDeviceAssist.cleanSummary("  \n" + markdown + "\n  "))
        #expect(cleaned == markdown)
        let blocks = MarkdownMessageView.renderBlocks(for: cleaned)
        #expect(blocks.count == 3)
        #expect(blocks.filter { if case .listItem = $0 { true } else { false } }.count == 2)
    }

    @Test func summaryCleaningRetainsMultipleSentencesAndBoundsOutput() {
        #expect(OnDeviceAssist.cleanSummary("First sentence.\nSecond sentence.") == "First sentence.\nSecond sentence.")
        #expect(OnDeviceAssist.cleanSummary(" \n ") == nil)
        #expect(OnDeviceAssist.cleanSummary(nil) == nil)
        #expect(OnDeviceAssist.cleanSummary(String(repeating: "a", count: 2000))?.count == 1000)
    }
}
