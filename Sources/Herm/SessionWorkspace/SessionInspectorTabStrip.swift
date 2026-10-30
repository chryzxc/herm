import SwiftUI

enum SessionInspectorTabLayout {
    private static func widths(titles: [String], scale: CGFloat) -> [CGFloat] {
        let font = DockSkinPresentation.nativeFont(size: DockTypography.size(.control, scale: scale), weight: .medium)
        return titles.map { title in
            min(240, ceil((title as NSString).size(withAttributes: [.font: font]).width))
                + DockWorkspaceScale.points(12, scale: scale) + 6 + 16 + 28
        }
    }

    static func fullWidth(titles: [String], scale: CGFloat = 1) -> CGFloat {
        widths(titles: titles, scale: scale).reduce(0, +) + CGFloat(max(0, titles.count - 1)) * 2 + 20
    }

    static func collapsedIndices(
        titles: [String], selectedIndex: Int?, availableWidth: CGFloat, scale: CGFloat = 1
    ) -> Set<Int> {
        let widths = widths(titles: titles, scale: scale)
        var required = fullWidth(titles: titles, scale: scale)
        let compactWidth = DockWorkspaceScale.points(12, scale: scale) + 16
        let candidates = titles.indices.sorted {
            if $0 == selectedIndex { return false }
            if $1 == selectedIndex { return true }
            let left = abs($0 - (selectedIndex ?? 0))
            let right = abs($1 - (selectedIndex ?? 0))
            return left == right ? $0 > $1 : left > right
        }
        var collapsed: Set<Int> = []
        for index in candidates {
            guard required > availableWidth else { break }
            collapsed.insert(index)
            required -= widths[index] - compactWidth
        }
        return collapsed
    }
}

struct SessionInspectorTabStrip: View {
    let tabs: [SessionInspectorTabItem]
    let workspace: String
    let reorder: @MainActor (SessionInspectorTabDrag, String) -> Bool
    @Environment(\.dockWorkspaceScale) private var scale

    private var selectedID: String? { tabs.first(where: \.isSelected)?.id }

    var body: some View {
        GeometryReader { geometry in
            let collapsed = SessionInspectorTabLayout.collapsedIndices(
                titles: tabs.map(\.title), selectedIndex: tabs.firstIndex(where: \.isSelected),
                availableWidth: geometry.size.width, scale: scale)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                            SessionInspectorTab(
                                tab: tab, compact: collapsed.contains(index),
                                drag: SessionInspectorTabDrag(workspace: workspace, id: tab.id),
                                reorder: { reorder($0, tab.id) },
                                moveLeft: index > 0 ? { move(tab.id, to: tabs[index - 1].id) } : nil,
                                moveRight: index + 1 < tabs.count ? { move(tab.id, to: tabs[index + 1].id) } : nil
                            ).id(tab.id)
                        }
                    }
                    .frame(minWidth: max(0, geometry.size.width - 20), alignment: .leading)
                    .dockPadding(.horizontal, 10)
                }
                .onChange(of: selectedID, initial: true) { _, _ in revealSelection(proxy) }
                .onChange(of: workspace) { _, _ in revealSelection(proxy) }
                .onChange(of: tabs.map(\.id)) { _, _ in revealSelection(proxy) }
                .onChange(of: geometry.size.width) { _, _ in revealSelection(proxy) }
            }
        }
        .frame(height: 32)
    }

    private func move(_ id: String, to target: String) {
        _ = reorder(SessionInspectorTabDrag(workspace: workspace, id: id), target)
    }

    private func revealSelection(_ proxy: ScrollViewProxy) {
        guard let selectedID else { return }
        DispatchQueue.main.async { proxy.scrollTo(selectedID, anchor: .center) }
    }
}
