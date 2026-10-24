import Foundation

extension DockModel {
    func generationContext(for destination: QuickDestination? = nil) -> RichGenerationContext {
        let captured = destination ?? RichReplyContext.destination(for: self)
        return richGenerationContextProvider?(captured)
            ?? RichGenerationContext(profileID: captured.profileID, sessionID: captured.sessionID)
    }
}
