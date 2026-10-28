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
            for id in [
                "code", "command", "findings", "workflow", "comparison", "metrics", "timeline", "checklist",
                "dataset.chart", "dataset.area", "dataset.point", "dataset.table", "graph", "imageComparison",
            ] {
                let descriptor = try #require(RichFeatureRegistry.local.first { $0.id == id })
                let source = RichFeatureRegistry.exampleSurface(descriptor)
                var surface = try JSONDecoder().decode(RichSurface.self, from: Data(source.utf8))
                if id == "dataset.chart" {
                    surface.datasets = [
                        RichDataset(
                            id: "sales",
                            columns: [
                                .init(id: "month", title: "Month", type: .text),
                                .init(id: "sales", title: "Sales", type: .number, unit: "units"),
                                .init(id: "returns", title: "Returns", type: .number, unit: "units"),
                                .init(id: "orders", title: "Orders", type: .number, unit: "units"),
                            ],
                            rows: [
                                .init(id: "jan", values: ["January", "12", "3", "16"]),
                                .init(id: "feb", values: ["February", "18", "2", "21"]),
                            ])
                    ]
                    surface.blocks = [
                        RichBlock(
                            type: .chart, id: "chart",
                            payload: .chart(
                                .init(
                                    dataset: "sales", label: "month", series: ["sales", "returns", "orders"],
                                    style: "bar")))
                    ]
                    #expect(surface.validate())
                }
                for width: CGFloat in [280, 320, 800] {
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

    @MainActor @Test func denseChartKeepsLegendAndSelectedValuesWithinNarrowLayouts() async throws {
        let previous = DockThemeRuntime.current
        let revision = DockThemeRuntime.revision
        defer {
            DockThemeRuntime.current = previous
            DockThemeRuntime.revision = revision
        }
        let suite = "RichChartSpacing.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = RichArtifactPresentationState(key: "chart", store: WorkspacePresentationStore(defaults: defaults))
        state.snapshot.selected[RichSelectionIdentity.dataset("activity")] = "1"
        let dataset = RichDataset(
            id: "activity",
            columns: [
                .init(id: "day", title: "October day", type: .text),
                .init(id: "commits", title: "Commits across registered projects", type: .number),
                .init(id: "reviews", title: "Completed code reviews", type: .number),
            ],
            rows: (1...27).map { day in
                .init(id: String(day), values: [String(format: "%02d", day), String(day * 3), String(day)])
            })
        let directory = ProcessInfo.processInfo.environment["HERM_WORKFLOW_REVIEW_DIR"]
        if let directory {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }
        for theme in [DockThemeID.warmLight, .slate, .glass, .mono] {
            DockThemeRuntime.current = theme
            DockThemeRuntime.revision &+= 1
            for width: CGFloat in [280, 320, 800] {
                let host = NSHostingView(
                    rootView:
                        RichDatasetChartView(
                            dataset: dataset,
                            configuration: .init(
                                dataset: "activity", label: "day", series: ["commits", "reviews"], style: "bar"),
                            state: state
                        )
                        .scrollIndicators(.visible).dockFont(.body).padding(16).frame(width: width)
                        .background(Color.dockCanvas).dockThemedRoot())
                host.frame = NSRect(x: 0, y: 0, width: width, height: 600)
                let window = NSWindow(
                    contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = host
                window.orderFrontRegardless()
                defer { window.orderOut(nil) }
                host.layoutSubtreeIfNeeded()
                func showScrollbars(_ view: NSView) {
                    if let scroll = view as? NSScrollView {
                        scroll.scrollerStyle = .legacy
                        scroll.autohidesScrollers = false
                    }
                    for child in view.subviews { showScrollbars(child) }
                }
                showScrollbars(host)
                try await Task.sleep(for: .milliseconds(80))
                host.layoutSubtreeIfNeeded()
                #expect(host.fittingSize.width <= width + 1)
                #expect(host.fittingSize.height.isFinite && host.fittingSize.height > 0)
                if let directory {
                    host.frame.size.height = host.fittingSize.height
                    host.layoutSubtreeIfNeeded()
                    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let png = try #require(bitmap.representation(using: .png, properties: [:]))
                    try png.write(
                        to: URL(fileURLWithPath: directory)
                            .appendingPathComponent("\(theme.rawValue)-dense-chart-\(Int(width)).png"))
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
