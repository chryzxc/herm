import AppKit
import SwiftUI
import Testing

@testable import Herm

@MainActor
struct EdgePanelFrameTransitionTests {
  @Test func defaultsChangesDuringLayoutCannotResizeTheNotchWindow() async throws {
    let suite = "HermPanelSizingTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let panel = makePanel()
    defer { panel.close() }
    let host = EdgeDockHostingView(rootView: AnimatedNotch().defaultAppStorage(defaults))
    host.sizingOptions = []
    panel.contentView = host.panelContainer()
    panel.orderFrontRegardless()
    let frame = panel.frame
    for expanded in [true, false, true, false] {
      withAnimation(.easeInOut(duration: 0.1)) {
        host.rootView = AnimatedNotch(expanded: expanded).defaultAppStorage(defaults)
        defaults.set(expanded, forKey: "herm.chatListCollapsed")
      }
      panel.layoutIfNeeded()
      try await Task.sleep(for: .milliseconds(150))
      #expect(panel.frame == frame)
      #expect(host.frame.size == panel.contentView?.bounds.size)
    }
  }

  private struct AnimatedNotch: View {
    var expanded = false
    @AppStorage("herm.chatListCollapsed") private var collapsed = false
    var body: some View {
      Color.clear
        .frame(width: expanded ? 368 : 66, height: expanded ? 360 : 97)
        .animation(.easeInOut(duration: 0.1), value: expanded)
        .opacity(collapsed ? 0.9 : 1)
    }
  }

  @Test func repeatedUnchangedPlacementDoesNotResizeTheHost() async throws {
    let panel = makePanel()
    defer { panel.close() }
    let transition = EdgePanelFrameTransition(panel: panel)
    panel.frameUpdates = 0
    for _ in 0..<1_000 {
      transition.position(to: panel.frame, animated: true)
      transition.position(to: panel.frame, animated: false)
    }
    try await Task.sleep(for: .milliseconds(150))
    #expect(panel.frameUpdates == 0)
  }

  @Test func queuedGrowthCannotUndoANewerPlacement() async throws {
    let panel = makePanel()
    defer { panel.close() }
    let transition = EdgePanelFrameTransition(panel: panel)
    transition.position(to: NSRect(x: 632, y: 200, width: 368, height: 360), animated: true)
    let left = NSRect(x: 0, y: 300, width: 24, height: 136)
    transition.position(to: left, animated: false)
    try await Task.sleep(for: .milliseconds(750))
    #expect(panel.frame == left)
    #expect(panel.contentView?.frame.size == left.size)
  }

  @Test func activityRefreshesDoNotKeepPostponingTheShrink() async throws {
    let panel = makePanel()
    defer { panel.close() }
    let transition = EdgePanelFrameTransition(panel: panel)
    transition.position(to: NSRect(x: 632, y: 200, width: 368, height: 360), animated: false)
    let collapsed = NSRect(x: 976, y: 300, width: 24, height: 136)
    for _ in 0..<20 {
      transition.position(to: collapsed, animated: true)
      try await Task.sleep(for: .milliseconds(50))
    }
    #expect(panel.frame == collapsed)
  }

  @Test func interruptedShrinkCannotRestoreTheOldEdge() async throws {
    let panel = makePanel()
    defer { panel.close() }
    let transition = EdgePanelFrameTransition(panel: panel)
    let expanded = NSRect(x: 632, y: 200, width: 368, height: 360)
    transition.position(to: expanded, animated: false)
    transition.position(to: NSRect(x: 976, y: 300, width: 24, height: 136), animated: true)
    try await Task.sleep(for: .milliseconds(480))
    let top = NSRect(x: 316, y: 600, width: 368, height: 360)
    transition.position(to: top, animated: false)
    try await Task.sleep(for: .milliseconds(400))
    #expect(panel.frame == top)
    #expect(panel.contentView?.frame.size == top.size)
  }

  @Test func collapseThenReopenSettlesAtExpandedSize() async throws {
    let panel = makePanel()
    defer { panel.close() }
    let transition = EdgePanelFrameTransition(panel: panel)
    let expanded = NSRect(x: 632, y: 200, width: 368, height: 360)
    transition.position(to: expanded, animated: false)
    transition.position(to: NSRect(x: 976, y: 300, width: 24, height: 136), animated: true)
    transition.position(to: expanded, animated: true)
    try await Task.sleep(for: .milliseconds(750))
    #expect(panel.frame == expanded)
  }

  private func makePanel() -> CountingPanel {
    let panel = CountingPanel(
      contentRect: NSRect(x: 976, y: 300, width: 24, height: 136),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isReleasedWhenClosed = false
    let host = EdgeDockHostingView(rootView: Color.clear)
    host.sizingOptions = []
    panel.contentView = host.panelContainer()
    return panel
  }

  private final class CountingPanel: NSPanel {
    var frameUpdates = 0
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
      frameUpdates += 1
      super.setFrame(frameRect, display: flag)
    }
  }
}
