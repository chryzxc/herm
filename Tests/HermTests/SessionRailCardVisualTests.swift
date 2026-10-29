import AppKit
import SwiftUI
import Testing

@testable import Herm

@Suite @MainActor
struct SessionRailCardVisualTests {
    @Test func newSummariesStayInlineAndBoundedUntilExplicitNavigation() async throws {
        let app = NSApplication.shared
        let accessibility = app.value(forKey: "accessibilityEnhancedUserInterface")
        app.setValue(true, forKey: "accessibilityEnhancedUserInterface")
        defer { app.setValue(accessibility, forKey: "accessibilityEnhancedUserInterface") }
        var summary = SessionRailSummary()
        summary.attention = [.init(id: "question", title: "Question", detail: "Which target?")]
        summary.plan = .init(
            sessionID: "session",
            items: (0..<40).map {
                .init(content: "Task \($0)", status: $0 == 0 ? "completed" : $0 == 1 ? "in_progress" : "pending")
            })
        summary.isWorking = true
        summary.outputs = [
            .init(value: "/tmp/rail-preview.md", sessionID: "session", sessionTitle: "Session", timestamp: .now)
        ]
        let pinPreview = "Saved decision " + String(repeating: "long detail ", count: 40) + "complete ending"
        summary.pins = [.init(rowID: 1, uid: "pin", role: "assistant", preview: pinPreview)]
        summary.workspace = .init(
            path: "/tmp/project", branch: "feature", latestCommit: "abc1234 Refine workspace details")
        var navigations: [String] = []
        let root = ScrollView {
            SessionRailSummarySections(
                summary: summary, onViewAllOutputs: { navigations.append("outputs") },
                onOpenOutput: { _ in navigations.append("output") },
                onRespondInChat: { navigations.append("reply") },
                onViewPin: { _ in
                    navigations.append("pin")
                    return true
                }
            )
            .padding(16)
        }.frame(width: 330).dockThemedRoot()
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: 330, height: 900)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        func settle() async throws {
            for _ in 0..<4 {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(30))
            }
        }
        func elements(_ element: AnyObject) -> [AnyObject] {
            [element] + (element.accessibilityChildren?() ?? []).flatMap { elements($0 as AnyObject) }
        }
        func press(_ text: String) async throws {
            let element = elements(host).first {
                let role = $0.accessibilityRole?()
                let title = ($0.accessibilityTitle?() ?? "") + ($0.accessibilityLabel?() ?? "")
                return (role == .button || role == .disclosureTriangle) && title.contains(text)
            }
            #expect(try #require(element).accessibilityPerformPress?() == true)
            try await settle()
        }
        try await settle()
        #expect(elements(host).contains { ($0.accessibilityLabel?() ?? "").contains("In progress: Task 1") })
        for section in [
            "Needs attention", "Tasks", "Outputs", "Pinned items", "Workspace",
        ] {
            try await press(section)
            #expect(navigations.isEmpty)
        }
        let taskLabels = elements(host).compactMap { $0.accessibilityLabel?() }
        let activeIndex = try #require(taskLabels.firstIndex(of: "Task 1, in progress"))
        let pendingIndex = try #require(taskLabels.firstIndex(of: "Task 2, pending"))
        let completedIndex = try #require(taskLabels.firstIndex(of: "Task 0, completed"))
        #expect(activeIndex < pendingIndex && pendingIndex < completedIndex)
        let scrolls = elements(host).filter { $0.accessibilityRole?() == .scrollArea }
        #expect(scrolls.count >= 6)
        let heights = scrolls.dropFirst().compactMap { $0.accessibilityFrame?().height }
        #expect(heights.allSatisfy { $0 <= 281 })
        #expect(heights.contains { $0 >= 279 })
        #expect(
            elements(host).contains {
                $0.accessibilityRole?() == .staticText
                    && String(describing: $0.accessibilityValue?() ?? "").contains("complete ending")
            })
        try await press("rail-preview.md")
        #expect(navigations == ["output"])
        try await press("View all outputs")
        try await press("Saved decision")
        try await press("Respond in chat")
        #expect(navigations == ["output", "outputs", "pin", "reply"])
    }

    @Test func summariesExpandWithoutOpeningPanelsUntilViewAllIsPressed() async throws {
        let app = NSApplication.shared
        // SwiftUI builds its accessibility tree only when an accessibility client is active.
        let enhancedAccessibility = app.value(forKey: "accessibilityEnhancedUserInterface")
        app.setValue(true, forKey: "accessibilityEnhancedUserInterface")
        defer { app.setValue(enhancedAccessibility, forKey: "accessibilityEnhancedUserInterface") }
        let repository = GitHubRepositoryReference(
            owner: "owner", name: "repo", webURL: URL(string: "https://github.com/owner/repo")!)
        let references = (42..<67).map {
            GitHubItemReference(repository: repository, number: $0, kind: .pullRequest)
        }
        let file = RepositoryFileChange(path: "file.swift", status: .modified, isStaged: false, renameSource: nil)
        let other = RepositoryFileChange(path: "other.swift", status: .untracked, isStaged: false, renameSource: nil)
        let tabs = SessionMessageTabs.shared
        let workspace = "rail-file-test-\(UUID().uuidString)"
        defer { for tab in tabs.tabs[workspace] ?? [] { tabs.close(tab.id, in: workspace) } }
        var changesOpened = 0
        var pullRequestsOpened = 0
        let root = SessionRailCard(
            repositoryName: "repo", repositoryPath: "/tmp/rail-ui-test",
            changes: .init(repositoryName: "repo", fileCount: 2, untrackedCount: 1, files: [file, other]),
            lines: .init(additions: 1, deletions: 1), references: references, records: [:], failures: [:],
            isRefreshing: false, onRefresh: {}, onViewAllChanges: { changesOpened += 1 },
            onViewPullRequest: { reference in
                pullRequestsOpened += 1
                tabs.open(.pullRequest(reference), in: workspace)
                return true
            }
        ).environment(\.sessionPreviewWorkspace, workspace).frame(width: 330).padding(16).dockThemedRoot()
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
        #expect(!elements(host).contains { ($0.accessibilityLabel?() ?? "").contains("Pull request #42") })
        try press("Pull requests")
        try await settle()
        #expect(changesOpened == 0 && pullRequestsOpened == 0)
        #expect(elements(host).contains { ($0.accessibilityLabel?() ?? "").contains("Pull request #42") })
        let listHeights = elements(host).filter { $0.accessibilityRole?() == .scrollArea }
            .compactMap { $0.accessibilityFrame?().height }
        #expect(!listHeights.isEmpty && listHeights.allSatisfy { $0 <= 281 })
        #expect(listHeights.contains { $0 >= 279 })
        try press("Pull requests")
        try await settle()
        #expect(!elements(host).contains { ($0.accessibilityLabel?() ?? "").contains("Pull request #42") })
        try press("Pull requests")
        try await settle()
        try press("Changes")
        try await settle()
        #expect(changesOpened == 0 && pullRequestsOpened == 0)
        try press("file.swift")
        try await settle()
        #expect(
            tabs.tabs[workspace]?.last?.content.key
                == "file:/tmp/rail-ui-test/file.swift")
        let firstID = try #require(tabs.selection[workspace])
        try press("other.swift")
        try await settle()
        #expect(tabs.tabs[workspace]?.count == 2)
        #expect(tabs.tabs[workspace]?.last?.content.key == "file:/tmp/rail-ui-test/other.swift")
        #expect(tabs.selection[workspace] != firstID)
        try press("file.swift")
        try await settle()
        #expect(tabs.tabs[workspace]?.count == 2)
        #expect(tabs.selection[workspace] == firstID)
        #expect(changesOpened == 0 && pullRequestsOpened == 0)
        try press("Pull request #42")
        try await settle()
        #expect(changesOpened == 0 && pullRequestsOpened == 1)
        #expect(tabs.tabs[workspace]?.last?.content.key == "pullRequest:" + references[0].id)
        #expect(tabs.selection[workspace] == tabs.tabs[workspace]?.last?.id)
        try press("View all changes")
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
