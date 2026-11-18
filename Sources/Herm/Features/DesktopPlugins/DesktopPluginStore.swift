import Foundation

/// The Desktop plugins on disk. Every installed plugin whose page runs in Herm is offered in More
/// destinations. Hermes owns the plugins; this is only a projection of the folder.
@MainActor
final class DesktopPluginStore: ObservableObject {
    static let shared = DesktopPluginStore()

    @Published private(set) var plugins: [HermesDesktopPlugin] = [] {
        didSet {
            byID = Dictionary(plugins.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            byFolded = Dictionary(plugins.map { ($0.id.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        }
    }
    private var byID: [String: HermesDesktopPlugin] = [:]
    private var byFolded: [String: HermesDesktopPlugin] = [:]

    private let home: URL
    private var refreshing: Task<Void, Never>?

    init(home: URL = HermesDesktopPluginCatalog.defaultHome()) {
        self.home = home
    }

    /// Installed plugins whose page Herm can open, in name order.
    var pages: [HermesDesktopPlugin] { plugins.filter { $0.compatibility == .runsInHerm } }

    func plugin(_ id: String) -> HermesDesktopPlugin? { byID[id] }

    /// The plugin whose folder matches an agent package's id or name, ignoring case.
    func plugin(matching name: String) -> HermesDesktopPlugin? { byFolded[name.lowercased()] }

    /// Rescans off the main actor; overlapping calls share one scan.
    // ponytail: rereads every plugin.js on each app activation; key on folder mtimes if counts grow.
    func refresh() async {
        if let refreshing { return await refreshing.value }
        let home = home
        let task = Task {
            let found = await Task.detached(priority: .utility) {
                HermesDesktopPluginCatalog.scan(
                    roots: HermesDesktopPluginCatalog.roots(home: home),
                    supported: HermesDesktopPluginCatalog.supportedExports())
            }.value
            if found != plugins { plugins = found }
        }
        refreshing = task
        await task.value
        refreshing = nil
    }
}
