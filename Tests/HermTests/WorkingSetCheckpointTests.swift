import Foundation
import Testing

@testable import Herm

@MainActor
struct WorkingSetCheckpointTests {
  @Test func restoreUsesTheExactDraftAndPreservesTheCurrentOne() {
    let drafts = QuickDraftStore()
    let destination = QuickDestination(
      profileID: "research", sessionID: "research-session", title: "Research")
    let saved = QuickDraftRecord(destination: destination, text: "Exact checkpoint draft")
    let another = QuickDraftRecord(
      destination: destination, text: "Another draft with the same recipient")
    drafts.save(saved)
    drafts.save(another)
    let state = EdgeNotchState(store: drafts)
    state.switchQuickProfile("coding")
    state.quickDraft = "Current unsent code review"
    let current = state.captureRecord()
    let set = WorkingSet(name: "Research", destinations: [destination])
    let checkpoint = WorkingSetCheckpoint(
      workingSetID: set.id, note: "Continue the comparison",
      destinationKey: destination.key, draftID: saved.id)
    #expect(state.restoreCheckpoint(checkpoint, from: set))
    #expect(state.captureRecord().id == saved.id)
    #expect(state.quickDraft == saved.text)
    #expect(drafts.records.first { $0.id == current.id }?.text == current.text)
  }

  @Test func missingDraftNeverSubstitutesAnotherDraftAtTheSameDestination() {
    let drafts = QuickDraftStore()
    let destination = QuickDestination(
      profileID: "research", sessionID: "owner", title: "Research", projectPath: "/tmp/project")
    let unrelated = QuickDraftRecord(destination: destination, text: "Unrelated draft")
    drafts.save(unrelated)
    let state = EdgeNotchState(store: drafts)
    let set = WorkingSet(name: "Research", destinations: [destination])
    let checkpoint = WorkingSetCheckpoint(
      workingSetID: set.id, note: "Resume the sources",
      destinationKey: destination.key, draftID: UUID())
    #expect(state.restoreCheckpoint(checkpoint, from: set))
    #expect(state.quickDraft.isEmpty)
    #expect(state.captureRecord().id != unrelated.id)
    #expect(state.captureRecord().destination.key == destination.key)
    #expect(state.quickResult?.contains("Saved draft unavailable") == true)
    #expect(drafts.records.contains { $0.id == unrelated.id })
  }

  @Test func unavailableMembershipAndBusyStateDoNotRetarget() {
    let state = EdgeNotchState()
    state.switchQuickProfile("coding")
    state.quickDraft = "Keep this"
    let original = state.captureRecord()
    let set = WorkingSet(name: "Empty", destinations: [])
    let checkpoint = WorkingSetCheckpoint(
      workingSetID: set.id, note: "Note", destinationKey: "missing")
    #expect(!state.restoreCheckpoint(checkpoint, from: set))
    #expect(state.captureRecord().destination == original.destination)
    #expect(state.quickDraft == original.text)
    let valid = WorkingSet(name: "Valid", destinations: [original.destination])
    let validCheckpoint = WorkingSetCheckpoint(
      workingSetID: valid.id, note: "Note", destinationKey: original.destination.key)
    state.quickSending = true
    #expect(!state.restoreCheckpoint(validCheckpoint, from: valid))
    #expect(state.quickDraft == original.text)
  }
}
