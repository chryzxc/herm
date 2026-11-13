import AppKit
import SwiftUI
import Testing

@testable import Herm

@MainActor
struct RepositoryStashLayoutTests {
    @Test func expandedStashReservesRoomForDiffAndFollowingSection() {
        let patch = "@@ -1,40 +1,40 @@\n" + (0..<40).map { " line \($0)" }.joined(separator: "\n")
        let view = RepositoryStashDiff(patch: patch, reference: "stash@{0}")
            .frame(width: 320)
            .fixedSize(horizontal: false, vertical: true)
        let host = NSHostingView(rootView: view)
        #expect(host.fittingSize.height >= 520)
    }

    @Test func renderExpandedStashDiff() throws {
        guard let directory = ProcessInfo.processInfo.environment["HERM_STASH_SNAPSHOT_DIR"] else { return }
        let patch = "@@ -1,40 +1,40 @@\n" + (0..<40).map { " line \($0)" }.joined(separator: "\n")
        for width: CGFloat in [320, 760] {
            let view = VStack(alignment: .leading, spacing: 8) {
                Text("Stash")
                Text("stash@{0} · Saved changes")
                HStack {
                    Text("Apply")
                    Text("Pop")
                    Text("Delete…")
                }
                RepositoryStashDiff(patch: patch, reference: "stash@{0}")
                Text("Graph")
            }
            .padding(12)
            .frame(width: width)
            .fixedSize(horizontal: false, vertical: true)
            .background(Color.dockCanvas)
            .dockThemedRoot()
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            window.orderFrontRegardless()
            defer { window.orderOut(nil) }
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("stash-\(Int(width)).png"))
        }
    }
}
