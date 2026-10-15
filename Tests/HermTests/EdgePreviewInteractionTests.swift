import Testing

@testable import Herm

struct EdgePreviewInteractionTests {
  @MainActor @Test func sameSessionIDAcrossProfilesKeepsSeparateRowsAndReply() {
    func row(_ profile: String) -> EdgeNotchTask {
      let session = HermesSession(
        id: "same", profileID: profile, title: profile, preview: "", startedAt: nil,
        messageCount: 0, source: "herm")
      return EdgeNotchTask(
        id: "same", title: profile, phase: .finished, statusLabel: "Finished", detail: nil,
        updatedAt: nil,
        isCurrent: false, isStatusCurrent: true, session: session)
    }
    let coding = row("coding")
    let research = row("research")
    #expect(coding.presentationID != research.presentationID)
    #expect(
      coding.previewIdentity(currentProfileID: nil)
        != research.previewIdentity(currentProfileID: nil))
    let state = EdgeNotchState()
    state.tasks = [coding]
    state.quickReplyTask = research
    state.composing = true
    #expect(state.previewTasks.count == 2)
  }
  private func item(_ id: String, profile: String = "coding") -> EdgePreviewItemID {
    EdgePreviewItemID(profileID: profile, resourceID: id)
  }

  @Test func passivePreviewDoesNotSelectOrMove() {
    var interaction = EdgePreviewInteraction()
    interaction.reconcile(previous: [], current: [item("a")])
    interaction.move(1, items: [item("a")])
    #expect(interaction.selected == nil)
  }

  @Test func selectionSurvivesReorderingAndRetainsItsProfile() {
    let coding = item("same")
    let research = item("same", profile: "research")
    var interaction = EdgePreviewInteraction(mode: .keyboard, selected: research)
    interaction.reconcile(previous: [coding, research], current: [research, coding])
    #expect(interaction.selected == research)
    interaction.move(1, items: [research, coding])
    #expect(interaction.selected == coding)
  }

  @Test func removedSelectionChoosesNextThenPreviousAndEmptyClears() {
    let items = [item("a"), item("b"), item("c")]
    var interaction = EdgePreviewInteraction(mode: .keyboard, selected: items[1])
    interaction.reconcile(previous: items, current: [items[0], items[2]])
    #expect(interaction.selected == items[2])
    interaction.reconcile(previous: [items[0], items[2]], current: [items[0]])
    #expect(interaction.selected == items[0])
    interaction.reconcile(previous: [items[0]], current: [])
    #expect(interaction.selected == nil)
  }

  @Test func movementStopsAtListBoundaries() {
    let items = [item("a"), item("b")]
    var interaction = EdgePreviewInteraction(mode: .keyboard)
    interaction.reconcile(previous: [], current: items)
    #expect(interaction.selected == items[0])
    interaction.move(-1, items: items)
    #expect(interaction.selected == items[0])
    interaction.move(10, items: items)
    #expect(interaction.selected == items[1])
  }
}
