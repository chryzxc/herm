import Foundation
import SwiftUI

struct EdgePreviewItemID: Hashable {
  let profileID: String?
  let resourceID: String
}

struct EdgePreviewInteraction: Equatable {
  enum Mode { case passive, keyboard }
  var mode: Mode = .passive
  var selected: EdgePreviewItemID?

  mutating func reconcile(previous: [EdgePreviewItemID], current: [EdgePreviewItemID]) {
    guard mode == .keyboard else { return }
    if let selected, current.contains(selected) { return }
    let index = selected.flatMap { previous.firstIndex(of: $0) } ?? 0
    selected = current.isEmpty ? nil : current[min(index, current.count - 1)]
  }

  mutating func move(_ offset: Int, items: [EdgePreviewItemID]) {
    guard mode == .keyboard, !items.isEmpty else { return }
    let index = selected.flatMap { items.firstIndex(of: $0) } ?? 0
    selected = items[max(0, min(items.count - 1, index + offset))]
  }
}

extension EdgeNotchTask {
  func previewIdentity(currentProfileID: String?) -> EdgePreviewItemID {
    EdgePreviewItemID(
      profileID: isCurrent
        ? currentProfileID
        : session?.profileID ?? attentionRequest?.profileID ?? routine?.profileID,
      resourceID: id)
  }
}

struct EdgeTaskKeyboardControl: ViewModifier {
  let identity: EdgePreviewItemID
  @FocusState.Binding var selection: EdgePreviewItemID?
  let move: (Int) -> KeyPress.Result
  let activate: () -> Void

  func body(content: Content) -> some View {
    content
      .focusable()
      // The rounded overlay below is the selection cue; the system ring draws a square blue box.
      .focusEffectDisabled()
      .focused($selection, equals: identity)
      .onKeyPress(.upArrow, phases: [.down, .repeat]) { key in
        guard key.modifiers.isEmpty else { return .ignored }
        return move(-1)
      }
      .onKeyPress(.downArrow, phases: [.down, .repeat]) { key in
        guard key.modifiers.isEmpty else { return .ignored }
        return move(1)
      }
      .onKeyPress(.return, phases: .down) { key in
        guard key.modifiers.isEmpty else { return .ignored }
        activate()
        return .handled
      }
      .id(identity)
      .overlay(
        RoundedRectangle(cornerRadius: DockControlMetrics.cornerRadius)
          .stroke(Color.dockAccent, lineWidth: 1)
          .opacity(selection == identity ? 1 : 0).allowsHitTesting(false))
  }
}
