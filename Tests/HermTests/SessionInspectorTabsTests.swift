import AppKit
import SwiftUI
import Testing

@testable import Herm

@MainActor
struct SessionInspectorTabsTests {
    @Test func closingEverySectionLeavesNoForcedTab() throws {
        let sections = SessionInspector.Section.allCases
        let closed = sections.map(\.rawValue).joined(separator: "|")
        let presentation = InspectorPresentation(selected: "Browser", closed: closed)
        let restored = try JSONDecoder().decode(
            InspectorPresentation.self, from: JSONEncoder().encode(presentation))
        #expect(
            SessionInspector.Section.open(
                visible: sections, closed: restored.closed, browserOpen: false, simulators: []
            ).isEmpty)
    }

    @Test func reopeningOneSectionReturnsOnlyThatTab() {
        let sections = SessionInspector.Section.allCases
        for section in sections {
            let closed = sections.filter { $0 != section }.map(\.rawValue).joined(separator: "|")
            #expect(
                SessionInspector.Section.open(
                    visible: sections, closed: closed, browserOpen: section == .browser,
                    simulators: [section.rawValue]) == [section])
        }
    }

    @Test func browserAndSimulatorsFollowTheirOwnOpenState() {
        #expect(
            SessionInspector.Section.open(
                visible: [.browser, .iosSimulator, .androidEmulator], closed: "",
                browserOpen: false, simulators: []
            ).isEmpty)
        #expect(
            SessionInspector.Section.open(
                visible: [.timeline], closed: "Browser", browserOpen: true,
                simulators: ["iOS Simulator"]) == [.timeline])
    }

    @Test func renderEmptyPanel() async throws {
        guard let directory = ProcessInfo.processInfo.environment["HERM_INSPECTOR_UI_DIR"] else { return }
        let root = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = DockThemeStore.shared
        let previous = DockThemeRuntime.current
        let appearance = NSApplication.shared.appearance
        defer {
            DockThemeRuntime.current = previous
            DockThemeRuntime.revision &+= 1
            NSApplication.shared.appearance = appearance
        }
        for theme: DockThemeID in [.clean, .island, .glass, .mono, .eInk] {
            DockThemeRuntime.current = theme
            DockThemeRuntime.revision &+= 1
            NSApplication.shared.appearance = NSAppearance(
                named: [.clean, .eInk].contains(theme) ? .aqua : .darkAqua)
            for width in [300.0, 760.0] {
                let host = NSHostingView(
                    rootView: SessionInspectorEmptyView(sections: [.browser, .terminal], onOpen: { _ in })
                        .frame(width: width, height: 660).dockThemedRoot())
                host.frame = NSRect(x: 0, y: 0, width: width, height: 660)
                host.layoutSubtreeIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try #require(bitmap.representation(using: .png, properties: [:])).write(
                    to: root.appendingPathComponent("inspector-empty-\(theme.rawValue)-\(Int(width)).png"))
            }
        }
    }
}
