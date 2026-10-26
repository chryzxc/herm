import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Herm

struct RichWorkflowTests {
    @MainActor @Test func workflowLayoutsFitNarrowAndWideThemes() throws {
        let previous = DockThemeRuntime.current
        let revision = DockThemeRuntime.revision
        defer {
            DockThemeRuntime.current = previous
            DockThemeRuntime.revision = revision
        }
        let directory = ProcessInfo.processInfo.environment["HERM_WORKFLOW_REVIEW_DIR"]
        if let directory {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }
        for theme in [DockThemeID.warmLight, .slate, .glass, .mono] {
            DockThemeRuntime.current = theme
            DockThemeRuntime.revision &+= 1
            for id in ["code", "findings", "workflow", "comparison"] {
                let descriptor = try #require(RichFeatureRegistry.local.first { $0.id == id })
                let source = RichFeatureRegistry.exampleSurface(descriptor)
                let surface = try JSONDecoder().decode(RichSurface.self, from: Data(source.utf8))
                for width: CGFloat in [320, 800] {
                    let host = NSHostingView(
                        rootView: RichSurfaceView(surface: surface, source: source)
                            .padding(16).frame(width: width).dockThemedRoot())
                    host.frame = NSRect(x: 0, y: 0, width: width, height: 600)
                    host.layoutSubtreeIfNeeded()
                    #expect(host.fittingSize.height.isFinite && host.fittingSize.height > 0)
                    #expect(host.fittingSize.width <= width + 1)
                    if let directory {
                        host.frame.size.height = max(180, host.fittingSize.height)
                        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                        host.cacheDisplay(in: host.bounds, to: bitmap)
                        let png = try #require(bitmap.representation(using: .png, properties: [:]))
                        try png.write(
                            to: URL(fileURLWithPath: directory)
                                .appendingPathComponent("\(theme.rawValue)-\(id)-\(Int(width)).png"))
                    }
                }
            }
        }
    }

    @Test func workflowsRequireEvidenceForReportedOutcomes() {
        for status in [RichWorkflow.Item.Status.running, .passed, .failed, .blocked, .skipped] {
            #expect(!RichWorkflow(items: [.init(id: "a", title: "Check", status: status)]).validate())
            #expect(!RichWorkflow(items: [.init(id: "a", title: "Check", status: status, evidence: " \n")]).validate())
            #expect(
                RichWorkflow(items: [.init(id: "a", title: "Check", status: status, evidence: "Supplied log")])
                    .validate())
        }
        let proposed = RichWorkflow.Item(id: "a", title: "Review", status: .proposed)
        #expect(RichWorkflow(items: [proposed]).validate())
        #expect(!RichWorkflow(items: [proposed, proposed]).validate())
        #expect(!RichWorkflow(items: []).validate())
    }

    @Test func newFormatsRoundTripAndPreserveReadableDetails() throws {
        for id in ["code", "findings", "workflow"] {
            let descriptor = try #require(RichFeatureRegistry.local.first { $0.id == id })
            let source = RichFeatureRegistry.exampleSurface(descriptor)
            let surface = try JSONDecoder().decode(RichSurface.self, from: Data(source.utf8))
            #expect(surface.validate())
            #expect(try JSONDecoder().decode(RichSurface.self, from: JSONEncoder().encode(surface)) == surface)
            #expect(RichDocument("```herm-ui\n" + source + "\n```").segments == [.surface(surface, source: source)])
            #expect(
                surface.plainText.contains(
                    id == "code"
                        ? "swift test" : id == "findings" ? "Cover an unavailable response." : "Supplied build log"))
        }
    }

    @Test func malformedPayloadsFailClosed() {
        for block in [
            #"{"id":"a","type":"code","payload":{"code":""}}"#,
            #"{"id":"a","type":"workflow","payload":{"items":[{"id":"a","title":"Build","status":"passed"}]}}"#,
            #"{"id":"a","type":"workflow","payload":{"items":[{"id":"a","title":"Build","status":"invented"}]}}"#,
            #"{"id":"a","type":"findings","payload":{"items":[]}}"#,
            #"{"id":"a","type":"findings","payload":{"items":[{"id":"a","title":"Issue","severity":"critical","detail":""}]}}"#,
        ] {
            let source =
                #"{"version":2,"id":"test","title":"Test","fallback":"Readable","kind":"native","blocks":[\#(block)]}"#
            #expect(
                RichDocument("```herm-ui\n" + source + "\n```").segments == [.unavailable("Readable", source: source)])
        }
        #expect(!RichCode(code: String(repeating: "a", count: 65_537)).validate())
        #expect(!RichCode(code: " \n").validate())
    }
}
