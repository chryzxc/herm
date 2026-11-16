import Foundation
import Testing

@testable import Herm

@MainActor
struct SidebarProjectionSharingReproductionTests {
    @Test func registryDoesNotRetainSidebar() throws {
        let suite = "SidebarProjectionLifetime.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = DockModel(defaults: defaults)
        defer { model.shutdown() }
        let control = ControlCenterModel()
        let store = WorkspaceStore(
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).json"))
        weak var first: SessionNavSidebarModel?
        do {
            let sidebar = SessionNavSidebarModel.shared(model: model, control: control, store: store)
            first = sidebar
            #expect(first != nil)
        }
        #expect(first == nil)
        let replacement = SessionNavSidebarModel.shared(model: model, control: control, store: store)
        #expect(first !== replacement)
    }

    @Test func badgeAndSplitTabsShareOneSidebarProjection() throws {
        let suite = "SidebarProjectionSharing.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = DockModel(defaults: defaults)
        defer { model.shutdown() }
        let control = ControlCenterModel()
        let store = WorkspaceStore(
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).json"))
        let badge = ChatRailActivityModel(
            model: model, control: control, store: store,
            seenStore: SidebarSessionSeenStore(defaults: defaults))
        let tabs = SessionPaneTabStatusModel()
        tabs.bind(model: model, control: control, store: store, panes: SessionPaneStore.shared)

        // Observe existing private ownership without adding production test hooks.
        let badgeProjection = try #require(
            Mirror(reflecting: badge).children.first { $0.label == "sidebar" }?.value
                as? SessionNavSidebarModel)
        let tabsStorage = try #require(
            Mirror(reflecting: tabs).children.first { $0.label == "sidebar" }?.value)
        let tabsProjection = try #require(
            Mirror(reflecting: tabsStorage).children.first?.value as? SessionNavSidebarModel)
        #expect(
            ObjectIdentifier(badgeProjection) == ObjectIdentifier(tabsProjection),
            "One workspace currently creates independent sidebar subscribers for badge and split tabs")
    }
}
