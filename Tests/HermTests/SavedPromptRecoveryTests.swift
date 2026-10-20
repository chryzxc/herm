import Foundation
import Testing

@testable import Herm

@MainActor
struct SavedPromptRecoveryTests {
    @Test func savedPromptsStayNamedAndDoNotReplaceTheCurrentDraft() {
        let store = QuickDraftStore()
        var saved = QuickDraftRecord(destination: QuickDestination(), text: "Saved prompt")
        saved.savedName = "Reusable"
        store.save(saved)
        let state = EdgeNotchState(store: store)
        state.selectQuickTarget(nil)
        #expect(state.quickDraft.isEmpty)
        #expect(state.recoverableDrafts.isEmpty)
        #expect(state.savedPrompts.map(\.id) == [saved.id])
        state.quickDraft = "Unsent current draft"
        let owner = state.captureRecord().destination
        state.restoreQuickDraft(saved)
        #expect(state.quickDraft == "Unsent current draft\n\nSaved prompt")
        #expect(state.captureRecord().destination == owner)
        #expect(store.records.first(where: { $0.id == saved.id })?.savedName == "Reusable")
        #expect(store.records.first(where: { $0.id == saved.id })?.text == "Saved prompt")
        #expect(!state.quickSending)
    }
}
