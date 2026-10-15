import Foundation
import Testing

@testable import Herm

@MainActor
struct QuickActionPreparationTests {
  @Test func unboundActionKeepsMaterialAndRecipientAndIgnoresDoubleApply() {
    let drafts = QuickDraftStore()
    let state = EdgeNotchState(store: drafts)
    state.switchQuickProfile("research")
    state.quickDraft = "Captured text"
    state.quickSources = ["https://example.com/source"]
    let before = state.captureRecord()
    state.showingActions = true
    let action = SavedQuickAction(title: "Summarize", instructions: "Summarize evidence")
    #expect(state.applyQuickAction(action))
    let result = state.captureRecord()
    #expect(result.destination == before.destination)
    #expect(result.text == "Summarize evidence\n\nCaptured text")
    #expect(result.sources == before.sources)
    #expect(!state.applyQuickAction(action))
    #expect(state.quickDraft == result.text)
    #expect(result.delivery == .editing)
  }

  @Test func boundActionRequiresConfirmationAndKeepsTheOriginalDraft() {
    let drafts = QuickDraftStore()
    let state = EdgeNotchState(store: drafts)
    state.switchQuickProfile("coding")
    state.quickDraft = "Unfinished coding material"
    state.quickSources = ["https://example.com/patch"]
    let original = state.captureRecord()
    let destination = QuickDestination(profileID: "research", sessionID: "other", title: "Research")
    let action = SavedQuickAction(
      title: "Compare", instructions: "Compare sources", destination: destination)
    state.showingActions = true
    #expect(!state.applyQuickAction(action))
    #expect(state.quickDraft == original.text)
    #expect(state.applyQuickAction(action, confirmDestinationChange: true))
    let prepared = state.captureRecord()
    #expect(prepared.id != original.id)
    #expect(prepared.destination.key == destination.key)
    #expect(prepared.text == action.instructions)
    #expect(prepared.files.isEmpty && prepared.sources.isEmpty)
    let retained = drafts.records.first { $0.id == original.id }
    #expect(retained?.text == original.text)
    #expect(retained?.sources == original.sources)
  }

  @Test func preparationAndUncertainDeliveryPreventActionApplication() {
    let state = EdgeNotchState()
    let action = SavedQuickAction(title: "Review", instructions: "Review work")
    state.showingActions = true
    state.quickPreparing = 1
    #expect(!state.applyQuickAction(action))
    state.quickPreparing = 0
    state.quickSending = true
    #expect(!state.applyQuickAction(action))
    state.quickSending = false
    var draft = QuickDraftRecord(
      destination: QuickDestination(profileID: "coding"), text: "Uncertain")
    draft.delivery = .needsReview
    state.restoreQuickDraft(draft)
    #expect(!state.applyQuickAction(action))
    #expect(state.quickDraft == "Uncertain")
  }
}
