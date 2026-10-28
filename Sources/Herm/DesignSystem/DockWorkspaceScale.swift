import SwiftUI

/// Native layout sizes, never a transform of the rendered workspace.
enum DockWorkspaceScale {
    static let window: CGFloat = 1
    static let preferenceKey = "herm.textSize"
    static let defaultTextSize = 1.1

    static func supportedTextSize(_ value: Double) -> Double {
        [1.0, defaultTextSize, 1.2, 1.3].contains(value) ? value : defaultTextSize
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

// Apply only at independent presentation roots; nested hosts inherit their parent's scale.
extension View {
    func dockPreferredTextSize() -> some View {
        DockWindowWorkspace { self }
    }
}
