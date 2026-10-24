import SwiftUI

/// Forms are active only when the original stored message is loaded in its owning conversation.
struct RichArtifactPreview: View {
    @ObservedObject var model: DockModel
    let generated: RichGeneratedArtifact
    @AppStorage(GenerativeUIIntegration.preferenceKey) private var enabled = true
    @Environment(\.richReplyState) private var state

    private var context: RichReplyContext? {
        let reference = generated.reference
        guard let state, model.navigationSessionID == reference.sessionID,
            (model.sessionProfileID ?? model.profileScopeID) == reference.profileID,
            let message = model.messages.first(where: { message in
                guard let stored = model.storedMessageReferences[message.id] else { return false }
                if let uid = reference.messageUID { return stored.uid == uid }
                return stored.rowID == reference.rowID
            }),
            RichDocument(message.text).segments.contains(where: {
                if case .surface(let surface, let source) = $0 {
                    return surface.id == reference.surfaceID
                        && RichArtifactReference.digest(source) == reference.sourceDigest
                }
                return false
            })
        else { return nil }
        return RichReplyContext(model: model, message: message, state: state)
    }
    var body: some View {
        Group {
            if enabled {
                RichSurfaceView(surface: generated.surface, source: generated.source)
                    .environment(\.richArtifactReference, generated.reference)
                    .environment(\.richReplyContext, context)
            } else {
                MarkdownMessageView(markdown: generated.surface.plainText)
            }
        }
    }
}
