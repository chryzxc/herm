import AppKit
import SwiftUI
import Testing

@testable import Herm

@MainActor
struct NativeReviewRenderTests {
    @Test func renderBlameAfterRulerRedraw() async throws {
        guard let directory = ProcessInfo.processInfo.environment["HERM_WORKFLOW_REVIEW_DIR"] else { return }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        _ = DockThemeStore.shared
        let previousTheme = DockThemeRuntime.current
        defer {
            DockThemeRuntime.current = previousTheme
            DockThemeRuntime.revision &+= 1
        }
        DockThemeRuntime.current = try #require(DockThemeID.allCases.first { $0.rawValue == "clean" })
        DockThemeRuntime.revision &+= 1
        let patch =
            "@@ -1,3 +1,3 @@\n import Foundation\n-let title = \"Before\"\n+let title = \"After · 日本語\"\n print(title)"
        let commit = RepositoryBlameCommit(
            hash: "abc", author: "Example Author", authoredAt: Date(timeIntervalSince1970: 1_600_000_000),
            summary: "Change", isUncommitted: false)
        for (width, split, name) in [
            (352.0, true, "352-both"), (1000.0, true, "1000-both"),
            (1000.0, false, "1000-unified"),
        ] {
            let state = DiffReviewState()
            state.showsBlame = true
            state.blame = DiffBlame(
                old: [2: RepositoryBlameLine(lineNumber: 2, text: "let title = \"Before\"", commit: commit)],
                new: [2: RepositoryBlameLine(lineNumber: 2, text: "let title = \"After · 日本語\"", commit: commit)])
            let view = SharedDiffView(patch: patch, path: "file.swift", preferredSplit: split, state: state)
                .frame(width: width, height: 250).dockThemedRoot()
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(x: 0, y: 0, width: width, height: 250)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            window.orderFrontRegardless()
            for _ in 0..<8 {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(100))
            }
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            func descendants(_ view: NSView) -> [NSView] {
                [view] + view.subviews.flatMap(descendants)
            }
            let rulers = descendants(host).compactMap { ($0 as? NSScrollView)?.verticalRulerView }
            #expect(rulers.count == (width >= 680 && split ? 2 : 1))
            for ruler in rulers {
                let labels = (ruler.accessibilityChildren() ?? []).compactMap {
                    ($0 as? NSAccessibilityElement)?.accessibilityLabel()
                }
                #expect(labels.contains { $0.contains("Example Author") && $0.contains("abc") })
            }
            let png = try #require(rep.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("diff-clean-\(name).png"))
            window.orderOut(nil)
        }
    }

    @Test func renderReviewWidthsAndThemes() async throws {
        guard let directory = ProcessInfo.processInfo.environment["HERM_WORKFLOW_REVIEW_DIR"] else { return }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        _ = DockThemeStore.shared
        let old = DockThemeRuntime.current
        defer {
            DockThemeRuntime.current = old
            DockThemeRuntime.revision &+= 1
        }
        let patch =
            "@@ -1,3 +1,3 @@\n import Foundation\n-let title = \"Before\"\n+let title = \"After · 日本語\"\n print(title)"
        let commit = RepositoryBlameCommit(
            hash: "abc123", author: "Example Author", authoredAt: Date(timeIntervalSince1970: 1_600_000_000),
            summary: "Example change", isUncommitted: false)
        let oldEntry = RepositoryBlameLine(lineNumber: 2, text: "let title = \"Before\"", commit: commit)
        let newEntry = RepositoryBlameLine(lineNumber: 2, text: "let title = \"After · 日本語\"", commit: commit)
        for theme in DockThemeID.allCases
        where ["island", "clean", "eInk", "glass", "mono", "warmLight"].contains(theme.rawValue) {
            DockThemeRuntime.current = theme
            DockThemeRuntime.revision &+= 1
            for width in [352.0, 1000.0] {
                for variant in ["off", "both", "old", "notes"] {
                    let showsNotes = variant == "notes"
                    let height = showsNotes ? (width < 600 ? 480.0 : 360.0) : 250.0
                    let state = DiffReviewState()
                    if variant == "both" || variant == "old" {
                        state.showsBlame = true
                        state.blame = DiffBlame(old: [2: oldEntry], new: variant == "both" ? [2: newEntry] : [:])
                    }
                    if showsNotes {
                        state.notes = [
                            RevisionNote(
                                documentID: "earlier-revision", path: "Sources/LongDirectory/Example.swift",
                                selection: DiffSelection(
                                    lines: DiffDocument(path: "Example.swift", patch: patch).lines),
                                text:
                                    "Keep the Unicode title intact and handle empty input explicitly. This longer revision note should remain readable without squeezing the Edit and Remove actions."
                            )
                        ]
                    }
                    let view = SharedDiffView(
                        patch: patch, path: "Sources/LongDirectory/Example.swift", preferredSplit: true,
                        contextLoader: { _ in patch }, state: state
                    )
                    .frame(width: width, height: height, alignment: .topLeading).background(Color.dockCanvas)
                    .dockThemedRoot()
                    let host = NSHostingView(rootView: view)
                    host.frame = NSRect(x: 0, y: 0, width: width, height: height)
                    let window = NSWindow(
                        contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                    window.contentView = host
                    window.orderFrontRegardless()
                    for _ in 0..<8 {
                        host.layoutSubtreeIfNeeded()
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: rep)
                    let png = try #require(rep.representation(using: .png, properties: [:]))
                    try png.write(
                        to: URL(fileURLWithPath: directory).appendingPathComponent(
                            "diff-\(theme.rawValue)-\(Int(width))-\(variant).png"))
                    window.orderOut(nil)
                }
            }
        }
    }
}
