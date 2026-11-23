import SwiftUI

/// The 32pt bar along the bottom of the workspace card. Left: live work and
/// what needs a decision. Right: context. Every item opens the work it counts.
struct WorkspaceStatusBar: View {
    static let height: CGFloat = 32

    @ObservedObject var status: WorkspaceStatusModel
    let edgeState: EdgeNotchState
    @ObservedObject var interruptions: HermInterruptionCoordinator
    @ObservedObject private var preferences = StatusBarPreferences.shared
    @State private var hoveredPreview: UUID?
    @State private var pinnedItem: StatusBarItem?
    var isFloating = false
    var isCompact = false
    var terminalScope: WorkspaceStatusModel.TerminalScope?
    let performAction: (StatusBarEntry.Action) -> Void
    let openSettings: () -> Void

    private struct TerminalMonitor: Equatable {
        let scope: WorkspaceStatusModel.TerminalScope?
        let servers: Bool
        let tests: Bool
    }

    private var isVisible: Bool { preferences.isVisible(inFloatingPanel: isFloating) }

    var body: some View {
        Group {
            if isVisible {
                let layout = status.layout
                let monitor = TerminalMonitor(
                    scope: terminalScope, servers: preferences.isOn(.processes), tests: preferences.isOn(.verification))
                content(layout)
                    .buttonStyle(.dockHover)
                    .dockButtonSize(.compact)
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
                    .task(id: monitor) {
                        await status.monitorTerminals(in: monitor.scope, servers: monitor.servers, tests: monitor.tests)
                    }
            }
        }
        .onChange(of: isVisible) { _, visible in
            guard !visible else { return }
            hoveredPreview = nil
            pinnedItem = nil
            status.isTrayPresented = false
        }
    }

    @ViewBuilder private func content(_ layout: StatusBarLayout) -> some View {
        if interruptions.quiet {
            quiet(layout)
        } else if layout.isStale {
            stale(layout)
        } else {
            let trailing = layout.trailing.filter { entry in
                switch entry.item {
                case .processes, .verification: status.terminalScope == terminalScope && terminalScope != nil
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
        HStack(spacing: 4) {
            HStack(spacing: 6) {
                DockIcon(.moon, size: 12, weight: .fill, color: .dockSecondaryText)
                Text(interruptions.expiry.map { "Quiet until \(StatusBarLayout.clock($0))" } ?? "Quiet")
                    .fontWeight(.semibold)
            }
            .dockPadding(.horizontal, 8)
            separator
            // The attention queue remains reachable during Quiet mode.
            ForEach(layout.chips.filter { $0.item == .needsYou }) { chip($0) }
            let held = interruptions.entries.count + interruptions.overflow
            if held > 0 {
                plainChip("\(held) held", help: "Banners and sounds waiting until quiet ends") { status.openActivity() }
            }
            Spacer(minLength: 8)
            Button("End quiet") { interruptions.end() }
                .buttonStyle(.dockSecondary)
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
                .help("The displayed counts are from the last available update.")
            trayButton
        }
    }

    private func returnChip(_ summary: (since: Date, text: String)) -> some View {
        plainChip(
            "Since \(StatusBarLayout.clock(summary.since)): \(summary.text)", help: "What changed while you were away"
        ) {
            status.dismissReturnSummary()
            perform(.tab(.usage))
        }
    }

    // MARK: - Pieces

    private var separator: some View {
        Color.dockBorder.frame(width: DockLayout.hairline, height: 14).dockPadding(.horizontal, 4)
    }

    private func chip(_ entry: StatusBarEntry) -> some View {
        let tint: Color? = entry.tone == .decision ? .dockWarning : nil
        let iconColor: Color =
            switch entry.tone {
            case .decision, .warning: .dockWarning
            case .problem: .dockDestructive
            case .outcome, .context: .dockSecondaryText
            }
        return Button {
            perform(entry.action)
        } label: {
            let label = HStack(spacing: 5) {
                if let icon = entry.icon {
                    DockIcon(icon, size: 12, weight: entry.tone == .decision ? .fill : .regular, color: iconColor)
                }
                Text(entry.text).dockFont(.metadata, weight: entry.tone == .decision ? .semibold : .medium)
                    .foregroundStyle(entry.tone == .decision ? Color.dockPrimaryText : Color.dockSecondaryText)
                    .monospacedDigit().lineLimit(1).frame(maxWidth: 168)
            }
            Group {
                if let tint {
                    label.dockPadding(.horizontal, 2).dockPill(tint: tint)
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

    private func plainChip(_ text: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text).fontWeight(.semibold).monospacedDigit().lineLimit(1)
                .dockPadding(.horizontal, 2)
                .dockPill(outline: Color.dockBorder)
                .fixedSize()
                .contentShape(Capsule())
        }
        .help(help)
    }

    /// Right-zone context with an affordance for navigation or a pinned preview.
    @ViewBuilder private func segment(_ entry: StatusBarEntry) -> some View {
        let label = HStack(spacing: 5) {
            if let icon = entry.icon {
                DockIcon(
                    icon, size: 12, color: entry.tone == .problem ? .dockDestructive : .dockSecondaryText)
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
                    if entry.action == .preview {
                        status.isTrayPresented = false
                        hoveredPreview = nil
                        pinnedItem = pinnedItem == entry.item ? nil : entry.item
                    } else {
                        perform(entry.action)
                    }
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
                Text(Self.activityKeycap).dockFont(.metadata, weight: .semibold, design: .monospaced)
                    .foregroundStyle(Color.dockSecondaryText).accessibilityHidden(true)
                DockIcon(.pulse, size: 13, color: .dockPrimaryText)
                if !isCompact { Text("Activity").dockFont(.metadata, weight: .semibold) }
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
        let pin = Binding(
            get: { pinnedItem == entry.item },
            set: { if !$0, pinnedItem == entry.item { pinnedItem = nil } })
        return StatusBarHoverPreview(
            selection: $hoveredPreview, isPinned: pin, allowsHover: !status.isTrayPresented && pinnedItem == nil
        ) {
            preview(status.layout.preview(for: entry))
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

    private func perform(_ action: StatusBarEntry.Action) {
        hoveredPreview = nil
        pinnedItem = nil
        if action == .tray { status.openActivity() } else { performAction(action) }
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
