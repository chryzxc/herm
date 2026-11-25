import Combine
import Foundation

extension DockModel {
    func makeComposerPresentationChanges() -> AnyPublisher<Void, Never> {
        Publishers.MergeMany(
            Self.change($sessionID), Self.change($sessionStorageID), Self.change($sessionTranscriptLoadState),
            Self.change($isRestoringSession), Self.change($status), Self.change($isSending),
            Self.change($interruptState),
            Self.change($composerFocusRequest), Self.change($pendingImages), Self.change($pendingPDFURLs),
            Self.change($attachedContexts), Self.change($replyQuote), Self.change($extractingImageTextIDs),
            Self.change($pendingPDFError), Self.change($pendingAttachmentError), Self.change($steeringError),
            Self.change($clarificationResponseError), Self.change($queuedPrompts),
            Self.change($redirectingPrompts), queuedSubmissionChanges.eraseToAnyPublisher(),
            Self.change($runtimeConfiguration), Self.change($runtimeModelOptions),
            Self.change($isLoadingRuntimeModelOptions), Self.change($runtimeModelOptionsError),
            Self.change($sessionModelOptionID), Self.change($sessionModelValue), Self.change($defaultModelOptionID),
            Self.change($isUpdatingSessionModel), Self.change($isUpdatingSessionFast),
            Self.change($sessionReasoningVariant), Self.change($defaultReasoningVariant),
            Self.change($draftReasoningVariant), Self.change($isUpdatingSessionReasoning)
        ).debounce(for: .milliseconds(1), scheduler: DispatchQueue.main).eraseToAnyPublisher()
    }

    var composerModelLabelChanges: AnyPublisher<Void, Never> {
        Publishers.MergeMany(
            Self.change($sessionID), Self.change($sessionModelValue), Self.change($sessionFastEnabled),
            Self.change($sessionReasoningWire), Self.change($sessionReasoningStale), Self.change($effortCatalog),
            Self.change($isUpdatingSessionModel), Self.change($isUpdatingSessionReasoning),
            Self.change($runtimeModelOptionsError), Self.change($sessionReasoningVariant),
            Self.change($defaultReasoningVariant), Self.change($draftReasoningVariant)
        ).debounce(for: .milliseconds(1), scheduler: DispatchQueue.main).eraseToAnyPublisher()
    }
}
