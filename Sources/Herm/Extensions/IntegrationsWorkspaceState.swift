import Combine
import Foundation

enum IntegrationsCategory: String, CaseIterable, Identifiable {
    case messaging, skills, tools, connectors, plugins, mcp

    var id: String { rawValue }
    var title: String {
        switch self {
        case .messaging: "Messaging"
        case .skills: "Skills"
        case .tools: "Tools"
        case .connectors: "Connectors"
        case .plugins: "Plugins"
        case .mcp: "MCP servers"
        }
    }
    var purpose: String {
        switch self {
        case .skills: "Instructions that teach your agent how to handle specific tasks."
        case .plugins: "Extensions that add capabilities to Hermes Agent."
        case .tools: "Choose the toolsets your agent can use in this profile."
        case .connectors: "Connect your accounts and manage access to external services."
        case .mcp: "Connect external tools and data through MCP servers."
        case .messaging: "Set up the channels where people can reach your agent."
        }
    }
    var section: WorkflowIntegrationSection? {
        switch self {
        case .messaging: nil
        case .skills: .skills
        case .tools: .tools
        case .connectors: .connectors
        case .plugins: .plugins
        case .mcp: .mcp
        }
    }
    var icon: Ph {
        switch self {
        case .messaging: .paperPlaneTilt
        case .skills: .bookOpen
        case .tools: .wrench
        case .connectors: .plugsConnected
        case .plugins: .puzzlePiece
        case .mcp: .plugs
        }
    }
}

enum IntegrationStatusFilter: String, CaseIterable, Identifiable {
    case all, enabled, disabled, updates, needsSetup

    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "All statuses"
        case .enabled: "Enabled"
        case .disabled: "Disabled"
        case .updates: "Updates available"
        case .needsSetup: "Needs attention"
        }
    }

    func includes(enabled: Bool?, tone: DockStatusTone?, update: Bool) -> Bool {
        switch self {
        case .all: true
        case .enabled: enabled == true
        case .disabled: enabled == false
        case .updates: update
        case .needsSetup: tone == .attention
        }
    }
}

struct IntegrationsBrowsingState: Equatable {
    var search = ""
    var statusFilter = IntegrationStatusFilter.all
    var selection: String?
    var discover = false
    var pluginCategory = ""
    var byStars = true
    var showsDetail = false
}

/// Disposable browsing state. Hermes data stays in the existing feature models;
/// secure editor input stays in its view and is never saved here.
@MainActor
final class IntegrationsWorkspaceState: ObservableObject {
    let workflow: WorkflowIntegrationModel
    let messaging: MessagingPlatformsModel
    private let store: WorkspaceStore
    @Published private(set) var category: IntegrationsCategory
    @Published private(set) var profileID: String?
    @Published var profiles: [BotSummary] = []
    @Published var browsing: [IntegrationsCategory: IntegrationsBrowsingState] = [:]
    @Published var isDirty = false
    @Published var showsLeaveConfirmation = false
    @Published private(set) var discardRevision = 0
    private var pendingNavigation: (() -> Void)?
    private var subscriptions = Set<AnyCancellable>()

    init(client: HermesRPCClientProtocol, store: WorkspaceStore) {
        self.store = store
        category = store.lastIntegrationsCategory
        workflow = WorkflowIntegrationModel(client: client, profileID: nil)
        messaging = MessagingPlatformsModel(client: client)
        workflow.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        messaging.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
    }

    var currentBrowsing: IntegrationsBrowsingState {
        get { browsing[category] ?? IntegrationsBrowsingState() }
        set { browsing[category] = newValue }
    }
    var busy: Bool { category == .messaging ? messaging.busy || messaging.loading : workflow.busy }
    var navigationLocked: Bool { isDirty || busy }
    var scopeTitle: String {
        category == .connectors ? "Account connections" : profileName
    }
    var profileName: String {
        guard let profileID else { return "Launch profile" }
        return profiles.first { $0.id == profileID }?.name ?? profileID
    }
    var status: String {
        if isDirty { return "Save or discard changes before changing this view." }
        if category == .messaging {
            if let error = messaging.error {
                return messaging.isStale && messaging.hasLoaded ? "Displayed platforms may be stale. \(error)" : error
            }
            return messaging.loading
                ? "Reading messaging platforms…" : messaging.notice ?? "Configure messaging for \(profileName)."
        }
        if busy { return "Reading \(category.title.lowercased())…" }
        let message = category.section.map { workflow.sectionStatus($0) } ?? ""
        return message.isEmpty
            ? (category == .connectors
                ? "Connections and access for your account."
                : "Configure \(category.title.lowercased()) for \(profileName).")
            : message
    }
    func count(_ category: IntegrationsCategory) -> Int? {
        if category == .messaging { return messaging.hasLoaded ? messaging.platforms.count : nil }
        guard let section = category.section, workflow.loadedSections.contains(section) else { return nil }
        switch category {
        case .messaging: return nil
        case .skills: return workflow.skills.count
        case .tools: return workflow.toolsets.count
        case .connectors: return workflow.connectors.count
        case .plugins: return workflow.plugins.count
        case .mcp: return workflow.servers.filter(\.installed).count
        }
    }
    func selectCategory(_ value: IntegrationsCategory) {
        guard !navigationLocked, value != category else { return }
        category = value
        store.selectIntegrationsCategory(value)
    }
    func load(force: Bool = false) async {
        if category == .messaging {
            if force || !messaging.hasLoaded { await messaging.load(profileID: profileID) }
        } else if let section = category.section {
            if force {
                await workflow.refresh(section: section)
                if category == .plugins, currentBrowsing.discover { await workflow.loadCatalog(force: true) }
            } else {
                await workflow.load(section)
            }
        }
    }
    func useProfile(_ value: String?) async {
        guard !navigationLocked, value != profileID else { return }
        profileID = value
        browsing = [:]
        discardChanges()
        messaging.invalidate()
        // Switching while Messaging is selected must not refresh all workflow categories.
        workflow.resetProfile(value)
        await load()
    }
    func requestNavigation(_ action: @escaping () -> Void) {
        guard !busy else { return }
        guard isDirty else {
            action()
            return
        }
        pendingNavigation = action
        showsLeaveConfirmation = true
    }
    func keepEditing() {
        pendingNavigation = nil
        showsLeaveConfirmation = false
    }
    func discardAndLeave() {
        let action = pendingNavigation
        pendingNavigation = nil
        showsLeaveConfirmation = false
        discardChanges()
        action?()
    }
    func discardChanges() {
        discardRevision += 1
        isDirty = false
    }
    func close() {
        messaging.invalidateReads()
        messaging.cancelQR()
        workflow.cancelActiveReads()
        Task { await workflow.cancelOAuth() }
    }
}
