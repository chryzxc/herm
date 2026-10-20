import SwiftUI

/// Presentation lifetime belongs to the opt-in workspace, never DockModel.
struct RichReplySessionScope<Content: View>: View {
    @ObservedObject var model: DockModel
    let content: Content
    @StateObject private var state = RichReplyState()

    var body: some View {
        content
            .environment(\.richReplyState, state)
            .onChange(of: model.navigationSessionID) { _, _ in GeneratedHTMLCoordinator.shared.close() }
            .onChange(of: model.sessionProfileID) { _, _ in GeneratedHTMLCoordinator.shared.close() }
            .onDisappear { GeneratedHTMLCoordinator.shared.close() }
    }
}

/// Takes the model's values as plain inputs instead of observing DockModel:
/// observing re-rendered every mounted row (past their `.equatable()`) on
/// each of DockModel's publications.
struct RichReplyMessageScope<Content: View>: View {
    let model: DockModel
    let message: ChatMessage
    let destination: QuickDestination
    let reference: StoredMessageReference?
    let content: Content
    @Environment(\.richReplyState) private var state

    var body: some View {
        if let state {
            content
                .environment(\.richReplyContext, RichReplyContext(
                    model: model, message: message, destination: destination, reference: reference, state: state))
        } else { content }
    }
}
