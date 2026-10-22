import SwiftUI

/// The single sheet chrome for every custom modal: a header with an optional
/// icon tile, title, subtitle, and close button; a padded body; and a tinted
/// footer bar for actions. Sheets supply only their content and actions so
/// spacing, background, and button treatments never drift between modals.
struct DockModal<Content: View, Footer: View>: View {
    let icon: Ph?
    let badge: AnyView?
    let title: String
    let subtitle: String?
    /// Fixed sheet width; `nil` lets resizable sheets set their own frame.
    let width: CGFloat?
    /// Body inset; scrolling bodies pass 0 and pad inside the scroll view.
    let contentPadding: CGFloat
    let content: Content
    let footer: Footer
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isEnabled) private var isEnabled

    init(
        icon: Ph? = nil,
        badge: AnyView? = nil,
        title: String,
        subtitle: String? = nil,
        width: CGFloat? = 460,
        contentPadding: CGFloat = 20,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) {
        self.icon = icon
        self.badge = badge
        self.title = title
        self.subtitle = subtitle
        self.width = width
        self.contentPadding = contentPadding
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Color.dockBorderLight.frame(height: DockLayout.hairline)
            VStack(alignment: .leading, spacing: 16) { content }
                .padding(contentPadding)
                .frame(maxWidth: .infinity, maxHeight: width == nil ? .infinity : nil, alignment: .topLeading)
            if Footer.self != EmptyView.self {
                Color.dockBorderLight.frame(height: DockLayout.hairline)
                HStack(spacing: DockLayout.controlGap) { footer }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity)
                    .dockPaneTint(Color.dockSurface.opacity(0.35))
            }
        }
        .frame(width: width)
        .background(DockPaneBackground())
        .dockThemedRoot()
        .onExitCommand { if isEnabled { dismiss() } }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            if let badge {
                badge
            } else if let icon {
                DockIcon(icon)
                    .dockFont(size: 15, weight: .semibold)
                    .foregroundStyle(Color.dockAccent)
                    .frame(width: 32, height: 32)
                    .background(
                        RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous)
                            .fill(Color.dockAccent.opacity(0.14))
                    )
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .dockFont(size: 15, weight: .semibold)
                    .foregroundStyle(Color.dockPrimaryText)
                    .lineLimit(2)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .dockFont(size: 12)
                        .foregroundStyle(Color.dockSecondaryText)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            Button { dismiss() } label: {
                DockIcon(.x)
                    .dockFont(size: 12, weight: .semibold)
                    .foregroundStyle(Color.dockSecondaryText)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.dockPress)
            .help("Close")
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }
}

extension DockModal where Footer == EmptyView {
    init(
        icon: Ph? = nil,
        badge: AnyView? = nil,
        title: String,
        subtitle: String? = nil,
        width: CGFloat? = 460,
        contentPadding: CGFloat = 20,
        @ViewBuilder content: () -> Content
    ) {
        self.init(icon: icon, badge: badge, title: title, subtitle: subtitle, width: width, contentPadding: contentPadding, content: content) { EmptyView() }
    }
}

/// Uppercase section label that groups related fields inside a modal.
@MainActor
@ViewBuilder
func modalSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 9) {
        Text(title)
            .dockFont(size: 10, weight: .semibold, design: .monospaced)
            .tracking(1.1)
            .foregroundStyle(Color.dockMetadataText)
        content()
    }
}

/// A field title with an optional inline hint above its control.
@MainActor
@ViewBuilder
func labeledField<Content: View>(_ title: String, hint: String? = nil, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 5) {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title)
                .dockFont(size: 12, weight: .semibold)
                .foregroundStyle(Color.dockPrimaryText)
            if let hint {
                Text(hint)
                    .dockFont(size: 10)
                    .foregroundStyle(Color.dockMetadataText)
                    .lineLimit(1)
            }
        }
        content()
    }
}

/// Small explanatory or status text under a modal's fields.
struct ModalNote: View {
    let text: String
    var icon: Ph? = nil
    var tone: Color = .dockMetadataText

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let icon { DockIcon(icon).dockFont(size: 11) }
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .dockFont(size: 11)
        .foregroundStyle(tone)
    }
}

/// The standard footer: Cancel plus one primary action, right-aligned.
@MainActor
@ViewBuilder
func modalActions(primaryTitle: String, pendingTitle: String = "Saving…", isDisabled: Bool, isPending: Bool, onCancel: @escaping () -> Void, onPrimary: @escaping () -> Void) -> some View {
    Spacer()
    Button("Cancel", action: onCancel)
        .keyboardShortcut(.cancelAction)
        .buttonStyle(DockModalButtonStyle(isPrimary: false))
    Button(action: onPrimary) {
        DockActionLabel(title: primaryTitle, pendingTitle: pendingTitle, isPending: isPending, tint: .dockOnAccentText)
    }
    .keyboardShortcut(.defaultAction)
    .buttonStyle(DockModalButtonStyle(isPrimary: true))
    .disabled(isDisabled)
}

/// Footer buttons shared by every modal: equal minimum width, a solid accent
/// fill for the primary action and a quiet outline for Cancel, all from theme tokens.
struct DockModalButtonStyle: ButtonStyle {
    let isPrimary: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = DockThemeShape(cornerRadius: DockLayout.controlRadius)
        configuration.label
            .dockFont(size: 13, weight: .semibold)
            .foregroundStyle(isPrimary ? Color.dockOnAccentText : Color.dockPrimaryText)
            .padding(.horizontal, 16)
            .frame(minWidth: 92, minHeight: DockLayout.controlHeight)
            .background {
                if DockThemeStyle.current.material == .glass {
                    Color.clear.dockLiquidGlass(shape, tint: isPrimary ? Color.dockAccent.opacity(0.88) : nil, interactive: true, elevated: true)
                } else {
                    shape.fill(isPrimary ? Color.dockAccent : Color.dockControlSurface)
                        .overlay(shape.stroke(isPrimary ? Color.clear : Color.dockBorder, lineWidth: DockLayout.outline))
                        .overlay(shape.fill(Color.black.opacity(configuration.isPressed ? 0.12 : 0)))
                }
            }
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.42)
    }
}
