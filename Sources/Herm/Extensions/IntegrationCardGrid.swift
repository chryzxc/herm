import SwiftUI

/// Adaptive library shared by every Integrations tab; wider columns keep descriptions readable.
struct IntegrationCardGrid<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 20, alignment: .top)], spacing: 0) {
            content
        }
    }
}

/// One integration tile: identity, a two-line description, live status and Hermes-reported source marks.
struct IntegrationCard<Icon: View>: View {
    let title: String
    let detail: String
    var status: (DockStatusTone, String)?
    /// Hermes Agent ships this item (bundled skill or plugin, catalog MCP preset).
    var builtin = false
    var official = false
    var stars: Int?
    var update = false
    let selected: Bool
    let action: () -> Void
    @ViewBuilder let icon: Icon

    var body: some View {
        let shape = DockThemeShape(cornerRadius: DockLayout.paneRadius, role: .pane)
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                icon
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 8) {
                        Text(title).dockFont(.body, weight: .semibold).foregroundStyle(Color.dockPrimaryText)
                            .lineLimit(2).multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                        DockIcon(.caretRight, size: 12, color: .dockMetadataText)
                    }
                    if !detail.isEmpty {
                        Text(detail).dockFont(.body).foregroundStyle(Color.dockSecondaryText)
                            .lineLimit(2).multilineTextAlignment(.leading)
                    }
                    DockChipFlow(spacing: 8) {
                        if let status {
                            HStack(spacing: 5) {
                                DockStatusDot(tone: status.0, size: 6)
                                Text(status.1)
                            }
                        }
                        if builtin { Label("Built-in", systemImage: "checkmark.shield") }
                        if official { Text("Official") }
                        if let stars {
                            Label(stars.formatted(.number.notation(.compactName)), systemImage: "star")
                                .monospacedDigit().help("\(stars) GitHub stars")
                        }
                        if update {
                            Label("Update available", systemImage: "arrow.up.circle")
                                .foregroundStyle(Color.dockAccent)
                        }
                    }
                    .dockFont(.metadata).foregroundStyle(Color.dockMetadataText)
                }
            }
            .dockPadding(14)
            .frame(maxWidth: .infinity, minHeight: detail.isEmpty ? 72 : 112, alignment: .topLeading)
            .background {
                if selected { shape.dockSurfaceFill(Color.dockSurface4) }
            }
            .overlay(alignment: .bottom) {
                Color.dockBorderLight.frame(height: DockLayout.hairline).dockPadding(.horizontal, 14)
                    .opacity(selected ? 0 : 1)
            }
            .overlay(shape.stroke(Color.dockAccent, lineWidth: 1).opacity(selected ? 1 : 0))
            .contentShape(shape)
        }
        .buttonStyle(.dockHover)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityLabel("Show details for \(title)")
    }
}

/// Static source mark: the item ships with Hermes Agent rather than being user-added.
struct IntegrationBuiltinPill: View {
    var body: some View {
        DockStatusPill(tone: .inactive, text: "Built-in", symbol: .shieldCheck)
            .help("Ships with Hermes Agent")
    }
}

/// Square glyph tile used as the leading icon on integration cards.
struct IntegrationCardIcon: View {
    let symbol: Ph

    var body: some View {
        DockIcon(symbol, size: 18, color: .dockPrimaryText)
            .frame(width: 36, height: 36)
            .background {
                DockThemeShape(cornerRadius: DockLayout.controlRadius)
                    .dockSurfaceFill(Color.dockSurface4, stroke: Color.dockBorderLight)
            }
    }
}

/// Stable category heading; inventory refreshes only replace the single-line summary.
struct IntegrationLibraryHeader: View {
    let title: String
    let summary: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).dockFont(.pageTitle, weight: .semibold).foregroundStyle(Color.dockPrimaryText)
            Text(summary).dockFont(.metadata).foregroundStyle(Color.dockMetadataText)
                .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
        }
        .dockPadding(.bottom, 6)
        .accessibilityElement(children: .combine)
    }
}
