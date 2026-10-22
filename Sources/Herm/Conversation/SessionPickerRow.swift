import AppKit
import Combine
import SwiftUI
import Foundation
import UniformTypeIdentifiers

/// One conversation in the session picker popover: title, preview, and a
/// single metadata line, with hide and delete kept visible in a quiet color.
struct SessionPickerRow: View {
    let session: HermesSession
    let projectName: String?
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
        HStack(spacing: 4) {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.displayTitle)
                        .dockFont(size: 13, weight: isCurrent ? .semibold : .medium)
                        .foregroundStyle(session.isHidden ? style.secondaryText : style.primaryText)
                        .lineLimit(1)
                    if let preview = session.displayPreview {
                        Text(preview)
                            .dockFont(size: 12)
                            .foregroundStyle(style.secondaryText)
                            .lineLimit(1)
                    }
                    metadata
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
                .padding(.leading, 10)
                .padding(.trailing, 18)
                .overlay(alignment: .trailing) {
                    DockIcon(.caretRight, size: 12, color: style.secondaryText)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.dockHover)
            .accessibilityAddTraits(isCurrent ? .isSelected : [])

            DockIconButton(
                icon: session.isHidden ? .eye : .eyeSlash,
                label: session.isHidden ? "Show \(session.displayTitle)" : "Hide \(session.displayTitle)",
                isBusy: isUpdatingVisibility,
                size: 24,
                style: style,
                action: onToggleHidden
            )
            DockIconButton(
                icon: .trash,
                label: isCurrent ? "The active conversation cannot be deleted" : "Delete \(session.displayTitle)",
                size: 24,
                style: style,
                action: onDelete
            )
            .disabled(!canDelete)
            .opacity(canDelete ? 1 : 0.4)
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
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : .dockEase(duration: 0.16), value: isHovering)
    }

    private var metadata: some View {
        HStack(spacing: 6) {
            if isCurrent {
                Text("Current")
                    .foregroundStyle(style.accent)
            }
            if session.isHidden {
                DockIconLabel("Hidden", icon: .eyeSlash)
            }
            if let projectName {
                DockIconLabel(projectName, icon: .folder)
                    .truncationMode(.middle)
            }
            if let date = session.lastUpdatedAt {
                Text(date, format: .relative(presentation: .named, unitsStyle: .abbreviated))
            }
        }
        .dockFont(size: 11, weight: .medium)
        .foregroundStyle(style.metadataText)
        .lineLimit(1)
        .padding(.top, 2)
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
                        let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.2) / 2.2
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
