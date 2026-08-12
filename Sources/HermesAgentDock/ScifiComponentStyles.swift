import SwiftUI

/// Shared interaction and input treatments derived from DESIGN.md's glass
/// button and input specifications. Keeping them here prevents native control
/// styles from leaking into individual Control, chat, or Activity views.
struct ScifiPressButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.86 : 1)
            .animation(reduceMotion ? nil : .scifiEase(duration: 0.16), value: configuration.isPressed)
    }
}

/// The single filled action treatment from DESIGN.md. Use it only for the
/// primary action in a section; secondary actions stay text-on-glass.
struct ScifiPrimaryButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(Color.scifiBg)
            .padding(.horizontal, 12)
            .frame(minHeight: 36)
            .background(Color.scifiAccent.opacity(configuration.isPressed ? 0.82 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .shadow(color: Color.scifiAccent.opacity(configuration.isPressed ? 0 : 0.14), radius: 6)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(reduceMotion ? nil : .scifiEase(duration: 0.16), value: configuration.isPressed)
    }
}

struct ScifiGlassTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .font(.body)
            .foregroundStyle(Color.scifiFg)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(minHeight: 36)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    // The shared canvas keeps inputs consistent across panes;
                    // the plain field style removes the warm native field fill.
                    .fill(Color.scifiControlSurface)
                    .stroke(Color.scifiBorder, lineWidth: 0.5)
            )
    }
}

/// A compact in-place pending treatment for actions that call Hermes. The
/// button retains its footprint so the surrounding control surface never jumps.
struct ScifiActionLabel: View {
    let title: String
    let pendingTitle: String
    let isPending: Bool
    var tint: Color = .scifiAccent

    var body: some View {
        HStack(spacing: 6) {
            if isPending {
                ProgressView()
                    .controlSize(.small)
                    .tint(tint)
            }
            Text(isPending ? pendingTitle : title)
        }
        .lineLimit(1)
        .contentTransition(.opacity)
    }
}

extension ButtonStyle where Self == ScifiPressButtonStyle {
    static var scifiPress: Self { Self() }
}

extension ButtonStyle where Self == ScifiPrimaryButtonStyle {
    static var scifiPrimary: Self { Self() }
}

extension TextFieldStyle where Self == ScifiGlassTextFieldStyle {
    static var scifiGlass: Self { Self() }
}

extension View {
    /// Level 1 glass pane: reserved for a focused, interactive unit of work.
    func scifiGlassPane() -> some View {
        self
            .background(Color.scifiSurface)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.scifiBorderStrong, lineWidth: 0.5))
    }

    /// Divider-led rows keep operational lists dense without turning each item
    /// into a separate card.
    func scifiListRow(isHighlighted: Bool = false) -> some View {
        self
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
            .background(isHighlighted ? Color.scifiAccent.opacity(0.07) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(alignment: .bottom) { Color.scifiBorderLight.frame(height: 0.5) }
            .contentShape(Rectangle())
    }
}
