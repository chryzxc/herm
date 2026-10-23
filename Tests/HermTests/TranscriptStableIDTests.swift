import Foundation
import Testing

@testable import Herm

@MainActor
struct TranscriptStableIDTests {
    @Test func rereadTranscriptKeepsKnownRowIDsAndNeverDuplicates() {
        let old = UUID()
        let first = ChatMessage(role: .user, text: "hi")
        let second = ChatMessage(role: .hermes, text: "new")
        let third = ChatMessage(role: .hermes, text: "split")
        // Rows 1 and 2 were one message before; now they are two.
        let restored = RestoredTranscript(
            messages: [first, second, third], pendingImages: [], rowIDs: [1: first.id, 2: third.id, 3: second.id],
            trailingActivity: [])

        let stable = DockModel.keepingMessageIDs(restored, previous: [1: old, 2: old])

        #expect(stable.messages.map(\.id) == [old, second.id, third.id])
        #expect(stable.rowIDs == [1: old, 2: third.id, 3: second.id])
    }
}
