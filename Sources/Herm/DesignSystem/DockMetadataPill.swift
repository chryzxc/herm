import SwiftUI

/// A value chip, without the lifecycle dot used by status pills.
struct DockMetadataPill: View {
    let text: String
    var navigationIcon: Ph? = nil

    var body: some View {
        HStack(spacing: DockSpacing.micro) {
            Text(text)
                .underline(navigationIcon != nil)
                .fixedSize(horizontal: false, vertical: true)
            if let navigationIcon {
                DockIcon(navigationIcon, size: 12, color: .dockAccent)
            }
        }
            .font(DockTypography.body)
            .fontWeight(.regular)
            .foregroundStyle(navigationIcon == nil ? Color.dockPrimaryText : Color.dockAccent)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.dockSurface4))
            .overlay(Capsule().stroke(Color.dockBorderLight, lineWidth: DockLayout.hairline))
    }
}

/// Wraps chips onto as many rows as the width needs.
struct DockChipFlow: Layout {
    var spacing: CGFloat = DockSpacing.tight

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews)
        return CGSize(width: proposal.width ?? rows.width, height: rows.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (index, origin) in arrange(width: bounds.width, subviews).origins.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: ProposedViewSize(width: min(bounds.width, subviews[index].sizeThatFits(.unspecified).width), height: nil))
        }
    }

    private func arrange(width: CGFloat, _ subviews: Subviews) -> (origins: [CGPoint], width: CGFloat, height: CGFloat) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: min(width, subview.sizeThatFits(.unspecified).width), height: nil))
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return (origins, maxX, y + rowHeight)
    }
}
