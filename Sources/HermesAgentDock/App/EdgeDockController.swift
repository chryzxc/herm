import AppKit
import Combine
import SwiftUI

/// One native window morphs from the passive notch into the interactive workspace.
@MainActor
final class EdgeDockController: NSObject {
    let panel = DockPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private let model: DockModel
    private let controlCenter: ControlCenterModel
    private let openQuota: () -> Void
    private let openDock: () -> Void
    private let state = EdgeNotchState()
    private var notchHost: NSView?
    private var subscriptions = Set<AnyCancellable>()
    private var collapseTask: DispatchWorkItem?
    private var hovering = false
    private var dragging = false
    private var suppressClickUntil = Date.distantPast
    private var workspacePresented = false
    private var completedTaskIDs: Set<String>?
    private var latestToolID: String?
    private var latestToolComplete = false
    private var lastProgressAnnouncement = Date.distantPast
    private var displayID: NSNumber?
    private var fraction: CGFloat = 0.5
    private let defaults: UserDefaults

    init(model: DockModel, controlCenter: ControlCenterModel, defaults: UserDefaults = .standard, openQuota: @escaping () -> Void, openDock: @escaping () -> Void) {
        self.model = model
        self.controlCenter = controlCenter
        self.openQuota = openQuota
        self.defaults = defaults
        self.openDock = openDock
        super.init()
        state.side = EdgeDockSide(rawValue: defaults.string(forKey: "hermes.notch.side") ?? "") ?? .right
        fraction = defaults.object(forKey: "hermes.notch.position") as? Double ?? 0.5
        displayID = defaults.object(forKey: "hermes.notch.display") as? NSNumber
        panel.acceptsWorkspaceFocus = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        let host = EdgeDockHostingView(rootView: EdgeNotchView(state: state, controlCenter: controlCenter,
            onQuotaRequested: { [weak self] in self?.loadQuota() },
            onOpenQuota: { [weak self] in self?.openQuota() },
            openDock: { [weak self] in self?.openWorkspace() },
            onDrag: { [weak self] ended in self?.moveNotch(ended: ended) },
            onSideChange: { [weak self] side in
                guard let self else { return }
                self.state.side = side
                self.persistPlacement()
                self.position(animated: true)
            }))
        host.onHoverChanged = { [weak self] value in self?.hoverChanged(value) }
        host.sizingOptions = []
        notchHost = host
        panel.contentView = host
        panel.onCancel = { [weak self] in self?.setExpanded(false) }
        Publishers.CombineLatest3(model.$status, model.$hasUnreadResponse, model.$backgroundTasks)
            .receive(on: RunLoop.main)
            .sink { [weak self] status, unread, tasks in
                self?.refresh(status: status, unread: unread, tasks: tasks)
            }.store(in: &subscriptions)
        model.$activityPresentationRevision
            .throttle(for: .seconds(1), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in self?.refreshProgress() }
            .store(in: &subscriptions)
        model.$currentSessionTitle.combineLatest(model.$runtimeConfiguration)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in
                guard let self else { return }
                self.state.name = self.model.agentDisplayName
                self.updateDetail()
            }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.position(animated: false) }
            .store(in: &subscriptions)
        position(animated: false)
        panel.orderFrontRegardless()
    }

    var placement: EdgeDockPlacement? {
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber) == displayID
        } ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return nil }
        displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        return EdgeDockPlacement(side: state.side, fraction: fraction,
                                 screenFrame: screen.frame, visibleFrame: screen.visibleFrame)
    }

    func prepareForWorkspace() {
        collapseTask?.cancel()
        workspacePresented = true
        hovering = false
        panel.acceptsWorkspaceFocus = true
    }

    func restoreNotch() {
        workspacePresented = false
        panel.acceptsWorkspaceFocus = false
        panel.resignKey()
        state.expanded = false
        state.activity.backgroundCompleted = false
        state.activity.responseCompleted = false
        panel.contentView = notchHost
        notchHost?.alphaValue = 1
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            notchHost?.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.24
                notchHost?.animator().alphaValue = 1
            }
        }
        panel.hasShadow = false
        panel.onCancel = { [weak self] in self?.setExpanded(false) }
        position(animated: true)
        panel.orderFrontRegardless()
    }

    private func openWorkspace() {
        guard !dragging, Date() >= suppressClickUntil else { return }
        state.activity.backgroundCompleted = false
        state.activity.responseCompleted = false
        openDock()
    }

    private func refresh(status: HermesStatus, unread: Bool, tasks: [HermesBackgroundTask]) {
        let completed = Set(tasks.filter { $0.status == .completed }.map(\.id))
        let newCompletion = completedTaskIDs.map { !completed.subtracting($0).isEmpty } ?? false
        completedTaskIDs = completed
        let previous = state.activity
        let responseFinished = previous.status == .working && status == .idle
            && model.messages.last?.role == .hermes
        state.activity = EdgeNotchActivity(status: status, unread: unread,
            runningCount: tasks.filter { $0.status == .running }.count,
            backgroundCompleted: newCompletion || (previous.backgroundCompleted && !completed.isEmpty),
            responseCompleted: responseFinished || (previous.responseCompleted && status != .working))
        updateDetail()
        if state.activity.shouldAnnounce(after: previous) || newCompletion || responseFinished {
            announce()
        } else {
            position(animated: true)
        }
    }

    private func refreshProgress() {
        guard state.activity.working else { return }
        guard let tool = model.activeToolCalls.last else { return }
        let changed = tool.id != latestToolID || tool.isComplete != latestToolComplete
        latestToolID = tool.id
        latestToolComplete = tool.isComplete
        guard changed else { return }
        updateDetail()
        // Bound automatic expansions during rapid tool chains, while keeping
        // an already-open preview current. Token streaming never drives geometry.
        if Date().timeIntervalSince(lastProgressAnnouncement) >= 4 {
            lastProgressAnnouncement = Date()
            announce()
        }
    }

    private func loadQuota() {
        collapseTask?.cancel()
        controlCenter.bind(to: model)
        guard controlCenter.refreshState(for: "provider.quota")?.isRefreshing != true else { return }
        let lastRead = controlCenter.providerQuotas.map(\.updatedAt).max()
        if lastRead == nil || Date().timeIntervalSince(lastRead!) > 60 {
            controlCenter.refreshProviderQuota()
        }
    }

    private func updateDetail() {
        state.sessionTitle = model.currentSessionTitle ?? (model.sessionID == nil ? "Hermes Dock" : "Current session")
        state.updateTitle = state.activity.title
        if state.activity.attention {
            state.detail = "Open this session to review and respond"
        } else if state.activity.working, let tool = model.activeToolCalls.last {
            state.detail = "\(tool.isComplete ? "Completed" : "Running"): \(tool.name)"
        } else if state.activity.backgroundCompleted {
            state.detail = "A background task finished. Open this session to review its result."
        } else if let response = model.messages.last(where: { $0.role == .hermes }), !response.text.isEmpty {
            state.detail = String(response.text.prefix(180))
            if state.activity.quiet { state.updateTitle = "Latest update" }
        } else if state.activity.working {
            state.detail = "Working on this session’s request"
        } else {
            state.updateTitle = "No activity yet"
            state.detail = model.sessionID == nil ? "Choose a session to see its activity." : "Updates will appear as work begins in this session."
        }
    }

    private func announce() {
        guard !workspacePresented, !dragging else { return }
        if !hovering { state.showingAnnouncement = true }
        state.expanded = true
        position(animated: true)
        scheduleCollapse(after: 6)
    }

    private func hoverChanged(_ value: Bool) {
        guard !workspacePresented, !dragging else { return }
        hovering = value
        collapseTask?.cancel()
        if value {
            state.showingAnnouncement = false
            setExpanded(true)
        }
        else { scheduleCollapse(after: 0.4) }
    }

    private func scheduleCollapse(after delay: TimeInterval) {
        collapseTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            guard let self, !self.hovering, !self.dragging, !self.workspacePresented,
                  !self.panel.frame.contains(NSEvent.mouseLocation) else { return }
            guard self.panel.attachedSheet == nil, self.panel.childWindows?.isEmpty != false else {
                self.scheduleCollapse(after: 0.4)
                return
            }
            self.state.showingAnnouncement = false
            self.state.activity.backgroundCompleted = false
            self.state.activity.responseCompleted = false
            self.setExpanded(false)
        }
        collapseTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: task)
    }

    private func setExpanded(_ expanded: Bool) {
        guard !workspacePresented else { return }
        collapseTask?.cancel()
        state.expanded = expanded
        updateDetail()
        position(animated: true)
    }

    private func moveNotch(ended: Bool) {
        guard !workspacePresented else { return }
        collapseTask?.cancel()
        dragging = !ended
        hovering = false
        state.expanded = false
        let point = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) {
            let location = EdgeDockPlacement.dragged(to: point, screenFrame: screen.frame, visibleFrame: screen.visibleFrame)
            displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            state.side = location.side
            fraction = location.fraction
            position(animated: false)
        }
        if ended {
            suppressClickUntil = Date().addingTimeInterval(0.4)
            persistPlacement()
        }
    }

    private func persistPlacement() {
        defaults.set(state.side.rawValue, forKey: "hermes.notch.side")
        defaults.set(fraction, forKey: "hermes.notch.position")
        defaults.set(displayID, forKey: "hermes.notch.display")
    }

    private func position(animated: Bool) {
        guard !workspacePresented, let placement else { return }
        let target = placement.frame(width: state.expanded ? 368 : state.railWidth,
                                     height: state.expanded ? max(300, state.railHeight) : state.railHeight)
        guard !panel.frame.equalTo(target) else { return }
        if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                let expanding = target.width > panel.frame.width
                context.duration = expanding ? EdgeDockMotion.revealDuration : EdgeDockMotion.collapseDuration
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
                panel.animator().setFrame(target, display: true)
            }
        } else {
            panel.setFrame(target, display: true)
        }
    }

    static func frame(screenFrame: NSRect, visibleFrame: NSRect, expanded: Bool, railHeight: CGFloat = 136) -> NSRect {
        EdgeDockPlacement(screenFrame: screenFrame, visibleFrame: visibleFrame)
            .frame(width: expanded ? 368 : 72, height: expanded ? max(200, railHeight) : railHeight)
    }
}

struct EdgeNotchActivity: Equatable {
    var status: HermesStatus = .idle
    var unread = false
    var runningCount = 0
    var backgroundCompleted = false
    var responseCompleted = false
    var hasUpdate: Bool { unread || backgroundCompleted || responseCompleted }
    var quiet: Bool { !working && !attention && !hasUpdate && status == .idle }

    func shouldAnnounce(after previous: Self) -> Bool {
        (working && !previous.working) || runningCount != previous.runningCount
            || (unread && !previous.unread) || (attention && status != previous.status)
    }

    var working: Bool { status == .working || runningCount > 0 }
    var attention: Bool { status == .needsApproval || status == .needsClarification }
    var title: String {
        if attention { return status.title }
        if unread { return "New response" }
        if backgroundCompleted { return "Background task completed" }
        if responseCompleted { return "Response completed" }
        if runningCount > 0 { return "\(runningCount) background \(runningCount == 1 ? "task" : "tasks") running" }
        if status == .working || status == .offline { return status.title }
        return "Open Dock"
    }
    var symbol: String {
        if attention { return status.icon }
        if unread { return "bubble.left.fill" }
        if backgroundCompleted || responseCompleted { return "checkmark" }
        return status == .offline ? "wifi.slash" : "rectangle.righthalf.inset.filled"
    }
}

@MainActor
final class EdgeNotchState: ObservableObject {
    @Published var expanded = false
    @Published var side: EdgeDockSide = .right
    @Published var activity = EdgeNotchActivity()
    @Published var name = "Hermes"
    @Published var sessionTitle = "Hermes Dock"
    @Published var updateTitle = "No activity yet"
    @Published var showsQuota = false
    @Published var showingAnnouncement = false
    var displaysQuota: Bool { showsQuota && !showingAnnouncement }
    @Published var detail = "Open your conversation"
    var showsSeparateWork: Bool { activity.working && (activity.hasUpdate || activity.attention) }
    var isQuiet: Bool { activity.quiet && !expanded }
    var railWidth: CGFloat { expanded ? 72 : 44 }
    var railHeight: CGFloat { expanded ? 136 : 72 }
}

struct EdgeNotchView: View {
    @ObservedObject var state: EdgeNotchState
    let controlCenter: ControlCenterModel
    var onQuotaRequested: () -> Void = {}
    var onOpenQuota: () -> Void = {}
    @StateObject private var theme = DockThemeStore()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let openDock: () -> Void
    var onDrag: (Bool) -> Void = { _ in }
    var onSideChange: (EdgeDockSide) -> Void = { _ in }

    private var tint: Color {
        state.activity.attention ? .dockWarning : state.activity.hasUpdate ? .dockSuccess : .dockAccent
    }

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                if state.expanded {
                    // The outer contour already supplies visual breathing room.
                    // Keep the preview close to it so its content does not float
                    // in the middle of the expanded notch.
                    preview.frame(width: 352, height: 252)
                        .padding(.horizontal, 8)
                        .transition(.opacity)
                } else {
                    rail
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height,
                   alignment: state.side == .right ? .trailing : .leading)
            .background {
                if state.expanded {
                    EdgeNotchShape(side: state.side).fill(Color.dockNotchCanvas)
                        .overlay { EdgeNotchShape(side: state.side).stroke(Color.dockBorderStrong, lineWidth: 1) }
                }
            }
        }
        .clipped()
        .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.86), value: state.expanded)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: state.isQuiet)
        .preferredColorScheme(theme.selectedThemeID.appearance == .light ? .light : theme.selectedThemeID.appearance == .dark ? .dark : nil)
        .id(theme.selectedThemeID)
    }

    private var rail: some View {
        Button(action: openDock) {
            HStack(spacing: 0) {
                if state.side == .right { Spacer(minLength: 0) }
                EdgeNotchStatusIndicator(activity: state.activity)
                    .frame(width: 22, height: 72)
                    .background {
                        EdgeNotchShape(side: state.side).fill(Color.dockNotchCanvas)
                            .overlay { EdgeNotchShape(side: state.side).stroke(Color.dockBorderStrong, lineWidth: 1) }
                    }
                if state.side == .left { Spacer(minLength: 0) }
            }
            .frame(width: state.railWidth, height: state.railHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(DragGesture(minimumDistance: 6)
            .onChanged { _ in onDrag(false) }
            .onEnded { _ in onDrag(true) })
        .contextMenu {
            Button("Move to left edge") { onSideChange(.left) }
            Button("Move to right edge") { onSideChange(.right) }
            Divider()
            Button("Quit Hermes Dock") { NSApp.terminate(nil) }
        }
        .accessibilityLabel("\(state.name), \(state.activity.title). Open Dock")
        .accessibilityHint("Drag to move along either screen edge")
        .help("\(state.activity.title). Hover for details; drag to reposition.")
    }

    private var preview: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Button("Session") { state.showingAnnouncement = false; state.showsQuota = false }
                    .foregroundStyle(state.displaysQuota ? Color.dockSecondaryText : Color.dockAccent)
                Button("Quota") { state.showingAnnouncement = false; state.showsQuota = true; onQuotaRequested() }
                    .foregroundStyle(state.displaysQuota ? Color.dockAccent : Color.dockSecondaryText)
                Spacer()
            }
            .font(.system(size: 12, weight: .semibold))
            .buttonStyle(.plain)
            .frame(height: 44)
            .padding(.horizontal, 12)
            if state.displaysQuota {
                EdgeQuotaPreview(control: controlCenter, openQuota: onOpenQuota)
            } else {
                sessionPreview
            }
        }
    }

    private var sessionPreview: some View {
        Button(action: openDock) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    DockAppIcon().frame(width: 22, height: 22)
                    Text(state.sessionTitle).font(.system(size: 12, weight: .semibold)).lineLimit(2)
                    Spacer()
                }
                Text(state.updateTitle).font(.system(size: 12, weight: .semibold)).foregroundStyle(tint)
                Text(state.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.dockNotchSecondaryText)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Open session").font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(Color.dockNotchText)
            .padding(.leading, 12)
            .padding(.vertical, 14)
            .padding(.trailing, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(state.sessionTitle). \(state.updateTitle). \(state.detail). Open session")
    }
}

/// Indeterminate motion conveys work without inventing a percentage.
private struct EdgeNotchStatusIndicator: View {
    let activity: EdgeNotchActivity
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var traveling = false

    private var color: Color {
        if activity.attention { return .dockWarning }
        if activity.hasUpdate { return .dockSuccess }
        if activity.status == .offline { return .dockSecondaryText }
        return .dockAccent
    }

    var body: some View {
        VStack(spacing: 7) {
            if activity.attention {
                Image(systemName: "exclamationmark").font(.system(size: 10, weight: .bold))
            } else if activity.hasUpdate {
                Circle().fill(color).frame(width: 5, height: 5)
            } else if activity.status == .offline {
                Image(systemName: "slash.circle").font(.system(size: 10))
            }
            if activity.working {
                ZStack {
                    Capsule().fill(color.opacity(0.18)).frame(width: 3, height: 28)
                    Capsule().fill(color).frame(width: 3, height: 10)
                        .offset(y: reduceMotion ? 0 : traveling ? 9 : -9)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.85).repeatForever(autoreverses: true), value: traveling)
                }
            } else if activity.quiet {
                Capsule().fill(Color.dockSecondaryText.opacity(0.45))
                    .frame(width: 3, height: 16)
            } else if activity.hasUpdate {
                Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold))
            }
        }
        .foregroundStyle(color)
        .onAppear { traveling = true }
        .accessibilityHidden(true)
    }
}

/// Concave shoulders meet the physical screen edge; the inner face is rounded.
struct EdgeNotchShape: Shape {
    var side: EdgeDockSide = .right

    func path(in rect: CGRect) -> Path {
        let shoulder: CGFloat = min(24, rect.width / 3)
        let radius: CGFloat = min(30, rect.width / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - shoulder, y: rect.minY + shoulder),
                          control: CGPoint(x: rect.maxX, y: rect.minY + shoulder))
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.minY + shoulder))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY + shoulder + radius),
                          control: CGPoint(x: rect.minX, y: rect.minY + shoulder))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - shoulder - radius))
        path.addQuadCurve(to: CGPoint(x: rect.minX + radius, y: rect.maxY - shoulder),
                          control: CGPoint(x: rect.minX, y: rect.maxY - shoulder))
        path.addLine(to: CGPoint(x: rect.maxX - shoulder, y: rect.maxY - shoulder))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY),
                          control: CGPoint(x: rect.maxX, y: rect.maxY - shoulder))
        path.closeSubpath()
        if side == .left {
            return path.applying(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: rect.minX + rect.maxX, ty: 0))
        }
        return path
    }
}

final class EdgeDockHostingView<Content: View>: NSHostingView<Content> {
    var onHoverChanged: ((Bool) -> Void)?
    private var hoverArea: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        hoverArea = area
        addTrackingArea(area)
    }
    override func mouseEntered(with event: NSEvent) { onHoverChanged?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChanged?(false) }
}
