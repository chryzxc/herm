import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// A three-region fullscreen shell: queue, focused workspace, and contextual
/// inspector. The queue and inspector keep sensible minimums while the center
/// owns all remaining space.
struct SessionNavSplitView<Queue: View, Workspace: View, Inspector: View>: NSViewRepresentable {
    let queue: Queue
    let workspace: Workspace
    let inspector: Inspector

    func makeCoordinator() -> Coordinator { Coordinator() }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSplitView, context: Context) -> CGSize? {
        splitPaneSize(proposal)
    }

    func makeNSView(context: Context) -> NSSplitView {
        let splitView = NSSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = context.coordinator
        splitView.addArrangedSubview(context.coordinator.queueHost)
        splitView.addArrangedSubview(context.coordinator.workspaceHost)
        splitView.addArrangedSubview(context.coordinator.inspectorHost)
        context.coordinator.splitView = splitView
        return splitView
    }

    func updateNSView(_ splitView: NSSplitView, context: Context) {
        let performanceStart = ProcessInfo.processInfo.systemUptime
        defer { HermPerformanceRecorder.recordWork("splitHostUpdate", since: performanceStart) }
        context.coordinator.queueHost.rootView = AnyView(
            queue.dockThemedRoot().environment(\.dockWorkspaceScale, context.environment.dockWorkspaceScale))
        context.coordinator.workspaceHost.rootView = AnyView(
            workspace.dockThemedRoot().environment(\.dockWorkspaceScale, context.environment.dockWorkspaceScale))
        context.coordinator.inspectorHost.rootView = AnyView(
            inspector.dockThemedRoot().environment(\.dockWorkspaceScale, context.environment.dockWorkspaceScale))

        guard !context.coordinator.hasSetInitialPositions else { return }
        DispatchQueue.main.async {
            guard !context.coordinator.hasSetInitialPositions,
                splitView.bounds.width > 0
            else { return }
            // The session navigation shell deliberately gives the queue, work surface, and
            // inspector equal outer weight at launch. Users may still resize
            // either divider for a chat- or operations-heavy session.
            splitView.setPosition(splitView.bounds.width * 0.30, ofDividerAt: 0)
            splitView.setPosition(splitView.bounds.width * 0.70, ofDividerAt: 1)
            context.coordinator.hasSetInitialPositions = true
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSSplitViewDelegate {
        let queueHost = splitPaneHost(role: "queue")
        let workspaceHost = splitPaneHost(role: "workspace")
        let inspectorHost = splitPaneHost(role: "inspector")
        weak var splitView: NSSplitView?
        var hasSetInitialPositions = false

        func splitView(
            _ splitView: NSSplitView,
            constrainMinCoordinate proposedMinimumPosition: CGFloat,
            ofSubviewAt dividerIndex: Int
        ) -> CGFloat {
            dividerIndex == 0 ? 220 : 540
        }

        func splitView(
            _ splitView: NSSplitView,
            constrainMaxCoordinate proposedMaximumPosition: CGFloat,
            ofSubviewAt dividerIndex: Int
        ) -> CGFloat {
            if dividerIndex == 0 {
                return min(360, splitView.bounds.width - 680)
            }
            return splitView.bounds.width - 280
        }
    }
}

/// The split views fill whatever SwiftUI offers. Without these, SwiftUI
/// sizes the representable through Auto Layout `fittingSize`, which walks
/// every constraint of the nested transcript on each layout pass — the main
/// cost of scrolling a long conversation.
func splitPaneSize(_ proposal: ProposedViewSize) -> CGSize {
    proposal.replacingUnspecifiedDimensions(by: CGSize(width: 800, height: 600))
}

/// Named target proportions for the desktop three-column shell (queue rail /
/// conversation / inspector), applied identically whether the Dock is
/// fullscreen or in its windowed/minimized popover presentation. The center
/// conversation column is intentionally the largest share.
enum DesktopWorkspaceFractions {
    static let queue: CGFloat = 0.25
    static let conversation: CGFloat = 0.40
    static let inspector: CGFloat = 0.35
    static func minimumConversationWidth(isFullscreen: Bool) -> CGFloat {
        isFullscreen ? 520 : 360
    }
    /// Rail + list + conversation no longer fit: the list yields to the chat.
    static func listCannotFit(width: CGFloat, isFullscreen: Bool) -> Bool {
        width < 52 + 300 + minimumConversationWidth(isFullscreen: isFullscreen) + 1
    }
    static func shouldCollapseQueue(width: CGFloat, isFullscreen: Bool) -> Bool {
        width < 52 + 300 + minimumConversationWidth(isFullscreen: isFullscreen) + 360 + 3
    }

    /// The inner split only sees the space left after the outer queue split,
    /// so its leading fraction must be re-derived against that remainder.
    static let conversationOfRemainder: CGFloat = conversation / (conversation + inspector)
}

/// Use the navigation views' rendered inputs to skip repeated shell deliveries.
struct DesktopNavigationPane: View, Equatable {
    enum Content: Equatable {
        case sessions(SessionNavQueue)
        case bots(BotChatsPage)
    }

    let content: Content
    let history: DockNavigationHistory
    let visible: Bool

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        MainActor.assumeIsolated {
            lhs.content == rhs.content && lhs.visible == rhs.visible
                && lhs.history.canGoBack == rhs.history.canGoBack
                && lhs.history.canGoForward == rhs.history.canGoForward
        }
    }

    var body: some View {
        Group {
            switch content {
            case .sessions(let queue): queue.equatable()
            case .bots(let page): page.equatable()
            }
        }
        .environment(\.dockNavigationHistory, history)
        .environment(\.dockHostVisible, visible)
    }
}

/// AppKit owns the fullscreen divider so it stays responsive while SwiftUI updates each pane.
struct FullscreenPanelSplitView<Leading: View, Trailing: View>: NSViewRepresentable {
    let leading: Leading
    let trailing: Trailing
    let leadingFraction: CGFloat?
    let initialLeadingWidth: CGFloat?
    let minimumLeadingWidth: CGFloat
    let maximumLeadingWidth: CGFloat?
    let minimumTrailingWidth: CGFloat
    let leadingWidth: Binding<CGFloat>?
    /// Hides the trailing pane without tearing it down, so its state survives.
    let isTrailingCollapsed: Bool
    let isLeadingCollapsed: Bool
    let leadingMatches: ((Leading, Leading) -> Bool)?
    let performanceRoles: (leading: String, trailing: String)

    init(
        leading: Leading,
        trailing: Trailing,
        leadingFraction: CGFloat? = 0.30,
        initialLeadingWidth: CGFloat? = nil,
        minimumLeadingWidth: CGFloat = 220,
        maximumLeadingWidth: CGFloat? = nil,
        minimumTrailingWidth: CGFloat = 360,
        leadingWidth: Binding<CGFloat>? = nil,
        isTrailingCollapsed: Bool = false,
        isLeadingCollapsed: Bool = false,
        leadingMatches: ((Leading, Leading) -> Bool)? = nil,
        performanceRoles: (leading: String, trailing: String) = ("panelLeading", "panelTrailing")
    ) {
        self.isTrailingCollapsed = isTrailingCollapsed
        self.isLeadingCollapsed = isLeadingCollapsed
        self.leading = leading
        self.trailing = trailing
        self.leadingFraction = leadingFraction
        self.initialLeadingWidth = initialLeadingWidth
        self.minimumLeadingWidth = minimumLeadingWidth
        self.maximumLeadingWidth = maximumLeadingWidth
        self.minimumTrailingWidth = minimumTrailingWidth
        self.leadingWidth = leadingWidth
        self.leadingMatches = leadingMatches
        self.performanceRoles = performanceRoles
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            leadingFraction: leadingFraction,
            initialLeadingWidth: initialLeadingWidth,
            minimumLeadingWidth: minimumLeadingWidth,
            maximumLeadingWidth: maximumLeadingWidth,
            minimumTrailingWidth: minimumTrailingWidth,
            leadingWidth: leadingWidth,
            performanceRoles: performanceRoles
        )
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSplitView, context: Context) -> CGSize? {
        splitPaneSize(proposal)
    }

    func makeNSView(context: Context) -> NSSplitView {
        let splitView = FractionPreservingSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = context.coordinator
        splitView.fraction = leadingFraction
        splitView.minimumLeadingWidth = minimumLeadingWidth
        splitView.maximumLeadingWidth = maximumLeadingWidth
        splitView.minimumTrailingWidth = minimumTrailingWidth
        splitView.addArrangedSubview(context.coordinator.leadingHost)
        splitView.addArrangedSubview(context.coordinator.trailingHost)
        context.coordinator.splitView = splitView
        splitView.onUserResizeEnded = { [weak splitView, weak coordinator = context.coordinator] in
            guard let splitView else { return }
            coordinator?.persistLeadingWidth(in: splitView)
        }
        return splitView
    }

    func updateNSView(_ splitView: NSSplitView, context: Context) {
        let performanceStart = ProcessInfo.processInfo.systemUptime
        defer { HermPerformanceRecorder.recordWork("splitHostUpdate", since: performanceStart) }
        let coordinator = context.coordinator
        let visible = context.environment.dockHostVisible
        if coordinator.acceptsLeading(
            leading, environment: context.environment, collapsed: isLeadingCollapsed, matches: leadingMatches)
        {
            coordinator.leadingContent.update(visible: visible && !isLeadingCollapsed) {
                leading.dockThemedRoot().environment(\.self, context.environment)
                    .disabled(isLeadingCollapsed).accessibilityHidden(isLeadingCollapsed)
            }
        }
        coordinator.trailingContent.update(visible: visible && !isTrailingCollapsed) {
            trailing.dockThemedRoot().environment(\.self, context.environment)
                .disabled(isTrailingCollapsed).accessibilityHidden(isTrailingCollapsed)
                .overlay(alignment: .leading) {
                    // The collapsed leading pane leaves the rail's rule adjacent; don't double it.
                    if !isLeadingCollapsed {
                        // Starts below the shell's title row so the rule never cuts the frame.
                        Color.dockBorder.frame(width: DockLayout.hairline)
                            .padding(.top, context.environment.dockShellToolbarHeight)
                    }
                }
        }
        context.coordinator.leadingWidth = leadingWidth
        if let splitView = splitView as? FractionPreservingSplitView {
            splitView.fraction = leadingFraction
            splitView.minimumLeadingWidth = minimumLeadingWidth
            splitView.maximumLeadingWidth = maximumLeadingWidth
            splitView.minimumTrailingWidth = minimumTrailingWidth
            splitView.setCollapsed(
                leading: isLeadingCollapsed, trailing: isTrailingCollapsed,
                animated: context.environment.dockHostVisible && !context.environment.dockHostResizing
                    && DockMotion.isEnabled(reduceMotion: context.environment.accessibilityReduceMotion))
        }

        guard !isLeadingCollapsed, !isTrailingCollapsed, !context.coordinator.hasSetInitialPosition else { return }
        DispatchQueue.main.async {
            guard !context.coordinator.hasSetInitialPosition,
                splitView.bounds.width > 0,
                (splitView as? FractionPreservingSplitView)?.isLeadingCollapsed != true,
                (splitView as? FractionPreservingSplitView)?.isTrailingCollapsed != true
            else { return }
            let proposed = initialLeadingWidth ?? (splitView.bounds.width * (leadingFraction ?? 0.30))
            let minimum = context.coordinator.minimumLeadingPosition(in: splitView)
            let maximum = context.coordinator.maximumLeadingPosition(in: splitView)
            splitView.setPosition(min(max(proposed, minimum), maximum), ofDividerAt: 0)
            context.coordinator.hasSetInitialPosition = true
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSSplitViewDelegate {
        let leadingFraction: CGFloat
        let initialLeadingWidth: CGFloat?
        let minimumLeadingWidth: CGFloat
        let maximumLeadingWidth: CGFloat?
        let minimumTrailingWidth: CGFloat
        let leadingHost: NSHostingView<AnyView>
        let trailingHost: NSHostingView<AnyView>
        fileprivate let leadingContent = FullscreenSplitPaneContent()
        fileprivate let trailingContent = FullscreenSplitPaneContent()
        weak var splitView: NSSplitView?
        var hasSetInitialPosition = false
        var leadingWidth: Binding<CGFloat>?
        private var previousLeading: (Leading, NavigationEnvironment, Bool)?

        init(
            leadingFraction: CGFloat?,
            initialLeadingWidth: CGFloat?,
            minimumLeadingWidth: CGFloat,
            maximumLeadingWidth: CGFloat?,
            minimumTrailingWidth: CGFloat,
            leadingWidth: Binding<CGFloat>?,
            performanceRoles: (leading: String, trailing: String)
        ) {
            self.leadingFraction = leadingFraction ?? 0.30
            self.initialLeadingWidth = initialLeadingWidth
            self.minimumLeadingWidth = minimumLeadingWidth
            self.maximumLeadingWidth = maximumLeadingWidth
            self.minimumTrailingWidth = minimumTrailingWidth
            self.leadingWidth = leadingWidth
            leadingHost = splitPaneHost(role: performanceRoles.leading)
            trailingHost = splitPaneHost(role: performanceRoles.trailing)
            super.init()
            leadingHost.rootView = AnyView(FullscreenSplitPaneRoot(content: leadingContent))
            trailingHost.rootView = AnyView(FullscreenSplitPaneRoot(content: trailingContent))
        }

        func acceptsLeading(
            _ leading: Leading, environment: EnvironmentValues, collapsed: Bool, matches: ((Leading, Leading) -> Bool)?
        ) -> Bool {
            guard let matches else { return true }
            let presentation = NavigationEnvironment(environment)
            if let (previous, previousPresentation, previousCollapsed) = previousLeading,
                previousCollapsed == collapsed, previousPresentation == presentation, matches(previous, leading)
            {
                return false
            }
            previousLeading = (leading, presentation, collapsed)
            return true
        }

        func minimumLeadingPosition(in splitView: NSSplitView) -> CGFloat {
            (splitView as? FractionPreservingSplitView)?.minimumLeadingPosition
                ?? min(
                    minimumLeadingWidth,
                    max(0, splitView.bounds.width - splitView.dividerThickness - minimumTrailingWidth))
        }

        func maximumLeadingPosition(in splitView: NSSplitView) -> CGFloat {
            if let splitView = splitView as? FractionPreservingSplitView {
                return splitView.maximumLeadingPosition
            }
            let availableMaximum = max(
                minimumLeadingPosition(in: splitView),
                splitView.bounds.width - splitView.dividerThickness - minimumTrailingWidth)
            return min(maximumLeadingWidth ?? availableMaximum, availableMaximum)
        }

        func splitView(
            _ splitView: NSSplitView,
            constrainMinCoordinate proposedMinimumPosition: CGFloat,
            ofSubviewAt dividerIndex: Int
        ) -> CGFloat {
            minimumLeadingPosition(in: splitView)
        }

        func splitView(
            _ splitView: NSSplitView,
            constrainMaxCoordinate proposedMaximumPosition: CGFloat,
            ofSubviewAt dividerIndex: Int
        ) -> CGFloat {
            maximumLeadingPosition(in: splitView)
        }

        func splitViewDidResizeSubviews(_ notification: Notification) {
            guard let splitView = notification.object as? NSSplitView,
                (splitView as? FractionPreservingSplitView)?.isDraggingDivider != true
            else { return }
            persistLeadingWidth(in: splitView)
        }

        func persistLeadingWidth(in splitView: NSSplitView) {
            guard let leadingWidth,
                (splitView as? FractionPreservingSplitView)?.isTrailingCollapsed != true,
                (splitView as? FractionPreservingSplitView)?.isLeadingCollapsed != true
            else { return }
            let width = splitView.subviews.first?.frame.width ?? leadingWidth.wrappedValue
            if leadingWidth.wrappedValue != width { leadingWidth.wrappedValue = width }
        }
    }
}

/// The desktop navigation pane's environment crosses the separate AppKit host.
@MainActor
private struct NavigationEnvironment: Equatable {
    let visible: Bool
    let resizing: Bool
    let enabled: Bool
    let workspaceScale: CGFloat
    let toolbarHeight: CGFloat
    let displayScale: CGFloat
    let scheme: ColorScheme
    let contrast: ColorSchemeContrast
    let reduceMotion: Bool
    let reduceTransparency: Bool
    let locale: Locale
    let direction: LayoutDirection
    let typeSize: DynamicTypeSize
    let themeRevision: Int

    init(_ environment: EnvironmentValues) {
        visible = environment.dockHostVisible
        resizing = environment.dockHostResizing
        enabled = environment.isEnabled
        workspaceScale = environment.dockWorkspaceScale
        toolbarHeight = environment.dockShellToolbarHeight
        displayScale = environment.displayScale
        scheme = environment.colorScheme
        contrast = environment.colorSchemeContrast
        reduceMotion = environment.accessibilityReduceMotion
        reduceTransparency = environment.accessibilityReduceTransparency
        locale = environment.locale
        direction = environment.layoutDirection
        typeSize = environment.dynamicTypeSize
        themeRevision = DockThemeRuntime.revision
    }
}

@MainActor
private final class FullscreenSplitPaneContent: ObservableObject {
    @Published private(set) var view = AnyView(EmptyView())
    private var visible: Bool?
    private var pending: AnyView?

    func update(visible: Bool, content: () -> some View) {
        // Deliver the hidden transition, then resume with the latest inputs when reopened.
        guard visible || self.visible != false else { return }
        let next = AnyView(content())
        if self.visible == nil {
            view = next
        } else {
            let deliveryScheduled = pending != nil
            pending = next
            if !deliveryScheduled {
                // Coalesce shell updates and publish outside AppKit's representable update.
                DispatchQueue.main.async { [weak self] in
                    guard let self, let next = pending else { return }
                    pending = nil
                    view = next
                }
            }
        }
        self.visible = visible
    }
}

private struct FullscreenSplitPaneRoot: View {
    @ObservedObject var content: FullscreenSplitPaneContent

    var body: some View { content.view }
}
