import SwiftUI

/// Native layout sizes, never a transform of the rendered workspace.
enum DockWorkspaceScale {
    static let window: CGFloat = 1.15

    static func points(_ value: CGFloat, scale: CGFloat) -> CGFloat {
        scale == 1 ? value : (value * scale).rounded()
    }
}

extension EnvironmentValues {
    @Entry var dockWorkspaceScale: CGFloat = 1
}

struct DockWindowWorkspace<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content.environment(\.dockWorkspaceScale, DockWorkspaceScale.window)
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

    func body(content: Content) -> some View {
        content.font(DockTypography.font(role, scale: scale, weight: weight))
    }
}

extension View {
    func dockFont(_ role: DockTypography.Role, weight: Font.Weight? = nil) -> some View {
        modifier(DockSemanticFont(role: role, weight: weight))
    }
}
