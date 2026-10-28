import Combine
import CryptoKit
import WebKit

struct SessionBrowserKey: Hashable {
    let profileID: String?
    let sessionID: String

    var profileDirectory: String { Self.hash([profileID, sessionID]) }

    /// The agent Chrome's profile, shared by the Hermes profile's sessions.
    static func browserDirectory(profileID: String?) -> String { hash([profileID]) }

    private static func hash(_ identity: [String?]) -> String {
        SHA256.hash(data: try! JSONEncoder().encode(identity)).map { String(format: "%02x", $0) }.joined()
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

    init(key: SessionBrowserKey, agent: AgentBrowser? = nil) {
        self.key = key
        self.agent = agent ?? AgentBrowser(profileID: key.profileID)
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

    /// The closed Browser tab unloads its page. The agent Chrome is the profile's and keeps running.
    func suspend() {
        primary.web.stopLoading()
        primary.web.load(URLRequest(url: URL(string: "about:blank")!))
    }

    /// A tab, loaded page or pending link the user could lose. Without one, quitting loses nothing.
    var isInUse: Bool {
        let loaded = { (url: String?) in url.map { !$0.isEmpty && !$0.hasPrefix("about:") } ?? false }
        return !extras.isEmpty || loaded(primary.web.url?.absoluteString)
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
    private var agents: [String?: AgentBrowser] = [:]
    private var subscriptions: [SessionBrowserKey: AnyCancellable] = [:]
    private var activeKey: SessionBrowserKey?

    func workspace(for key: SessionBrowserKey) -> SessionBrowserWorkspace {
        if let existing = workspaces[key] { return existing }
        let agent = agents[key.profileID] ?? AgentBrowser(profileID: key.profileID)
        agents[key.profileID] = agent
        let workspace = SessionBrowserWorkspace(key: key, agent: agent)
        workspaces[key] = workspace
        subscriptions[key] = workspace.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        return workspace
    }

    /// Hermes deleted the session: its pages go; the profile's agent Chrome stays.
    func delete(_ key: SessionBrowserKey) {
        agents[key.profileID]?.forget(session: key.sessionID)
        remove(key)
    }

    /// Only dispose after Hermes confirms deletion; retained live pages otherwise belong to the user.
    func remove(_ key: SessionBrowserKey) {
        guard let workspace = workspaces.removeValue(forKey: key) else { return }
        subscriptions.removeValue(forKey: key)?.cancel()
        workspace.suspend()
        for tab in workspace.extras { workspace.closeTab(tab.id) }
        if presentation == key { presentation = nil }
        if activeKey == key { activeKey = nil }
        // The profile's last session went: quit its Chrome and disconnect Hermes.
        if !workspaces.keys.contains(where: { $0.profileID == key.profileID }) {
            agents.removeValue(forKey: key.profileID)?.stop()
        }
    }

    func activate(model: DockModel, reconnect: Bool = false) {
        guard let key = model.browserSessionKey else { return }
        // Create first, so releasing the previous session never quits the Chrome this one shares.
        let agent = workspace(for: key).agent
        if let activeKey, activeKey != key { releaseIfUnused(activeKey) }
        agent.model = model
        agent.show(session: key.sessionID)
        if !agent.isActive {
            agent.start()
        } else if reconnect || activeKey?.profileID != key.profileID {
            // Hermes holds one connection per profile; a session switch within it keeps that.
            agent.reconnectHermes()
        }
        activeKey = key
    }

    /// Selecting a session starts its profile's Chrome so Hermes' browser tools reach it.
    /// Leaving one that was never used drops its pages.
    func releaseIfUnused(_ key: SessionBrowserKey) {
        guard presentation != key, let workspace = workspaces[key], !workspace.isInUse else { return }
        remove(key)
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
