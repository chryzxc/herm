import SwiftUI

/// Presentation-only state; the action keeps ownership of errors and authoritative data.
@MainActor
final class DockAsyncAction: ObservableObject {
    @Published private(set) var isPending = false

    @discardableResult
    func perform(_ action: @escaping @MainActor () async -> Void) -> Task<Void, Never>? {
        guard !isPending else { return nil }
        isPending = true
        return Task { @MainActor in
            defer { isPending = false }
            await action()
        }
    }
}

/// For async controls that remain mounted while working. Confirmation/menu actions
/// must expose pending state on their persistent parent instead.
struct DockAsyncButton<Label: View>: View {
    let role: ButtonRole?
    let action: @MainActor () async -> Void
    let label: Label
    @StateObject private var activity: DockAsyncAction

    init(
        role: ButtonRole? = nil, activity: DockAsyncAction = DockAsyncAction(),
        action: @escaping @MainActor () async -> Void,
        @ViewBuilder label: () -> Label
    ) {
        _activity = StateObject(wrappedValue: activity)
        self.role = role
        self.action = action
        self.label = label()
    }

    var body: some View {
        Button(role: role) {
            activity.perform(action)
        } label: {
            HStack(spacing: 6) {
                label
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 12, height: 12)
                    .opacity(activity.isPending ? 1 : 0)
                    .accessibilityHidden(true)
            }
        }
        .disabled(activity.isPending)
        .accessibilityValue(activity.isPending ? "In progress" : "")
    }
}

extension DockAsyncButton where Label == Text {
    init(_ title: String, role: ButtonRole? = nil, action: @escaping @MainActor () async -> Void) {
        self.init(role: role, action: action) { Text(title) }
    }
}
