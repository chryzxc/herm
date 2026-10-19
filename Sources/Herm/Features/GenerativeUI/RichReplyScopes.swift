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

struct RichReplyMessageScope<Content: View>: View {
    @ObservedObject var model: DockModel
    let message: ChatMessage
    let content: Content
    @Environment(\.richReplyState) private var state

    var body: some View {
        if let state {
            content
                .environment(\.richReplyContext, RichReplyContext(model: model, message: message, state: state))
                .onChange(of: model.storedMessageReferences[message.id]) { _, reference in
                    let destination = QuickDestination(profileID: model.sessionProfileID ?? model.profileScopeID,
                        sessionID: model.navigationSessionID)
                    _ = state.sourceKey(session: destination.sessionKey, message: message, reference: reference)
                }
        } else { content }
    }
}
