import AppKit
import SwiftUI
import Testing

@testable import Herm

@MainActor
struct NativeReviewRenderTests {
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
        for theme in DockThemeID.allCases
        where ["island", "clean", "eInk", "glass", "mono", "warmLight"].contains(theme.rawValue) {
            DockThemeRuntime.current = theme
            DockThemeRuntime.revision &+= 1
            for width in [352.0, 1000.0] {
                for showsNotes in [false, true] {
                    let height = showsNotes ? (width < 600 ? 480.0 : 360.0) : 250.0
                    let state = DiffReviewState()
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
                            "diff-\(theme.rawValue)-\(Int(width))\(showsNotes ? "-notes" : "").png"))
                    window.orderOut(nil)
                }
            }
        }
    }
}
