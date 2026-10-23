import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// A three-region fullscreen shell: queue, focused workspace, and contextual
/// inspector. The queue and inspector keep sensible minimums while the center
/// owns all remaining space.
struct MissionControlSplitView<Queue: View, Workspace: View, Inspector: View>: NSViewRepresentable {
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
            // Mission Control deliberately gives the queue, work surface, and
            // inspector equal outer weight at launch. Users may still resize
            // either divider for a chat- or operations-heavy session.
            splitView.setPosition(splitView.bounds.width * 0.30, ofDividerAt: 0)
            splitView.setPosition(splitView.bounds.width * 0.70, ofDividerAt: 1)
            context.coordinator.hasSetInitialPositions = true
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSSplitViewDelegate {
        let queueHost = splitPaneHost()
        let workspaceHost = splitPaneHost()
        let inspectorHost = splitPaneHost()
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

@MainActor
func splitPaneHost() -> NSHostingView<AnyView> {
    let host = NSHostingView(rootView: AnyView(EmptyView()))
    // The split view places panes by frame; don't publish SwiftUI's
    // intrinsic/min/max size as constraints for the outer layout to solve.
    host.sizingOptions = []
    // Panes draw their own title row; inheriting the window's titlebar safe
    // area would push every pane down a second 52pt.
    host.safeAreaRegions = []
    return host
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
    /// The inner split only sees the space left after the outer queue split,
    /// so its leading fraction must be re-derived against that remainder.
    static let conversationOfRemainder: CGFloat = conversation / (conversation + inspector)
}

/// AppKit owns the fullscreen divider so panel resizing stays responsive even
/// while the conversation and inspector contain complex, frequently-updating
/// SwiftUI content.
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

    init(
        leading: Leading,
        trailing: Trailing,
        leadingFraction: CGFloat? = 0.30,
        initialLeadingWidth: CGFloat? = nil,
        minimumLeadingWidth: CGFloat = 220,
        maximumLeadingWidth: CGFloat? = nil,
        minimumTrailingWidth: CGFloat = 360,
        leadingWidth: Binding<CGFloat>? = nil,
        isTrailingCollapsed: Bool = false
    ) {
        self.isTrailingCollapsed = isTrailingCollapsed
        self.leading = leading
        self.trailing = trailing
        self.leadingFraction = leadingFraction
        self.initialLeadingWidth = initialLeadingWidth
        self.minimumLeadingWidth = minimumLeadingWidth
        self.maximumLeadingWidth = maximumLeadingWidth
        self.minimumTrailingWidth = minimumTrailingWidth
        self.leadingWidth = leadingWidth
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            leadingFraction: leadingFraction,
            initialLeadingWidth: initialLeadingWidth,
            minimumLeadingWidth: minimumLeadingWidth,
            maximumLeadingWidth: maximumLeadingWidth,
            minimumTrailingWidth: minimumTrailingWidth,
            leadingWidth: leadingWidth
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
        return splitView
    }

    func updateNSView(_ splitView: NSSplitView, context: Context) {
        context.coordinator.leadingHost.rootView = AnyView(
            leading.dockThemedRoot().environment(\.dockWorkspaceScale, context.environment.dockWorkspaceScale)
        )
        context.coordinator.trailingHost.rootView = AnyView(
            trailing.dockThemedRoot().environment(\.dockWorkspaceScale, context.environment.dockWorkspaceScale)
                .overlay(alignment: .leading) {
                    Color.dockBorder.frame(width: DockLayout.hairline)
                }
        )
        context.coordinator.leadingWidth = leadingWidth
        if let splitView = splitView as? FractionPreservingSplitView {
            splitView.setTrailingCollapsed(isTrailingCollapsed)
            splitView.fraction = leadingFraction
            splitView.minimumLeadingWidth = minimumLeadingWidth
            splitView.maximumLeadingWidth = maximumLeadingWidth
            splitView.minimumTrailingWidth = minimumTrailingWidth
        }

        guard !context.coordinator.hasSetInitialPosition else { return }
        DispatchQueue.main.async {
            guard !context.coordinator.hasSetInitialPosition,
                splitView.bounds.width > 0
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
        let leadingHost = splitPaneHost()
        let trailingHost = splitPaneHost()
        weak var splitView: NSSplitView?
        var hasSetInitialPosition = false
        var leadingWidth: Binding<CGFloat>?

        init(
            leadingFraction: CGFloat?,
            initialLeadingWidth: CGFloat?,
            minimumLeadingWidth: CGFloat,
            maximumLeadingWidth: CGFloat?,
            minimumTrailingWidth: CGFloat,
            leadingWidth: Binding<CGFloat>?
        ) {
            self.leadingFraction = leadingFraction ?? 0.30
            self.initialLeadingWidth = initialLeadingWidth
            self.minimumLeadingWidth = minimumLeadingWidth
            self.maximumLeadingWidth = maximumLeadingWidth
            self.minimumTrailingWidth = minimumTrailingWidth
            self.leadingWidth = leadingWidth
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
            guard let leadingWidth else { return }
            guard let splitView = notification.object as? NSSplitView,
                (splitView as? FractionPreservingSplitView)?.isTrailingCollapsed != true
            else { return }
            leadingWidth.wrappedValue = splitView.subviews.first?.frame.width ?? leadingWidth.wrappedValue
        }
    }
}
