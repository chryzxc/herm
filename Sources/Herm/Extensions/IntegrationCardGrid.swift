import SwiftUI

/// A responsive grid keeps each integration's identity, description and state together.
struct IntegrationInventoryList<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12, alignment: .top)], spacing: 12) {
            content
        }
    }
}

struct IntegrationInventoryRow<Icon: View>: View {
    let title: String
    let detail: String
    var status: (DockStatusTone, String)?
    var builtin = false
    var official = false
    var stars: Int?
    var update = false
    let selected: Bool
    let action: () -> Void
    @ViewBuilder let icon: Icon

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    icon.accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(title).dockFont(.body, weight: .semibold).foregroundStyle(Color.dockPrimaryText)
                            .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                        if !detail.isEmpty {
                            Text(detail).dockFont(.body).foregroundStyle(Color.dockSecondaryText)
                                .lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    DockIcon(.caretRight, size: 12, color: .dockMetadataText)
                }
                Spacer(minLength: 0)
                DockChipFlow(spacing: 8) {
                    if let status {
                        HStack(spacing: 5) {
                            DockStatusDot(tone: status.0, size: 6)
                            Text(status.1)
                        }
                    }
                    if builtin { Text("Built-in") }
                    if official { Text("Official") }
                    if let stars {
                        Label(stars.formatted(.number.notation(.compactName)), systemImage: "star")
                            .monospacedDigit().help("\(stars) GitHub stars")
                    }
                    if update {
                        Label("Update available", systemImage: "arrow.up.circle").foregroundStyle(Color.dockAccent)
                    }
                }
                .dockFont(.metadata).foregroundStyle(Color.dockMetadataText)
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
            .dockCard(padding: 14, isActive: selected)
            .contentShape(DockThemeShape(cornerRadius: DockLayout.paneRadius, role: .pane))
        }
        .buttonStyle(.dockHover)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityLabel("Show details for \(title)")
        .accessibilityValue(
            [status?.1, builtin ? "Built-in" : nil, update ? "Update available" : nil]
                .compactMap { $0 }.joined(separator: ", "))
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
        DockIcon(symbol, size: 18, color: .dockSecondaryText)
            .frame(width: 28, height: 28)
            .accessibilityHidden(true)
    }
}

/// Catalog artwork is optional. Failed or unsupported images retain the category glyph.
struct IntegrationArtwork: View {
    let url: URL?
    let symbol: Ph
    let size: CGFloat

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFit().dockPadding(5)
                    } else {
                        fallback
                    }
                }
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .dockWell(.sunken, radius: DockLayout.controlRadius)
        .accessibilityHidden(true)
    }

    private var fallback: some View {
        DockIcon(symbol, size: size * 0.5, color: .dockSecondaryText)
    }
}

struct IntegrationLibraryHeader: View {
    let title: String
    let summary: String
    let symbol: Ph
    var purpose = ""

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).dockFont(.pageTitle, weight: .semibold).foregroundStyle(Color.dockPrimaryText)
                if !purpose.isEmpty {
                    Text(purpose).dockFont(.body).foregroundStyle(Color.dockSecondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(summary).dockFont(.body).foregroundStyle(Color.dockMetadataText)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }
}

/// The grid remains usable beside details; narrow windows show one pane at a time.
struct IntegrationLibraryLayout<Header: View, Library: View, Inspector: View>: View {
    let showsDetail: Bool
    let close: () -> Void
    @ViewBuilder let header: Header
    @ViewBuilder let library: Library
    @ViewBuilder let inspector: Inspector

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                if !showsDetail || geometry.size.width >= 800 {
                    header.frame(maxWidth: .infinity, alignment: .leading)
                        .dockPadding(.horizontal, 24).dockPadding(.vertical, 20)
                    Color.dockBorderLight.frame(height: DockLayout.hairline)
                }
                AdaptiveSplit(
                    breakpoint: 800, primaryMinWidth: 300,
                    primaryIdealWidth: max(340, geometry.size.width - 520), secondaryMinWidth: 400,
                    showsSecondary: showsDetail, onBack: close
                ) {
                    library.dockPadding(20)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } secondary: {
                    inspector
                }
            }
        }
    }
}

struct IntegrationStatusPicker: View {
    @Binding var selection: IntegrationStatusFilter
    let options: [IntegrationStatusFilter]

    var body: some View {
        DockMenuPicker(title: selection.title, selection: $selection) {
            ForEach(options) { DockMenuOption($0.title, value: $0) }
        }.fixedSize()
    }
}

struct IntegrationFilterEmptyState: View {
    let clear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No integrations match this status").dockFont(.body, weight: .semibold)
            Text("Choose another status or show the full inventory.")
                .dockFont(.body).foregroundStyle(Color.dockSecondaryText)
            Button("Show all statuses", action: clear).buttonStyle(.dockSecondary)
        }.frame(maxWidth: .infinity, alignment: .leading).dockPadding(20)
    }
}
