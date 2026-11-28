import Combine
import SwiftUI

/// The 32pt bar along the bottom of the workspace card. Left: live work and
/// what needs a decision. Right: context. Each item previews its own status.
struct WorkspaceStatusBar: View {
    static let height: CGFloat = 32

    @ObservedObject var status: WorkspaceStatusModel
    let edgeState: EdgeNotchState
    @ObservedObject var interruptions: HermInterruptionCoordinator
    @ObservedObject private var preferences = StatusBarPreferences.shared
    @State private var hoveredPreview: UUID?
    @State private var pinnedItem: PreviewItem?
    var isFloating = false
    var isCompact = false
    var terminalScope: WorkspaceStatusModel.TerminalScope?
    var workflow: DeveloperWorkflowModel?
    let performAction: (StatusBarEntry.Action) -> Void
    let openSettings: () -> Void

    private struct TerminalMonitor: Equatable {
        let scope: WorkspaceStatusModel.TerminalProcessScope?
        let servers: Bool
    }

    private enum PreviewItem: Equatable {
        case entry(StatusBarItem)
        case heldNotifications
    }

    private var isVisible: Bool { preferences.isVisible(inFloatingPanel: isFloating) }

    var body: some View {
        Group {
            if isVisible {
                let layout = status.layout
                let monitor = TerminalMonitor(scope: terminalScope?.processes, servers: preferences.isOn(.processes))
                let tests = preferences.isOn(.verification)
                content(layout)
                    .buttonStyle(.dockHover)
                    .dockButtonSize(.inline)
                    .dockFont(.metadata)
                    .foregroundStyle(Color.dockPrimaryText)
                    .dockPadding(.horizontal, 8)
                    .frame(height: Self.height)
                    .frame(maxWidth: .infinity)
                    .dockShellChrome()
                    .overlay(alignment: .top) { Color.dockBorder.frame(height: DockLayout.hairline) }
                    .contentShape(Rectangle())
                    .contextMenu { menu }
                    .onChange(of: status.isTrayPresented) { _, presented in
                        if presented {
                            hoveredPreview = nil
                            pinnedItem = nil
                        }
                    }
                    .onChange(of: terminalScope, initial: true) { _, scope in
                        status.updateTerminalScope(currentVerificationScope(scope), tests: tests)
                    }
                    .onChange(of: tests) { _, tests in
                        status.updateTerminalScope(currentVerificationScope(terminalScope), tests: tests)
                    }
                    .task(id: monitor) {
                        await status.monitorTerminals(in: monitor.scope, servers: monitor.servers)
                    }
            }
        }
        .onChange(of: isVisible) { _, visible in
            guard !visible else { return }
            hoveredPreview = nil
            pinnedItem = nil
            status.isTrayPresented = false
            status.updateTerminalScope(nil, tests: false)
        }
        .onReceive(
            workflow?.$changeRevision.map { $0?.fingerprint }.removeDuplicates()
                .receive(on: DispatchQueue.main).eraseToAnyPublisher() ?? Empty().eraseToAnyPublisher()
        ) { _ in
            guard isVisible, preferences.isOn(.verification) else { return }
            status.updateTerminalScope(currentVerificationScope(terminalScope), tests: true)
        }
    }

    private func currentVerificationScope(_ scope: WorkspaceStatusModel.TerminalScope?)
        -> WorkspaceStatusModel.TerminalScope?
    {
        guard let scope, let workflow else { return scope }
        let repository = workflow.repository
        let matches =
            scope.repositoryID == repository.repositoryID && !repository.isStale && repository.statusError == nil
        return .init(
            identity: scope.identity, directory: scope.directory, repositoryID: matches ? scope.repositoryID : nil,
            fingerprint: matches ? workflow.repositoryFingerprint : nil)
    }

    @ViewBuilder private func content(_ layout: StatusBarLayout) -> some View {
        if interruptions.quiet {
            quiet(layout)
        } else if layout.isStale {
            stale(layout)
        } else {
            let trailing = layout.trailing.filter { entry in
                switch entry.item {
                case .processes:
                    terminalScope != nil && status.terminalScope?.processes == terminalScope?.processes
                case .verification:
                    terminalScope != nil && status.terminalScope == currentVerificationScope(terminalScope)
                default: true
                }
            }
            ViewThatFits(in: .horizontal) {
                ForEach(
                    Self.folds(chips: layout.chips.count, trailing: trailing.count),
                    id: \.self
                ) {
                    fold in row(layout.chips.prefix(fold.chips), trailing: trailing.prefix(fold.trailing))
                }
            }
        }
    }

    /// Widest first: optional context drops before the leading counts.
    struct Fold: Hashable {
        let chips: Int
        let trailing: Int
    }

    static func folds(chips: Int, trailing: Int) -> [Fold] {
        (0...trailing).reversed().map { Fold(chips: chips, trailing: $0) }
            + (0..<chips).reversed().map { Fold(chips: $0, trailing: 0) }
    }

    private func row(_ chips: ArraySlice<StatusBarEntry>, trailing: ArraySlice<StatusBarEntry>) -> some View {
        HStack(spacing: 4) {
            if let summary = status.returnSummary {
                returnChip(summary)
            }
            ForEach(chips) { chip($0) }
            Spacer(minLength: 8)
            ForEach(trailing) { segment($0) }
            if !trailing.isEmpty { separator }
            trayButton
        }
    }

    // MARK: - Modes

    private func quiet(_ layout: StatusBarLayout) -> some View {
        let attention = layout.chips.filter { $0.item == .needsYou }
        let held = interruptions.entries.count + interruptions.overflow
        return ViewThatFits(in: .horizontal) {
            if held > 0 { quietRow(attention, held: held) }
            quietRow(attention, held: nil)
        }
    }

    private func quietRow(_ attention: [StatusBarEntry], held: Int?) -> some View {
        let quietLabel = interruptions.expiry.map { "Quiet until \(StatusBarLayout.clock($0))" }
        return HStack(spacing: 4) {
            HStack(spacing: 6) {
                DockIcon(.moon, size: 12, weight: .fill, color: .dockSecondaryText)
                    .accessibilityHidden(true)
                Text(quietLabel ?? "Quiet").monospacedDigit().lineLimit(1)
            }
            .foregroundStyle(Color.dockSecondaryText)
            .dockPadding(.horizontal, 8)
            .modifier(
                hoverPreview {
                    .init(
                        headline: quietLabel ?? "Quiet until you end it", title: "Quiet mode", icon: .moon,
                        detail: "Banners and sounds are paused. Requests that need your attention still appear.",
                        footerAction: .none)
                })
            if !attention.isEmpty || held != nil { separator }
            // The attention queue remains reachable during Quiet mode.
            ForEach(attention) { chip($0) }
            if let held {
                summaryChip("\(held.formatted()) held", icon: .caretUp) {
                    togglePreview(.heldNotifications)
                }
                .modifier(
                    hoverPreview(for: .heldNotifications) {
                        .heldNotifications(interruptions.entries, overflow: interruptions.overflow)
                    })
            }
            Spacer(minLength: 8)
            Button {
                interruptions.end()
            } label: {
                Text("End quiet").dockFont(.control, weight: .regular)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .buttonStyle(.dockSecondary)
            .modifier(
                hoverPreview {
                    .init(
                        headline: "Resume banners and sounds for new updates", title: "End quiet", icon: .bellRinging,
                        footerAction: .none)
                })
            trayButton
        }
    }

    /// The last data stays, greyed and inert; the right slot says why.
    private func stale(_ layout: StatusBarLayout) -> some View {
        HStack(spacing: 4) {
            Group {
                ForEach(layout.chips) { chip($0) }
            }
            .disabled(true)
            .opacity(0.55)
            Spacer(minLength: 8)
            let message =
                layout.isOffline
                ? status.staleSince.map { "Stale since \(StatusBarLayout.clock($0)) · reconnecting" } ?? "Reconnecting"
                : "Activity status unavailable"
            Text(message)
                .foregroundStyle(Color.dockSecondaryText)
                .lineLimit(1)
                .modifier(
                    hoverPreview {
                        .init(
                            headline: message, title: "Connection status", icon: .plugs,
                            detail: "The displayed counts are from the last available update.", footerAction: .none)
                    })
            trayButton
        }
    }

    private func returnChip(_ summary: (since: Date, text: String)) -> some View {
        let since = "Since \(StatusBarLayout.clock(summary.since))"
        return summaryChip("\(since): \(summary.text)", icon: .arrowUpRight) {
            status.dismissReturnSummary()
            perform(.tab(.usage))
        }
        .modifier(
            hoverPreview {
                .init(
                    headline: summary.text, title: "While you were away", icon: .clockCounterClockwise,
                    detail: since, footerAction: .none)
            })
    }

    // MARK: - Pieces

    private var separator: some View {
        Color.dockBorder.frame(width: DockLayout.hairline, height: 14).dockPadding(.horizontal, 4)
    }

    private func iconColor(for tone: StatusBarEntry.Tone) -> Color {
        switch tone {
        case .decision, .warning: .dockWarning
        case .problem: .dockDestructive
        case .outcome, .context: .dockSecondaryText
        }
    }

    private func chip(_ entry: StatusBarEntry) -> some View {
        let isAttention = entry.tone == .decision
        return Button {
            activate(entry)
        } label: {
            let label = HStack(spacing: 5) {
                if let icon = entry.icon {
                    DockIcon(icon, size: 12, weight: isAttention ? .fill : .regular, color: iconColor(for: entry.tone))
                        .accessibilityHidden(true)
                }
                Text(entry.text).dockFont(.metadata)
                    .foregroundStyle(isAttention ? Color.dockPrimaryText : Color.dockSecondaryText)
                    .monospacedDigit().lineLimit(1).frame(maxWidth: 168)
            }
            Group {
                if isAttention {
                    label.dockPadding(.horizontal, 2)
                        .dockPill(tint: .dockWarning, outline: Color.dockWarning.opacity(0.34))
                } else {
                    label.dockPadding(.horizontal, 6)
                }
            }
            .frame(height: 24)
            .fixedSize()
            .contentShape(Rectangle())
        }
        .modifier(hoverPreview(for: entry))
    }

    private func summaryChip(_ text: String, icon: Ph, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: DockSpacing.micro) {
                Text(text).dockFont(.metadata).underline().monospacedDigit().lineLimit(1)
                DockIcon(icon, size: 9, color: .dockSecondaryText).accessibilityHidden(true)
            }
            .foregroundStyle(Color.dockSecondaryText)
            .dockPadding(.horizontal, 2)
            .dockPill(outline: Color.dockBorder)
            .fixedSize()
            .contentShape(Capsule())
        }
    }

    /// Right-zone context with an affordance for navigation or a pinned preview.
    @ViewBuilder private func segment(_ entry: StatusBarEntry) -> some View {
        let label = HStack(spacing: 5) {
            if let icon = entry.icon {
                DockIcon(icon, size: 12, color: iconColor(for: entry.tone)).accessibilityHidden(true)
            }
            Text(isCompact ? entry.compactText ?? entry.text : entry.text)
                .dockFont(.metadata).lineLimit(1).truncationMode(.middle).frame(maxWidth: 170)
            if entry.action != .none {
                DockIcon(entry.action == .preview ? .caretUp : .arrowUpRight, size: 9).accessibilityHidden(true)
            }
        }
        .foregroundStyle(Color.dockSecondaryText)
        .dockPadding(.horizontal, 6)
        .frame(height: 24)
        .fixedSize()
        Group {
            if entry.action == .none {
                label.contentShape(Rectangle())
            } else {
                Button {
                    activate(entry)
                } label: {
                    label.contentShape(Rectangle())
                }
            }
        }
        .modifier(hoverPreview(for: entry))
    }

    private var trayButton: some View {
        Button {
            hoveredPreview = nil
            pinnedItem = nil
            status.toggleActivity()
        } label: {
            HStack(spacing: 6) {
                DockIcon(.pulse, size: 13, color: .dockPrimaryText).accessibilityHidden(true)
                if !isCompact {
                    Text("Activity").dockFont(.control, weight: .regular)
                    Text(Self.activityKeycap).dockFont(.metadata, design: .monospaced)
                        .foregroundStyle(Color.dockSecondaryText).accessibilityHidden(true)
                }
            }
            .dockPadding(.horizontal, 6)
            .frame(height: 24)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(status.isTrayPresented ? "Close Activity popover" : "Show Activity popover")
        .modifier(
            StatusBarHoverPreview(
                selection: $hoveredPreview, isPinned: $status.isTrayPresented, allowsHover: pinnedItem == nil
            ) {
                preview(status.layout.preview)
            })
    }

    private func hoverPreview(for entry: StatusBarEntry) -> some ViewModifier {
        hoverPreview(for: .entry(entry.item)) { status.layout.preview(for: entry) }
    }

    private func hoverPreview(
        for item: PreviewItem? = nil, content: @escaping () -> StatusBarLayout.Preview
    ) -> some ViewModifier {
        let pin =
            item.map { item in
                Binding(
                    get: { pinnedItem == item },
                    set: { if !$0, pinnedItem == item { pinnedItem = nil } })
            } ?? .constant(false)
        return StatusBarHoverPreview(
            selection: $hoveredPreview, isPinned: pin, allowsHover: !status.isTrayPresented && pinnedItem == nil
        ) {
            preview(content())
        }
    }

    private func preview(_ data: StatusBarLayout.Preview) -> some View {
        WorkspaceActivityTray(preview: data, state: edgeState) { action in
            status.isTrayPresented = false
            perform(action)
        }
    }

    /// From the command registry, so the bar, menu and shortcut list agree.
    static let activityKeycap = HermCommand.all.first { $0.id == .toggleActivity }?.keycap ?? ""

    private func activate(_ entry: StatusBarEntry) {
        if entry.action == .preview {
            togglePreview(.entry(entry.item))
        } else {
            perform(entry.action)
        }
    }

    private func togglePreview(_ item: PreviewItem) {
        status.isTrayPresented = false
        hoveredPreview = nil
        pinnedItem = pinnedItem == item ? nil : item
    }

    private func perform(_ action: StatusBarEntry.Action) {
        hoveredPreview = nil
        pinnedItem = nil
        performAction(action)
    }

    // MARK: - Right-click

    @ViewBuilder private var menu: some View {
        ForEach(StatusBarItem.allCases.filter { !$0.isLocked }) { item in
            let access = BackendReach.access(item.resource)
            Toggle(
                item.title,
                isOn: preferences.binding(for: item)
            )
            .disabled(!access.isAvailable)
        }
        Divider()
        Button("Status bar settings…", action: openSettings)
        Button("Hide status bar") { preferences.isEnabled = false }
    }
}
