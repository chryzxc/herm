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
    @Published private var pageTitles: [UUID: String] = [:]
    private var titleSubscriptions: [UUID: AnyCancellable] = [:]
    /// WebKit tabs' persistent store, shared by the sessions of one Hermes profile like its agent
    /// Chrome, so signing in on one profile never reaches another's browser.
    let dataStore: WKWebsiteDataStore
    private static var dataStores: [String?: WKWebsiteDataStore] = [:]
    nonisolated private static let defaultDataStoreID = UUID(uuidString: "DA9890F2-CB88-46F5-9F29-97475D8B7B7B")!

    /// Every profile's ID starts like the default one's, so Sign Out of All Sites finds them all
    /// (and never the gateway sign-in store).
    nonisolated static func dataStoreID(for profileID: String?) -> UUID {
        guard let profileID else { return defaultDataStoreID }
        var bytes = [UInt8](SHA256.hash(data: Data(profileID.utf8)).prefix(16))
        bytes.replaceSubrange(0..<4, with: [0xDA, 0x98, 0x90, 0xF2])
        return NSUUID(uuidBytes: bytes) as UUID
    }

    nonisolated static func isDataStoreID(_ id: UUID) -> Bool {
        id.uuidString.hasPrefix(defaultDataStoreID.uuidString.prefix(8))
    }

    static func dataStore(for profileID: String?) -> WKWebsiteDataStore {
        if let existing = dataStores[profileID] { return existing }
        let store = WKWebsiteDataStore(forIdentifier: dataStoreID(for: profileID))
        dataStores[profileID] = store
        return store
    }

    static func clearSignIns() async {
        let identifiers = await WKWebsiteDataStore.allDataStoreIdentifiers
        for id in identifiers where isDataStoreID(id) {
            await WKWebsiteDataStore(forIdentifier: id).removeData(
                ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        }
        for store in dataStores.values {
            await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        }
    }

    init(key: SessionBrowserKey, agent: AgentBrowser? = nil) {
        self.key = key
        self.agent = agent ?? AgentBrowser(profileID: key.profileID)
        dataStore = Self.dataStore(for: key.profileID)
        primary = BrowserController(key: key, dataStore: dataStore)
        titleSubscriptions[primary.id] = primary.web.publisher(for: \.title)
            .combineLatest(self.agent.$state, self.agent.$pages, self.agent.$activeTargetID)
            .map { title, state, pages, target in
                let usesAgent = state == .starting || state == .running
                return usesAgent ? pages.first(where: { $0.id == target })?.title ?? "" : title ?? ""
            }
            .removeDuplicates()
            .sink { [weak self] title in
                guard let self else { return }
                pageTitles[primary.id] = title
            }
    }

    func addTab() -> BrowserController {
        let tab = BrowserController(key: key, dataStore: dataStore)
        let cookies = dataStore.httpCookieStore
        tab.prepareLoad = { [weak agent] url in await agent?.copySignIns(for: url, into: cookies) }
        tab.didLoad = { [weak agent] url in await agent?.receiveSignIns(for: url, from: cookies) }
        let id = tab.id
        titleSubscriptions[id] = tab.web.publisher(for: \.title)
            .map { $0 ?? "" }
            .removeDuplicates()
            .sink { [weak self] title in self?.pageTitles[id] = title }
        extras.append(tab)
        return tab
    }

    func closeTab(_ id: UUID) {
        titleSubscriptions.removeValue(forKey: id)?.cancel()
        pageTitles.removeValue(forKey: id)
        extras.first { $0.id == id }?.web.stopLoading()
        extras.removeAll { $0.id == id }
    }

    func tabTitle(for id: UUID? = nil, fallback: String = "Browser") -> String {
        let title = (pageTitles[id ?? primary.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty || title == "about:blank" || ["http", "https"].contains(URL(string: title)?.scheme)
            ? fallback : title
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

    /// Keep the current page when a chat link points somewhere else.
    /// Nil identifies the built-in Browser tab.
    func openLink(_ url: URL) -> UUID? {
        let primaryAddress =
            agent.isActive
            ? agent.pendingURL?.absoluteString
                ?? agent.pages.first(where: { $0.id == agent.activeTargetID })?.url ?? primary.address
            : primary.address
        if primaryAddress == url.absoluteString { return nil }
        if let tab = extras.first(where: { $0.address == url.absoluteString }) { return tab.id }
        if primaryAddress.isEmpty || primaryAddress == "about:blank" {
            open(url)
            return nil
        }
        let tab = addTab()
        tab.open(url)
        return tab.id
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

    func signOutAll() async {
        do {
            try await BrowserSignOutState.shared.reset {
                var failure: (any Error)?
                for agent in Array(self.agents.values) {
                    do { try await agent.clearSignIns() } catch { failure = failure ?? error }
                }
                await SessionBrowserWorkspace.clearSignIns()
                if let failure { throw failure }
            }
        } catch {
            DockActionErrorCenter.shared.report(
                "Browser sign-out incomplete",
                message: "Some sign-ins could not be cleared. Retry Sign Out of All Sites. "
                    + HermesDiagnosticsService.safeSummary(error.localizedDescription))
        }
    }

    func workspace(for key: SessionBrowserKey) -> SessionBrowserWorkspace {
        if let existing = workspaces[key] { return existing }
        let workspace = SessionBrowserWorkspace(key: key, agent: agent(for: key.profileID))
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

    private func agent(for profileID: String?) -> AgentBrowser {
        if let existing = agents[profileID] { return existing }
        let agent = AgentBrowser(profileID: profileID)
        agents[profileID] = agent
        return agent
    }

    func activate(model: DockModel, reconnect: Bool = false) {
        guard let key = model.browserSessionKey else {
            // A new chat has no session until its first turn starts: launch the profile's Chrome
            // now so Hermes' first browser call doesn't race the launch.
            let agent = agent(for: model.profileScopeID)
            agent.model = model
            if !agent.isActive { agent.start() } else if reconnect { agent.reconnectHermes() }
            return
        }
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

    @discardableResult
    func present(_ url: URL?, model: DockModel) -> UUID? {
        guard let key = model.browserSessionKey else {
            if let url { ExternalOpen.open(url) }
            return nil
        }
        activate(model: model)
        let tabID = url.flatMap { workspace(for: key).openLink($0) }
        presentation = key
        return tabID
    }
}
