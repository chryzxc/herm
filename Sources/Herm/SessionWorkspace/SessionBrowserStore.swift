import Combine
import CryptoKit
import WebKit

struct SessionBrowserKey: Hashable {
    let profileID: String?
    let sessionID: String

    var profileDirectory: String {
        let identity = try! JSONEncoder().encode([profileID, sessionID])
        return SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
    }
}

extension DockModel {
    var browserSessionKey: SessionBrowserKey? {
        navigationSessionID.map { SessionBrowserKey(profileID: profileScopeID, sessionID: $0) }
    }
}

/// Owns live pages independently of the inspector's SwiftUI lifetime.
@MainActor
final class SessionBrowserWorkspace: ObservableObject {
    let key: SessionBrowserKey
    let agent: AgentBrowser
    let primary: BrowserController
    @Published private(set) var extras: [BrowserController] = []
    /// WebKit tabs share one persistent store, so a sign-in carries across sessions like the agent browser's.
    static let dataStore = WKWebsiteDataStore(forIdentifier: UUID(uuidString: "DA9890F2-CB88-46F5-9F29-97475D8B7B7B")!)

    init(key: SessionBrowserKey) {
        self.key = key
        agent = AgentBrowser(key: key)
        primary = BrowserController(key: key, dataStore: Self.dataStore)
    }

    func addTab() -> BrowserController {
        let tab = BrowserController(key: key, dataStore: Self.dataStore)
        extras.append(tab)
        return tab
    }

    func closeTab(_ id: UUID) {
        extras.first { $0.id == id }?.web.stopLoading()
        extras.removeAll { $0.id == id }
    }

    /// The closed Browser tab: quit the agent's Chrome and unload the page; reopening restarts both.
    func suspend() {
        agent.stop()
        primary.web.stopLoading()
        primary.web.load(URLRequest(url: URL(string: "about:blank")!))
    }

    func open(_ url: URL) {
        primary.address = url.absoluteString
        if agent.isActive { agent.navigate(url) } else { primary.open(url) }
    }
}

@MainActor
final class SessionBrowserStore: ObservableObject {
    static let shared = SessionBrowserStore()
    @Published var presentation: SessionBrowserKey?
    private var workspaces: [SessionBrowserKey: SessionBrowserWorkspace] = [:]
    private var subscriptions: [SessionBrowserKey: AnyCancellable] = [:]
    private var activeKey: SessionBrowserKey?

    func workspace(for key: SessionBrowserKey) -> SessionBrowserWorkspace {
        if let existing = workspaces[key] { return existing }
        let workspace = SessionBrowserWorkspace(key: key)
        workspaces[key] = workspace
        subscriptions[key] = workspace.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        return workspace
    }

    /// Hermes deleted the session: its browser and its Chrome profile both go.
    func delete(_ key: SessionBrowserKey) {
        remove(key)
        AgentBrowser.removeProfile(key)
    }

    /// Only dispose after Hermes confirms deletion; retained live pages otherwise belong to the user.
    func remove(_ key: SessionBrowserKey) {
        guard let workspace = workspaces.removeValue(forKey: key) else { return }
        subscriptions.removeValue(forKey: key)?.cancel()
        workspace.suspend()
        for tab in workspace.extras { workspace.closeTab(tab.id) }
        if presentation == key { presentation = nil }
        if activeKey == key { activeKey = nil }
    }

    func activate(model: DockModel, reconnect: Bool = false) {
        guard let key = model.browserSessionKey else { return }
        let agent = workspace(for: key).agent
        agent.model = model
        if !agent.isActive {
            agent.start()
        } else if reconnect || activeKey != key {
            agent.reconnectHermes()
        }
        activeKey = key
    }

    func present(_ url: URL?, model: DockModel) {
        guard let key = model.browserSessionKey else {
            if let url { ExternalOpen.open(url) }
            return
        }
        activate(model: model)
        if let url { workspace(for: key).open(url) }
        presentation = key
    }
}
