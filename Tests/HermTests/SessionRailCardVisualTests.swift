import AppKit
import SwiftUI
import Testing

@testable import Herm

@Suite @MainActor
struct SessionRailCardVisualTests {
    @Test func summariesExpandWithoutOpeningPanelsUntilViewAllIsPressed() async throws {
        let app = NSApplication.shared
        // SwiftUI builds its accessibility tree only when an accessibility client is active.
        let enhancedAccessibility = app.value(forKey: "accessibilityEnhancedUserInterface")
        app.setValue(true, forKey: "accessibilityEnhancedUserInterface")
        defer { app.setValue(enhancedAccessibility, forKey: "accessibilityEnhancedUserInterface") }
        let repository = GitHubRepositoryReference(
            owner: "owner", name: "repo", webURL: URL(string: "https://github.com/owner/repo")!)
        let reference = GitHubItemReference(repository: repository, number: 42, kind: .pullRequest)
        let file = RepositoryFileChange(path: "file.swift", status: .modified, isStaged: false, renameSource: nil)
        var changesOpened = 0
        var pullRequestsOpened = 0
        let root = SessionRailCard(
            repositoryName: "repo", repositoryPath: "/tmp/rail-ui-test",
            changes: .init(repositoryName: "repo", fileCount: 1, untrackedCount: 0, files: [file]),
            lines: .init(additions: 1, deletions: 1), references: [reference], records: [:], failures: [:],
            isRefreshing: false, onRefresh: {}, onViewAllChanges: { changesOpened += 1 },
            onViewPullRequest: { _ in
                pullRequestsOpened += 1
                return true
            }
        ).frame(width: 330).padding(16).dockThemedRoot()
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: 362, height: 700)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        func settle() async throws {
            for _ in 0..<3 {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(30))
            }
        }
        // SwiftUI's lightweight accessibility children expose selectors without full protocol conformance.
        func elements(_ element: AnyObject) -> [AnyObject] {
            let children = element.accessibilityChildren?() ?? []
            return [element] + children.flatMap { elements($0 as AnyObject) }
        }
        func press(_ label: String) throws {
            let candidates = elements(host)
            let button = candidates.first { element in
                let role = element.accessibilityRole?()
                let title = element.accessibilityTitle?() ?? ""
                let description = element.accessibilityLabel?() ?? ""
                return (role == .button || role == .disclosureTriangle) && (title + description).contains(label)
            }
            if button == nil {
                print(
                    "Missing \(label): "
                        + candidates.map {
                            "\($0.accessibilityRole?()?.rawValue ?? "nil") \($0.accessibilityTitle?() ?? "") \($0.accessibilityLabel?() ?? "")"
                        }.joined(separator: " | "))
            }
            #expect(try #require(button).accessibilityPerformPress?() == true)
        }
        try await settle()
        try press("Changes")
        try await settle()
        #expect(changesOpened == 0 && pullRequestsOpened == 0)
        try press("file.swift")
        try await settle()
        #expect(changesOpened == 0 && pullRequestsOpened == 0)
        try press("Pull request #42")
        try await settle()
        #expect(changesOpened == 0 && pullRequestsOpened == 0)
        try press("View all changes")
        try await settle()
        #expect(changesOpened == 1 && pullRequestsOpened == 0)
        try press("View in GitHub panel")
        try await settle()
        #expect(changesOpened == 1 && pullRequestsOpened == 1)
    }

    @Test func renderQuietCardsAcrossThemesAndWidths() async throws {
        guard let directory = ProcessInfo.processInfo.environment["SESSION_RAIL_SNAPSHOT_DIR"] else { return }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        _ = NSApplication.shared
        _ = DockThemeStore.shared
        let savedTheme = DockThemeRuntime.current
        let savedAppearance = NSApplication.shared.appearance
        defer {
            DockThemeRuntime.current = savedTheme
            DockThemeRuntime.revision &+= 1
            NSApplication.shared.appearance = savedAppearance
        }
        let repository = GitHubRepositoryReference(
            owner: "owner", name: "hermes-agent-dock",
            webURL: URL(string: "https://github.com/owner/hermes-agent-dock")!)
        let record = try #require(
            PullRequestCenterAPI().parse(
                [
                    "number": 42, "title": "Refine the session rail cards", "state": "open",
                    "head": ["ref": "rail-cards"], "base": ["ref": "main"], "checks_available": true,
                ], repository: repository, localPath: ""))
        let appearances: [(DockThemeID, Bool)] = [(.storm, true), (.clean, false), (.mono, true), (.glass, false)]
        for (theme, dark) in appearances {
            DockThemeRuntime.current = theme
            DockThemeRuntime.revision &+= 1
            NSApplication.shared.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let root = HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 16) {
                    card(record: record, hasChanges: true).frame(width: 312)
                    card(record: nil, hasChanges: true).frame(width: 312)
                    card(record: nil, hasChanges: false).frame(width: 312)
                }
                VStack(alignment: .leading, spacing: 16) {
                    card(record: record, hasChanges: false).frame(width: 172)
                    card(record: nil, hasChanges: true).frame(width: 172)
                    card(record: nil, hasChanges: false).frame(width: 172)
                }
            }
            .padding(20).frame(width: 540, height: 660, alignment: .topLeading)
            .background(DockWindowBackground()).dockThemedRoot()
            .environment(\.colorScheme, dark ? .dark : .light)
            let host = NSHostingView(rootView: root)
            host.frame = NSRect(x: 0, y: 0, width: 540, height: 660)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = host
            window.orderFrontRegardless()
            for _ in 0..<3 {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(50))
            }
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("rail-\(theme.rawValue).png"))
            window.orderOut(nil)
        }
    }

    private func card(record: PullRequestRecord?, hasChanges: Bool) -> some View {
        SessionRailCard(
            repositoryName: "hermes-agent-dock",
            changes: hasChanges ? .init(repositoryName: "hermes-agent-dock", fileCount: 8, untrackedCount: 0) : nil,
            lines: hasChanges ? .init(additions: 5766, deletions: 109) : nil,
            references: record.map { [$0.reference] } ?? [], records: record.map { [$0.id: $0] } ?? [:], failures: [:],
            isRefreshing: false, onRefresh: {}, onViewAllChanges: {}, onViewPullRequest: { _ in true })
    }
}
