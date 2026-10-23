import AppKit
import SwiftUI
import Testing

@testable import Herm

@MainActor
struct PullRequestReviewRenderTests {
    @Test func renderReviewAuthoringAndInlineDrafts() async throws {
        guard let directory = ProcessInfo.processInfo.environment["HERM_PR_REVIEW_UI_DIR"] else { return }
        let root = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let savedTheme = DockThemeRuntime.current
        defer { DockThemeRuntime.current = savedTheme; DockThemeRuntime.revision &+= 1 }
        let record = try #require(PullRequestCenterAPI().parse([
            "number": 1, "node_id": "PR", "title": "Handle empty input", "state": "open",
            "user": ["login": "author"], "head": ["sha": String(repeating: "a", count: 40)],
        ], repository: GitHubReferenceParser.repository("owner/repo")!, localPath: ""))
        let patch = "@@ -1,3 +1,3 @@\n func title(_ value: String) -> String {\n-    value\n+    value.isEmpty ? \"Untitled\" : value\n }"
        let fixturePath = "/tmp/pr-review-ui-" + UUID().uuidString
        let document = DiffDocument(path: "Sources/Title.swift", patch: patch)
        let target = GitHubInlineCommentTarget(path: document.path, line: 2, side: "RIGHT", revision: record.headRevision!)
        let model = PullRequestReviewModel(client: GitHubClient(transport: BatchReviewTransport(.accepted)))
        await model.refresh(record)
        model.inlineDrafts[target.id] = "Could we also handle **whitespace-only** titles?"
        #expect(model.stageInline(target, record: record))
        model.draft = "The recovery path looks good. One edge case to check before merging."
        for theme: DockThemeID in [.clean, .island, .glass, .mono] {
            DockThemeRuntime.current = theme
            DockThemeRuntime.revision &+= 1
            for width in [352.0, 560.0] {
                try await capture(
                    PullRequestReviewView(model: model, record: record, viewer: "reviewer", onChanged: {}, onReviewCode: {}),
                    url: root.appendingPathComponent("review-\(theme.rawValue)-\(Int(width)).png"), width: width, height: 680)
                let editorTarget = GitHubInlineCommentTarget(path: document.path, line: 1, side: "RIGHT", revision: record.headRevision!)
                model.inlineDrafts[editorTarget.id] = "Should this also normalize the display name?"
                try await capture(
                    SharedDiffView(patch: patch, path: document.path, onComment: { _ in }, projectPath: fixturePath,
                        reviewAccessory: AnyView(PullRequestInlineReview(model: model, record: record, document: document,
                            target: .constant(editorTarget)))),
                    url: root.appendingPathComponent("inline-\(theme.rawValue)-\(Int(width)).png"), width: width, height: 620)
            }
            try await capture(
                SharedDiffView(patch: patch, path: document.path, onComment: { _ in }, projectPath: fixturePath, expandedPresentation: true,
                    reviewAccessory: AnyView(PullRequestInlineReview(model: model, record: record, document: document,
                        target: .constant(target)))),
                url: root.appendingPathComponent("inline-expanded-\(theme.rawValue).png"), width: 900, height: 560)
        }
    }

    private func capture<V: View>(_ view: V, url: URL, width: CGFloat, height: CGFloat) async throws {
        let host = NSHostingView(rootView: view.frame(width: width, height: height)
            .background(Color.dockCanvas).dockThemedRoot())
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        for _ in 0..<4 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(80))
        }
        if width == 352 && url.lastPathComponent == "inline-island-352.png" {
            func inspect(_ view: NSView) {
                if let scroll = view as? NSScrollView, scroll.documentView is NSTextView {
                    if scroll.verticalRulerView != nil {
                        #expect(scroll.contentView.bounds.minX == -scroll.contentView.contentInsets.left)
                    }
                }
                for child in view.subviews { inspect(child) }
            }
            inspect(host)
        }
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }
}
