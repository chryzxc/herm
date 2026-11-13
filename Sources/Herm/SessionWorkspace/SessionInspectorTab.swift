import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SessionInspectorTabItem: Identifiable {
    let id: String
    let title: String
    let icon: Ph
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void
    /// Set for a group chat tab, whose members' avatars replace the icon.
    var groupRoomID: String?
}

struct SessionInspectorTabDrag: Codable, Transferable {
    let workspace: String
    let id: String
    static let pasteboardType = NSPasteboard.PasteboardType("io.github.chryzxc.Herm.inspector-tab")

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(
            contentType: UTType(exportedAs: pasteboardType.rawValue, conformingTo: .data))
    }
}

/// Presentation order only; previews and their order live for the current app run.
@MainActor
final class SessionInspectorTabOrder: ObservableObject {
    static let shared = SessionInspectorTabOrder()
    @Published private(set) var orders: [String: [String]] = [:]

    func ordered(_ available: [String], in workspace: String) -> [String] {
        let saved = orders[workspace] ?? []
        return saved.filter { available.contains($0) } + available.filter { !saved.contains($0) }
    }

    @discardableResult
    func move(_ drag: SessionInspectorTabDrag, to target: String, available: [String], in workspace: String) -> Bool {
        guard drag.workspace == workspace, drag.id != target else { return false }
        var ids = ordered(available, in: workspace)
        guard let sourceIndex = ids.firstIndex(of: drag.id), let targetIndex = ids.firstIndex(of: target) else {
            return false
        }
        ids.insert(ids.remove(at: sourceIndex), at: targetIndex)
        orders[workspace] = ids
        return true
    }
}

@MainActor
final class SessionInspectorTabSurface {
    weak var view: NSView?
}

struct SessionInspectorTab: View {
    let tab: SessionInspectorTabItem
    let compact: Bool
    let drag: SessionInspectorTabDrag
    let reorder: @MainActor (SessionInspectorTabDrag) -> Bool
    let moveLeft: (() -> Void)?
    let moveRight: (() -> Void)?

    @State private var hovered = false
    @State private var isDropTarget = false
    @State private var surface = SessionInspectorTabSurface()

    private var showsTitle: Bool { !compact }

    var body: some View {
        HStack(spacing: 0) {
            selectionButton
            if showsTitle {
                Button(action: tab.close) {
                    DockIcon(.x, size: 12, color: tab.isSelected ? .dockPrimaryText : .dockSecondaryText)
                        .frame(width: 28, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.dockHover)
                .accessibilityLabel("Close \(tab.title)")
            }
        }
        .dockFont(.body, weight: .semibold)
        .foregroundStyle(tab.isSelected ? Color.dockPrimaryText : Color.dockSecondaryText)
        .dockSelectionBackground(
            DockThemeShape(cornerRadius: DockLayout.controlRadius - 1), active: tab.isSelected,
            fill: DockThemePalette(theme: DockThemeRuntime.current).selectedFill, allowsInvert: false
        )
        .background(!tab.isSelected && hovered ? Color.dockSurface2 : Color.clear)
        .clipShape(DockThemeShape(cornerRadius: DockLayout.controlRadius - 1))
        .overlay {
            if isDropTarget {
                DockThemeShape(cornerRadius: DockLayout.controlRadius - 1)
                    .stroke(Color.dockAccent, lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .background {
            SessionInspectorTabHoverArea(surface: { surface.view = $0 }) { inside in
                hovered = inside
            }
        }
        .transaction { $0.animation = nil }
        .onDrop(
            of: [SessionInspectorTabDrag.pasteboardType.rawValue],
            delegate: SessionInspectorTabDropDelegate(isTargeted: $isDropTarget, reorder: reorder)
        )
        .contextMenu {
            Button("Move tab left") { moveLeft?() }.disabled(moveLeft == nil)
            Button("Move tab right") { moveRight?() }.disabled(moveRight == nil)
            Divider()
            Button("Close tab", action: tab.close)
        }
    }

    private var selectionButton: some View {
        SessionInspectorTabDragSource(
            payload: drag, title: tab.title, isSelected: tab.isSelected, select: tab.select,
            dragging: { _ in }, entered: { hovered = true }, content: selectionLabel, preview: { surface.view }
        )
        .help(tab.title)
    }

    private var selectionLabel: some View {
        HStack(spacing: 6) {
            DockIcon(
                tab.icon, size: 12, weight: tab.isSelected ? .fill : .regular,
                color: tab.isSelected ? .dockPrimaryText : .dockSecondaryText)
            if showsTitle {
                Text(tab.title).lineLimit(1).frame(maxWidth: 240)
            }
        }
        .dockFont(.control)
        .dockPadding(.leading, 10)
        .dockPadding(.trailing, 6)
        .frame(height: 32)
    }
}
