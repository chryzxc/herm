import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// One conversation in the session picker popover. Mirrors the rail row: a
/// leading status slot (spinner, done, attention), title with time, then the
/// preview. Hide and delete replace the time on hover so rows stay quiet.
struct SessionPickerRow: View {
    let session: HermesSession
    let projectName: String?
    let status: SidebarSessionStatus
    let isCurrent: Bool
    let canDelete: Bool
    let isUpdatingVisibility: Bool
    let style: DockThemePalette
    let onOpen: () -> Void
    let onToggleHidden: () -> Void
    let onDelete: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                statusIndicator
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.displayTitle)
                        .dockFont(.navigation, weight: isCurrent ? .semibold : .medium)
                        .foregroundStyle(session.isHidden ? style.secondaryText : style.primaryText)
                        .lineLimit(1)
                        .modifier(WorkingTitleShimmer(isActive: status == .working, color: style.accent))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.trailing, 56)
                    if let preview = session.displayPreview {
                        Text(preview)
                            .dockFont(.body)
                            .foregroundStyle(style.secondaryText)
                            .lineLimit(1)
                    }
                    if session.isHidden || projectName != nil {
                        metadata
                    }
                }
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.dockHover)
        .overlay(alignment: .topTrailing) {
            trailingSlot
                .frame(height: 24)
                .padding(.top, 5)
                .padding(.trailing, 6)
        }
        .background(
            RoundedRectangle(cornerRadius: DockControlMetrics.cornerRadius, style: .continuous)
                .fill(isCurrent ? style.selectedFill : isHovering ? style.surface4.opacity(0.6) : .clear)
        )
        .overlay(alignment: .leading) {
            if isCurrent {
                Capsule().fill(style.accent).frame(width: 3, height: 14)
            }
        }
        .contextMenu {
            Button(session.isHidden ? "Show in list" : "Hide from list", action: onToggleHidden)
            Button("Delete…", role: .destructive, action: onDelete)
                .disabled(!canDelete)
        }
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : .dockEase(duration: 0.16), value: isHovering)
        .help(status == .none ? session.displayTitle : "\(session.displayTitle) — \(status.label)")
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    /// Same fixed-width slot as the rail, so titles align with or without status.
    private var statusIndicator: some View {
        Group {
            if let state = status.activityState {
                DockActivityIndicator(state: state, size: 12, unreadDot: true)
            } else {
                Color.clear
            }
        }
        .frame(width: 14, height: 14)
        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4.5 }
    }

    @ViewBuilder
    private var trailingSlot: some View {
        if isHovering || isUpdatingVisibility {
            HStack(spacing: 0) {
                if isUpdatingVisibility {
                    ProgressView().controlSize(.mini).frame(width: 24, height: 24)
                } else {
                    actionButton(
                        icon: session.isHidden ? .eye : .eyeSlash,
                        label: session.isHidden ? "Show \(session.displayTitle)" : "Hide \(session.displayTitle)",
                        action: onToggleHidden
                    )
                }
                actionButton(
                    icon: .trash,
                    label: canDelete ? "Delete \(session.displayTitle)" : "The active conversation cannot be deleted",
                    action: onDelete
                )
                .disabled(!canDelete)
                .opacity(canDelete ? 1 : 0.4)
            }
        } else if let date = session.lastUpdatedAt {
            Text(SidebarSessionTime.short(date))
                .dockFont(.metadata)
                .monospacedDigit()
                .foregroundStyle(style.metadataText)
                .lineLimit(1)
                .fixedSize()
                .padding(.trailing, 4)
        }
    }

    private func actionButton(icon: Ph, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            DockIcon(icon, size: 12, color: style.secondaryText)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.dockHover)
        .help(label)
        .accessibilityLabel(label)
    }

    private var metadata: some View {
        HStack(spacing: 6) {
            if session.isHidden {
                DockIconLabel("Hidden", icon: .eyeSlash)
            }
            if let projectName {
                DockIconLabel(projectName, icon: .folder)
                    .truncationMode(.middle)
            }
        }
        .dockFont(.metadata, weight: .medium)
        .foregroundStyle(style.metadataText)
        .lineLimit(1)
        .padding(.top, 1)
    }

    private var accessibilityLabel: String {
        var parts = [session.displayTitle]
        if isCurrent { parts.append("Current") }
        if status != .none { parts.append(status.label) }
        if session.isHidden { parts.append("Hidden") }
        if let projectName { parts.append(projectName) }
        if let date = session.lastUpdatedAt { parts.append(SidebarSessionTime.short(date)) }
        return parts.joined(separator: ", ")
    }
}

/// Rows sliding under a still pointer otherwise flip hover on every row they
/// pass, each building and tearing down its action buttons. Like Finder, hover
/// pauses while the list scrolls. `content` is stored, not a closure, so the
/// scroll-phase flip does not rebuild the rail.
struct HoverPausingScrollView<Content: View>: View {
    let content: Content
    @State private var isScrolling = false

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        if #available(macOS 15, *) {
            ScrollView { content.allowsHitTesting(!isScrolling) }
                .onScrollPhaseChange { _, phase in isScrolling = phase.isScrolling }
        } else {
            ScrollView { content }
        }
    }
}

/// Sweeps an accent highlight across a working session's title. Static under
/// Reduce Motion; only working rows pay for the timeline.
struct WorkingTitleShimmer: ViewModifier {
    let isActive: Bool
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if isActive && !reduceMotion {
            content.overlay {
                TimelineView(.dockMotion()) { context in
                    GeometryReader { geo in
                        let phase =
                            context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.2) / 2.2
                        let band = max(geo.size.width * 0.4, 40)
                        LinearGradient(colors: [.clear, color, .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: band)
                            .offset(x: -band + (geo.size.width + band) * phase)
                    }
                }
                .mask(content)
                .allowsHitTesting(false)
            }
        } else if isActive {
            content.foregroundStyle(color)
        } else {
            content
        }
    }
}
