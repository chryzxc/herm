import Foundation

/// Value inputs keep prompt rows independent of unrelated model publications.
struct ConversationPromptState: Equatable {
    let sessionID: String?
    let status: HermesStatus
    let approval: ApprovalPresentation?
    let approvalTitle: String?
    let approvalText: String?
    let approvalPending: Bool
    let question: String?
    let choices: [String]
    let multiSelect: Bool
    let progress: String?
    let clarificationID: String?
    let clarificationPending: Bool
    let restoring: Bool
    let prompt: ValuePrompt?
    let promptPending: Bool
    let promptError: String?

    @MainActor init(model: DockModel) {
        sessionID = model.sessionID
        status = model.status
        approval = model.approvalDetails
        approvalTitle = model.approvalTitle
        approvalText = model.approvalText
        approvalPending = model.isRespondingToApproval
        question = model.clarificationQuestion
        choices = model.clarificationChoices
        multiSelect = model.clarificationMultiSelect
        progress = model.clarificationProgress
        clarificationID = model.clarificationRequestID
        clarificationPending = model.isRespondingToClarification
        restoring = model.isRestoringSession
        prompt = model.valuePrompt
        promptPending = model.isRespondingToValuePrompt
        promptError = model.valuePromptError
    }
    @MainActor func matchesApproval(in model: DockModel) -> Bool {
        sessionID == model.sessionID && approval == model.approvalDetails
            && approvalTitle == model.approvalTitle && approvalText == model.approvalText
            && !model.isRespondingToApproval
    }

    @MainActor func matchesClarification(in model: DockModel) -> Bool {
        sessionID == model.sessionID && clarificationID == model.clarificationRequestID
            && question == model.clarificationQuestion && choices == model.clarificationChoices
            && !model.isRespondingToClarification && !model.isRestoringSession
    }

    @MainActor func matchesPrompt(in model: DockModel) -> Bool {
        sessionID == model.sessionID && prompt?.requestID == model.valuePrompt?.requestID
            && !model.isRespondingToValuePrompt
    }
}
