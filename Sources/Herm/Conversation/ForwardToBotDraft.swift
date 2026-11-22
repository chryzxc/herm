import Combine
import Foundation

/// The unsent note and its submission can outlive the popover that edits them.
@MainActor
final class ForwardToBotDraft: ObservableObject {
    struct Key: Hashable {
        let sourceSession: String
        let messageID: UUID
        let recipientID: String
    }

    enum Submission: Equatable {
        case editing, sending
        case sent(UUID)
        case failed(String)
    }

    @Published var note = ""
    @Published private(set) var submission = Submission.editing

    func submit(messageText: String, to recipientID: String, using model: DockModel) {
        guard submission != .sending else { return }
        let submittedNote = note
        let typed = ComposerCompletion.pathifyingBareRefs(submittedNote.trimmingCharacters(in: .whitespacesAndNewlines))
        let body = "Forwarded message:\n\(messageText)"
        // A leading slash command receives the forwarded message as part of its argument.
        let text = typed.isEmpty ? body : "\(typed)\n\n\(body)"
        submission = .sending
        model.forwardMessage(text, toProfile: recipientID) { failure, _ in
            if let failure {
                self.submission = .failed(failure)
            } else {
                if self.note == submittedNote { self.note = "" }
                self.submission = .sent(UUID())
            }
        }
    }
}
