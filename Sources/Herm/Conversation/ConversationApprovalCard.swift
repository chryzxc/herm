import Combine
import SwiftUI

struct VoiceConversationPromptRows: View {
    let model: DockModel
    let conversationMetrics: ConversationWorkspaceMetrics
    let showsClarification: Bool
    @State private var records: [ConversationApproval]
    @State private var answers: [AttentionRequest: AttentionAnswerState]

    init(model: DockModel, conversationMetrics: ConversationWorkspaceMetrics, showsClarification: Bool) {
        self.model = model
        self.conversationMetrics = conversationMetrics
        self.showsClarification = showsClarification
        _records = State(initialValue: model.conversationApprovals)
        _answers = State(initialValue: model.attentionAnswers)
    }

    var body: some View {
        let approval = model.voiceApproval(records: records, answers: answers)
        ConversationPromptRows(
            model: model, conversationMetrics: conversationMetrics, showsClarification: showsClarification,
            exclusive: true, conversationApproval: approval?.record, approvalAnswer: approval?.answer,
            transcriptMode: true
        )
        .onReceive(model.$conversationApprovals) { records = $0 }
        .onReceive(model.$attentionAnswers) { answers = $0 }
    }
}
