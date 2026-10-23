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
  private let dataStore = WKWebsiteDataStore.nonPersistent()

  init(key: SessionBrowserKey) {
    self.key = key
    agent = AgentBrowser(key: key)
    primary = BrowserController(key: key, dataStore: dataStore)
  }

  func addTab() -> BrowserController {
    let tab = BrowserController(key: key, dataStore: dataStore)
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
  private var subscriptions: [AnyCancellable] = []
  private var activeKey: SessionBrowserKey?

  func workspace(for key: SessionBrowserKey) -> SessionBrowserWorkspace {
    if let existing = workspaces[key] { return existing }
    let workspace = SessionBrowserWorkspace(key: key)
    workspaces[key] = workspace
    workspace.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
      .store(in: &subscriptions)
    return workspace
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
