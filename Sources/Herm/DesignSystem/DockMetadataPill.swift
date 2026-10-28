import SwiftUI

/// A value chip, without the lifecycle dot used by status pills.
struct DockMetadataPill: View {
    let text: String
    var language: String? = nil
    @Environment(\.dockWorkspaceScale) private var workspaceScale
    var navigationIcon: Ph? = nil
    var colorHex: String? = nil
    var compact = false
    private var labelColor: DockMetadataPillColor? { colorHex.flatMap(DockMetadataPillColor.init) }

    var body: some View {
        HStack(spacing: DockSpacing.micro) {
            if let language, let image = ArtifactFileIcon.image(forLanguage: language) {
                Image(nsImage: image)
                    .renderingMode(
                        DockThemeRuntime.current == .mono || DockThemeRuntime.current == .eInk ? .template : .original
                    )
                    .resizable().interpolation(.high).scaledToFit()
                    .frame(
                        width: DockWorkspaceScale.points(14, scale: workspaceScale),
                        height: DockWorkspaceScale.points(14, scale: workspaceScale)
                    )
                    .foregroundStyle(Color.dockSecondaryText)
                    .accessibilityHidden(true)
            }
            if let labelColor {
                Circle().fill(labelColor.background).frame(width: 8, height: 8).accessibilityHidden(true)
            }
            Text(text)
                .underline(navigationIcon != nil)
                .fixedSize(horizontal: false, vertical: true)
            if let navigationIcon {
                DockIcon(navigationIcon, size: 12, color: .dockAccent)
            }
        }
        .dockFont(compact ? .metadata : .body)
        .fontWeight(.regular)
        .foregroundStyle(navigationIcon == nil ? Color.dockPrimaryText : Color.dockAccent)
        .padding(.horizontal, compact ? 6 : 10)
        .padding(.vertical, compact ? 2 : 4)
        .background(Capsule().fill(Color.dockSurface4))
        .overlay(
            Capsule().stroke(Color.dockBorderLight, lineWidth: DockLayout.hairline))
    }
}

/// Provider label colors render as a dot on a neutral chip so they never fight the skin.
struct DockMetadataPillColor {
    let red: Double
    let green: Double
    let blue: Double
    let luminance: Double
    var usesWhiteText: Bool { 1.05 / (luminance + 0.05) > (luminance + 0.05) / 0.05 }
    var contrastRatio: Double { usesWhiteText ? 1.05 / (luminance + 0.05) : (luminance + 0.05) / 0.05 }
    var background: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: 1) }
    var foreground: Color { usesWhiteText ? .white : .black }
    init?(hex: String) {
        let value = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard value.count == 6,
            value.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
            let rgb = UInt32(value, radix: 16)
        else { return nil }
        red = Double((rgb >> 16) & 255) / 255
        green = Double((rgb >> 8) & 255) / 255
        blue = Double(rgb & 255) / 255
        func linear(_ channel: Double) -> Double {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        luminance = 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
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
            subviews[index].place(
                at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                proposal: ProposedViewSize(
                    width: min(bounds.width, subviews[index].sizeThatFits(.unspecified).width), height: nil))
        }
    }

    private func arrange(width: CGFloat, _ subviews: Subviews) -> (origins: [CGPoint], width: CGFloat, height: CGFloat)
    {
        var origins: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(
                ProposedViewSize(width: min(width, subview.sizeThatFits(.unspecified).width), height: nil))
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
