import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Native panel placement is owned by AppKit, while this state lets the
/// SwiftUI surface match its silhouette without resetting conversation state.
final class DockPanelPresentation: ObservableObject {
    @Published var quotaRequest = 0
    @Published var kanbanRequest = 0
    @Published var settingsRequest = 0
    @Published var isEdgeAttached = false
    /// Drives the notch-style grow/shrink of the edge-attached panel: false is the collapsed notch shape.
    @Published var isRevealed = true
    var collapsedSize = CGSize(width: 66, height: 96)
    /// Vertical offset (SwiftUI, down is positive) from the panel's center to the notch's,
    /// nonzero when the panel is clamped to the screen but the notch sits nearer an edge.
    var collapsedOffsetY: CGFloat = 0
    @Published var edgeSide: EdgeDockSide = .right
    /// Clearance inside the edge silhouette; the top drop-down clears the menu bar and its shoulders.
    @Published var edgeInsets = EdgeDockLayout.insets(for: .right)
    @Published var compactHeight: CGFloat = 720
    @Published var compactWidth: CGFloat = .greatestFiniteMagnitude
    @Published var availableWidth: CGFloat = .greatestFiniteMagnitude
    /// Owned by the panel controller; the view mirrors it so the layout always
    /// matches the window, including when the panel reopens in fullscreen.
    @Published var isFullscreen = false
    /// The notch's state, which the top drop-down shows in its menu-bar band.
    var islandStatus: EdgeNotchState?
    var openIslandTask: (EdgeNotchTask) -> Void = { _ in }
}

enum SessionNavigationSelection: Equatable {
    case session(String)
    case task(UUID)
    case global(ControlTab)
    case artifacts
    case bots
    case pullRequests
    case issues
}

@MainActor
final class SessionNavigationSelectionState: ObservableObject {
    @Published private(set) var selection: SessionNavigationSelection?

    func clear() { selection = nil }
    func selectSession(_ id: String) { selection = .session(id) }
    func selectTask(_ id: UUID) { selection = .task(id) }
    func selectGlobal(_ tab: ControlTab) { selection = .global(tab) }
    func selectArtifacts() { selection = .artifacts }
    func selectBots() { selection = .bots }
    func selectPullRequests() { selection = .pullRequests }
    func selectIssues() { selection = .issues }

    func isTaskSelected(_ id: UUID, sessionID: String? = nil) -> Bool {
        if case .task(id) = selection { return true }
        return false
    }

    func isSessionSelected(_ id: String) -> Bool {
        if case .session(id) = selection { return true }
        return false
    }

    func isGlobalSelected(_ tab: ControlTab) -> Bool {
        if case .global(tab) = selection { return true }
        return false
    }
}

/// Presentation state owned by the left navigation rail, rather than a
/// particular split-view host. Global destinations replace their trailing
/// content host, so keeping this state here lets the rail retain its expanded
/// sections and local selection while the user moves between pages.
@MainActor
final class SessionNavigationState: ObservableObject {
    private(set) var integrationsWorkspace: IntegrationsWorkspaceState?

    func integrations(client: HermesRPCClientProtocol, store: WorkspaceStore) -> IntegrationsWorkspaceState {
        if let integrationsWorkspace { return integrationsWorkspace }
        let state = IntegrationsWorkspaceState(client: client, store: store)
        integrationsWorkspace = state
        return state
    }

    let selection = SessionNavigationSelectionState()
    @Published var showsAllConversations = false
    @Published var selectedTaskID: UUID?
    @Published var selectedSessionID: String?
    @Published var areConversationsExpanded = true
    @Published var arePinnedExpanded = true
    /// User-chosen order of the rail's sections; a local preference.
    @Published private(set) var sectionOrder: [SessionRailSection] = SessionRailSection.stored()
    @Published private(set) var selectedGitHubSection: GitHubWorkspaceSection = .pullRequests
    var hasRequestedSessionIndex = false

    var selectedProjectSessionID: String? {
        guard case .session = selection.selection else { return nil }
        return selectedSessionID
    }

    func moveSection(_ section: SessionRailSection, before target: SessionRailSection?) {
        guard section != target, let from = sectionOrder.firstIndex(of: section) else { return }
        var order = sectionOrder
        order.remove(at: from)
        order.insert(section, at: target.flatMap { order.firstIndex(of: $0) } ?? order.endIndex)
        sectionOrder = order
        UserDefaults.standard.set(order.map(\.rawValue), forKey: SessionRailSection.storageKey)
    }

    func selectSession(_ id: String) {
        selection.selectSession(id)
        selectedTaskID = nil
        selectedSessionID = id
    }

    /// Route every callback that opens an existing or newly resolved session
    /// through the same owner so the prior task/global destination cannot
    /// remain selected alongside the conversation.
    func openSession(_ id: String) {
        selectSession(id)
    }

    func openBotChat(sessionID: String) {
        openSession(sessionID)
    }

    func openProjectSession(sessionID: String) {
        openSession(sessionID)
    }

    func openPullRequestChat(sessionID: String?) {
        if let sessionID {
            openSession(sessionID)
        } else {
            clearSelection()
        }
    }

    func synchronizeActiveSession(_ sessionID: String?) {
        if let sessionID, !sessionID.isEmpty {
            openSession(sessionID)
        }
    }

    func openIssueChat(sessionID: String?) {
        openPullRequestChat(sessionID: sessionID)
    }

    func beginProjectChat(sessionID: String? = nil) {
        if let sessionID {
            openSession(sessionID)
        } else {
            beginNewConversation()
        }
    }

    func beginNewConversation() {
        clearSelection()
    }

    func clearSelection() {
        selection.clear()
        selectedTaskID = nil
        selectedSessionID = nil
    }

    func selectTask(_ id: UUID) {
        selection.selectTask(id)
        selectedSessionID = nil
        selectedTaskID = id
    }

    func selectGlobal(_ tab: ControlTab) {
        selection.selectGlobal(tab)
        selectedTaskID = nil
        selectedSessionID = nil
    }

    func selectArtifacts() {
        selection.selectArtifacts()
        selectedTaskID = nil
        selectedSessionID = nil
    }

    func selectBots() {
        selection.selectBots()
        selectedTaskID = nil
        selectedSessionID = nil
    }

    func selectPullRequests() {
        selectedGitHubSection = .pullRequests
        selection.selectPullRequests()
        selectedTaskID = nil
        selectedSessionID = nil
    }

    func selectGitHubRepositories() {
        selectPullRequests()
        selectedGitHubSection = .repositories
    }

    func selectIssues() {
        selectedGitHubSection = .issues
        selection.selectIssues()
        selectedTaskID = nil
        selectedSessionID = nil
    }
}

/// A rail section whose header can be dragged to swap places with another.
enum SessionRailSection: String, CaseIterable, Codable, Transferable {
    case pinned, recents, projects

    static let storageKey = "herm.sessions.sectionOrder"
    static let pasteboardType = NSPasteboard.PasteboardType("io.github.chryzxc.Herm.session-rail-section")

    static func stored(_ defaults: UserDefaults = .standard) -> [SessionRailSection] {
        let saved = (defaults.stringArray(forKey: storageKey) ?? []).compactMap(SessionRailSection.init)
        return saved + allCases.filter { !saved.contains($0) }
    }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: UTType(exportedAs: pasteboardType.rawValue, conformingTo: .data))
    }
}

/// Makes a section header draggable and a drop target that reorders the rail.
struct SessionRailSectionReorder: ViewModifier {
    let section: SessionRailSection
    @ObservedObject var state: SessionNavigationState
    @State private var isTargeted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .draggable(section) { Text(section.rawValue.capitalized).dockPill().dockPadding(6) }
            // The hovered section slides down and leaves a slot for the dragged one.
            .dockPadding(.top, isTargeted ? 30 : 0)
            .overlay(alignment: .top) {
                if isTargeted {
                    RoundedRectangle(cornerRadius: DockControlMetrics.cornerRadius, style: .continuous)
                        .fill(Color.dockAccent.opacity(0.18))
                        .frame(height: 26)
                        .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .bottom)))
                }
            }
            // Last, so the drop area grows with the gap; inside it the header would slide out from under the cursor and flicker.
            .onDrop(
                of: [SessionRailSection.pasteboardType.rawValue],
                delegate: SessionRailSectionDropDelegate(section: section, state: state, isTargeted: $isTargeted)
            )
            .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.85), value: isTargeted)
    }
}

extension View {
    func sessionRailReorder(_ section: SessionRailSection, state: SessionNavigationState) -> some View {
        modifier(SessionRailSectionReorder(section: section, state: state))
    }
}

struct SessionRailSectionDropDelegate: DropDelegate {
    let section: SessionRailSection?
    let state: SessionNavigationState
    @Binding var isTargeted: Bool

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [SessionRailSection.pasteboardType.rawValue])
    }
    func dropEntered(info: DropInfo) { isTargeted = true }
    func dropExited(info: DropInfo) { isTargeted = false }
    /// `.copy`: a SwiftUI `.draggable` source offers only copy, so a move proposal is refused.
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .copy) }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        guard let provider = info.itemProviders(for: [SessionRailSection.pasteboardType.rawValue]).first else {
            return false
        }
        let target = section
        let state = state
        _ = provider.loadTransferable(type: SessionRailSection.self) { result in
            guard case .success(let dragged) = result else { return }
            Task { @MainActor in
                withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                    state.moveSection(dragged, before: target)
                }
            }
        }
        return true
    }
}

/// A zone after the last section: dropping a header here moves it to the end.
struct SessionRailEndDropZone: View {
    let state: SessionNavigationState
    @State private var isTargeted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        RoundedRectangle(cornerRadius: DockControlMetrics.cornerRadius, style: .continuous)
            .fill(isTargeted ? Color.dockAccent.opacity(0.18) : .clear)
            .frame(height: isTargeted ? 30 : 44)
            .dockPadding(.top, 4)
            .contentShape(Rectangle())
            .onDrop(
                of: [SessionRailSection.pasteboardType.rawValue],
                delegate: SessionRailSectionDropDelegate(section: nil, state: state, isTargeted: $isTargeted)
            )
            .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.85), value: isTargeted)
    }
}
