import SwiftUI

/// A themed replacement for SwiftUI's `Menu`. The native menu is drawn by
/// AppKit with system colors and can ignore the selected Dock theme, so this
/// presents the same content in a popover painted with theme tokens.
///
/// Content is written like a `Menu`: `Button`s become rows and dismiss the
/// popover, `Toggle`s become checkable rows, nested `DockMenu`s open a
/// submenu, and `DockMenuSection` / `DockMenuOption` cover section headers
/// and picker-style choices.
struct DockMenu<Label: View, Content: View>: View {
    private let content: Content
    private let label: Label
    @State private var isOpen = false
    @State private var isHovered = false
    @Environment(\.dockMenuDepth) private var depth
    @Environment(\.dockMenuDismiss) private var dismissParent
    @Environment(\.isEnabled) private var isEnabled

    init(@ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label) {
        self.content = content()
        self.label = label()
    }

    var body: some View {
        trigger
            .opacity(isEnabled ? 1 : 0.4)
            .popover(isPresented: $isOpen, arrowEdge: depth > 0 ? .trailing : .bottom) {
                DockMenuPanel(content: content)
                    .environment(\.dockMenuDepth, depth + 1)
                    .environment(\.dockMenuDismiss, { isOpen = false; dismissParent() })
            }
    }

    @ViewBuilder
    private var trigger: some View {
        if depth > 0 {
            DockMenuRowChrome(isHovered: (isHovered || isOpen) && isEnabled, tint: nil) {
                HStack(spacing: 8) {
                    label
                    Spacer(minLength: 12)
                    DockIcon(.caretRight, size: 10, color: Color.dockMetadataText)
                }
            }
            .onHover { isHovered = $0 }
            .onTapGesture { if isEnabled { isOpen.toggle() } }
            .accessibilityAddTraits(.isButton)
        } else {
            Button { isOpen.toggle() } label: { label.contentShape(Rectangle()) }
                .buttonStyle(.dockHover)
        }
    }
}

extension DockMenu where Label == Text {
    init(_ title: some StringProtocol, @ViewBuilder content: () -> Content) {
        self.init(content: content) { Text(title) }
    }
}

extension DockMenu where Label == SwiftUI.Label<Text, Image> {
    init(_ title: some StringProtocol, icon: Ph, @ViewBuilder content: () -> Content) {
        self.init(content: content) { SwiftUI.Label(title, icon: icon) }
    }
}

/// A section header inside a `DockMenu`.
struct DockMenuSection<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.dockMetadataText)
                .padding(.horizontal, 8)
                .padding(.top, 6)
                .padding(.bottom, 2)
            content
        }
    }
}

/// A checkable choice inside a `DockMenu` that is not tied to a `DockMenuPicker`.
struct DockMenuCheckRow: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                DockIcon(.check, size: 12, color: Color.dockPrimaryText).opacity(isSelected ? 1 : 0).frame(width: 14)
                Text(title).lineLimit(1)
            }
        }
    }
}

/// A choice inside a `DockMenuPicker`; selection comes from the environment.
struct DockMenuOption<Value: Hashable>: View {
    let title: String
    let value: Value
    @Environment(\.dockMenuSelection) private var selection

    init(_ title: String, value: Value) {
        self.title = title
        self.value = value
    }

    var body: some View {
        DockMenuCheckRow(title: title, isSelected: selection?.isSelected(AnyHashable(value)) ?? false) {
            selection?.select(AnyHashable(value))
        }
    }
}

/// A themed pop-up picker. `title` is the label of the current selection;
/// `label` puts a leading caption in front, like a form row.
struct DockMenuPicker<Value: Hashable, Content: View>: View {
    var label: String?
    let title: String
    @Binding var selection: Value
    let content: Content

    init(_ label: String? = nil, title: String, selection: Binding<Value>, @ViewBuilder content: () -> Content) {
        self.label = label
        self.title = title
        self._selection = selection
        self.content = content()
    }

    var body: some View {
        let menu = DockMenu {
            DockMenuChoices(selection: $selection) { content }
        } label: {
            HStack(spacing: 6) {
                Text(title)
                    .foregroundStyle(Color.dockPrimaryText)
                    .lineLimit(1)
                DockIcon(.caretUpDown, size: 11, color: Color.dockMetadataText)
            }
        }
        .fixedSize()
        if let label { LabeledContent(label) { menu } } else { menu }
    }
}

/// Scopes the `DockMenuOption`s inside it to one selection binding.
struct DockMenuChoices<Value: Hashable, Content: View>: View {
    @Binding var selection: Value
    let content: Content

    init(selection: Binding<Value>, @ViewBuilder content: () -> Content) {
        self._selection = selection
        self.content = content()
    }

    var body: some View {
        content.environment(\.dockMenuSelection, DockMenuSelection(
            isSelected: { $0 == AnyHashable(selection) },
            select: { if let value = $0.base as? Value { selection = value } }
        ))
    }
}

/// A themed segmented control for choosing between a few options inline.
struct DockSegmentedPicker<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, title: String)]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options.indices, id: \.self) { index in
                DockTabButton(title: options[index].title, isSelected: selection == options[index].value) {
                    selection = options[index].value
                }
            }
        }
    }
}

struct DockMenuSelection {
    let isSelected: (AnyHashable) -> Bool
    let select: (AnyHashable) -> Void
}

private struct DockMenuDismissKey: EnvironmentKey { nonisolated(unsafe) static var defaultValue: () -> Void = {} }
private struct DockMenuDepthKey: EnvironmentKey { static let defaultValue = 0 }
private struct DockMenuSelectionKey: EnvironmentKey { nonisolated(unsafe) static var defaultValue: DockMenuSelection? = nil }

extension EnvironmentValues {
    fileprivate var dockMenuDismiss: () -> Void {
        get { self[DockMenuDismissKey.self] }
        set { self[DockMenuDismissKey.self] = newValue }
    }
    fileprivate var dockMenuDepth: Int {
        get { self[DockMenuDepthKey.self] }
        set { self[DockMenuDepthKey.self] = newValue }
    }
    fileprivate var dockMenuSelection: DockMenuSelection? {
        get { self[DockMenuSelectionKey.self] }
        set { self[DockMenuSelectionKey.self] = newValue }
    }
}

private struct DockMenuHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct DockMenuPanel<Content: View>: View {
    let content: Content
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 1) { content }
                .buttonStyle(DockMenuRowStyle())
                .toggleStyle(DockMenuToggleStyle())
                .labelStyle(DockMenuLabelStyle())
                .frame(minWidth: 190, maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
                .padding(6)
                .background(GeometryReader { Color.clear.preference(key: DockMenuHeightKey.self, value: $0.size.height) })
        }
        .onPreferenceChange(DockMenuHeightKey.self) { contentHeight = $0 }
        .frame(height: contentHeight > 0 ? min(contentHeight, 440) : nil)
        .background { Color.dockOpaqueCanvas; Color.dockSurface }
    }
}

private struct DockMenuRowChrome<Content: View>: View {
    let isHovered: Bool
    let tint: Color?
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .font(.system(size: 12))
            .foregroundStyle(tint ?? Color.dockPrimaryText)
            .frame(maxWidth: 340, alignment: .leading)
            .padding(.horizontal, 8)
            .frame(minHeight: 26)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DockLayout.controlRadius - 2, style: .continuous)
                    .fill(isHovered ? Color.dockAccent.opacity(0.18) : Color.clear)
            )
            .contentShape(Rectangle())
    }
}

private struct DockMenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { DockMenuRowButton(configuration: configuration) }
}

private struct DockMenuRowButton: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.dockMenuDismiss) private var dismiss
    @State private var isHovered = false

    var body: some View {
        DockMenuRowChrome(
            isHovered: (isHovered || configuration.isPressed) && isEnabled,
            tint: configuration.role == .destructive ? Color.dockDestructive : nil
        ) { configuration.label }
            .opacity(isEnabled ? 1 : 0.4)
            .onHover { isHovered = $0 }
            // A gesture on the label competes with the Button's own click and can
            // swallow its action, so dismiss from the pressed -> released
            // transition instead, a turn later so the action has already run.
            .onChange(of: configuration.isPressed) { wasPressed, pressed in
                if wasPressed, !pressed, isEnabled, isHovered { DispatchQueue.main.async { dismiss() } }
            }
    }
}

private struct DockMenuToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 8) {
                DockIcon(.check, size: 12, color: Color.dockPrimaryText).opacity(configuration.isOn ? 1 : 0).frame(width: 14)
                configuration.label
            }
        }
        .buttonStyle(DockMenuRowStyle())
    }
}

private struct DockMenuLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon.frame(width: 16)
            configuration.title
        }
    }
}
