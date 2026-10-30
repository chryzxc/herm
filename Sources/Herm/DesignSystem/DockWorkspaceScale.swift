import SwiftUI

/// Native layout sizes, never a transform of the rendered workspace.
enum DockWorkspaceScale {
    static let window: CGFloat = 1
    static let preferenceKey = "herm.textSize"
    static let defaultTextSize = 1.1
    /// Density "Compact": smaller text and icons, plus tighter padding via `spacing`.
    static let compactTextSize = 0.9
    static let compactSpacing: CGFloat = 0.8

    static func supportedTextSize(_ value: Double) -> Double {
        value < defaultTextSize ? compactTextSize : defaultTextSize
    }

    static func isCompact(_ scale: CGFloat) -> Bool { scale < 1 }

    /// Margins and padding: unchanged by default, tightened in Compact.
    static func spacing(_ value: CGFloat, scale: CGFloat) -> CGFloat {
        isCompact(scale) ? (value * compactSpacing).rounded() : value
    }

    static func points(_ value: CGFloat, scale: CGFloat) -> CGFloat {
        scale == 1 ? value : (value * scale).rounded()
    }
}

extension EnvironmentValues {
    @Entry var dockWorkspaceScale: CGFloat = 1
}

struct DockWindowWorkspace<Content: View>: View {
    @AppStorage(DockWorkspaceScale.preferenceKey) private var textSize = DockWorkspaceScale.defaultTextSize
    @ViewBuilder var content: Content

    var body: some View {
        content.environment(\.dockWorkspaceScale, CGFloat(DockWorkspaceScale.supportedTextSize(textSize)))
    }
}

private struct DockScaledFont: ViewModifier {
    @Environment(\.dockWorkspaceScale) private var scale
    let size: CGFloat
    let weight: Font.Weight
    let design: Font.Design

    func body(content: Content) -> some View {
        content.font(.system(size: DockWorkspaceScale.points(size, scale: scale), weight: weight, design: design))
    }
}

extension View {
    func dockFont(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> some View {
        modifier(DockScaledFont(size: size, weight: weight, design: design))
    }
}

private struct DockSemanticFont: ViewModifier {
    @Environment(\.dockWorkspaceScale) private var scale
    let role: DockTypography.Role
    let weight: Font.Weight?
    let design: Font.Design?

    func body(content: Content) -> some View {
        content.font(DockTypography.font(role, scale: scale, weight: weight, design: design))
    }
}

extension View {
    func dockFont(_ role: DockTypography.Role, weight: Font.Weight? = nil, design: Font.Design? = nil) -> some View {
        modifier(DockSemanticFont(role: role, weight: weight, design: design))
    }
}

private struct DockScaledPadding: ViewModifier {
    @Environment(\.dockWorkspaceScale) private var scale
    let insets: EdgeInsets?
    let edges: Edge.Set
    let length: CGFloat?

    func body(content: Content) -> some View {
        if let insets {
            content.padding(
                EdgeInsets(
                    top: DockWorkspaceScale.spacing(insets.top, scale: scale),
                    leading: DockWorkspaceScale.spacing(insets.leading, scale: scale),
                    bottom: DockWorkspaceScale.spacing(insets.bottom, scale: scale),
                    trailing: DockWorkspaceScale.spacing(insets.trailing, scale: scale)))
        } else {
            content.padding(edges, length.map { DockWorkspaceScale.spacing($0, scale: scale) })
        }
    }
}

extension View {
    /// `padding` that follows the Density setting. Use it for every margin and inset.
    nonisolated func dockPadding(_ edges: Edge.Set = .all, _ length: CGFloat? = nil) -> some View {
        modifier(DockScaledPadding(insets: nil, edges: edges, length: length))
    }

    nonisolated func dockPadding(_ length: CGFloat) -> some View {
        modifier(DockScaledPadding(insets: nil, edges: .all, length: length))
    }

    nonisolated func dockPadding(_ insets: EdgeInsets) -> some View {
        modifier(DockScaledPadding(insets: insets, edges: .all, length: nil))
    }
}

// Apply only at independent presentation roots; nested hosts inherit their parent's scale.
extension View {
    func dockPreferredTextSize() -> some View {
        DockWindowWorkspace { self }
    }
}
