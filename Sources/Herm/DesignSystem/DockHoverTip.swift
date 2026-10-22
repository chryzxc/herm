import AppKit
import SwiftUI

struct DockHoverTipAnchor: NSViewRepresentable {
  let text: String
  let edge: Edge
  let gap: CGFloat
  let hovering: Bool

  func makeNSView(context: Context) -> DockHoverTipAnchorView { DockHoverTipAnchorView() }

  func updateNSView(_ view: DockHoverTipAnchorView, context: Context) {
    let changed = view.text != text || view.edge != edge || view.gap != gap
    view.text = text
    view.edge = edge
    view.gap = gap
    if view.hovering != hovering || changed {
      view.hovering = hovering
      DockHoverTipPresenter.shared.update(view)
    }
  }

  static func dismantleNSView(_ view: DockHoverTipAnchorView, coordinator: ()) {
    view.hovering = false
    DockHoverTipPresenter.shared.update(view)
  }
}

final class DockHoverTipAnchorView: NSView {
  var text = ""
  var edge: Edge = .bottom
  var gap: CGFloat = 6
  var hovering = false

  var visibleAnchorRect: CGRect { bounds.intersection(visibleRect) }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func viewWillMove(toWindow newWindow: NSWindow?) {
    if window != newWindow {
      hovering = false
      DockHoverTipPresenter.shared.update(self)
    }
    super.viewWillMove(toWindow: newWindow)
  }
}

final class DockHoverTipPanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

extension NSWindow {
  /// Informational tips must not keep pointer-exit or outside-click dismissal open.
  var dockHasInteractiveChildWindow: Bool {
    childWindows?.contains { !($0 is DockHoverTipPanel) } == true
  }
}

/// AppKit screen coordinates: keep the tip beside the control, including after clamping.
enum DockHoverTipPlacement {
  static func frame(anchor: CGRect, size: CGSize, edge: Edge, gap: CGFloat, visibleFrame: CGRect)
    -> CGRect
  {
    let bounds = visibleFrame.insetBy(dx: 8, dy: 8)
    let size = CGSize(width: min(size.width, bounds.width), height: min(size.height, bounds.height))
    func candidate(_ edge: Edge) -> CGRect {
      switch edge {
      case .top:
        CGRect(
          x: anchor.midX - size.width / 2, y: anchor.maxY + gap, width: size.width,
          height: size.height)
      case .bottom:
        CGRect(
          x: anchor.midX - size.width / 2, y: anchor.minY - gap - size.height, width: size.width,
          height: size.height)
      case .leading:
        CGRect(
          x: anchor.minX - gap - size.width, y: anchor.midY - size.height / 2, width: size.width,
          height: size.height)
      case .trailing:
        CGRect(
          x: anchor.maxX + gap, y: anchor.midY - size.height / 2, width: size.width,
          height: size.height)
      }
    }
    let opposite: Edge =
      switch edge {
      case .top: .bottom
      case .bottom: .top
      case .leading: .trailing
      case .trailing: .leading
      }
    let otherEdges: [Edge] =
      (edge == .top || edge == .bottom) ? [.trailing, .leading] : [.bottom, .top]
    func clamped(_ frame: CGRect) -> CGRect {
      CGRect(
        x: min(max(frame.minX, bounds.minX), bounds.maxX - size.width),
        y: min(max(frame.minY, bounds.minY), bounds.maxY - size.height),
        width: size.width, height: size.height)
    }
    for edge in [edge, opposite] + otherEdges {
      let frame = clamped(candidate(edge))
      if frame.maxY <= anchor.minY - gap || frame.minY >= anchor.maxY + gap
        || frame.maxX <= anchor.minX - gap || frame.minX >= anchor.maxX + gap
      {
        return frame
      }
    }
    return clamped(candidate(edge))
  }
}

@MainActor
final class DockHoverTipPresenter {
  static let shared = DockHoverTipPresenter()
  private let hovered = NSHashTable<DockHoverTipAnchorView>.weakObjects()
  private(set) weak var activeAnchor: DockHoverTipAnchorView?
  private(set) var panel: DockHoverTipPanel?
  private var pending: Task<Void, Never>?
  private var observers: [NSObjectProtocol] = []
  private var eventMonitor: Any?

  func update(_ anchor: DockHoverTipAnchorView) {
    if anchor.hovering && !anchor.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      hovered.add(anchor)
    } else {
      hovered.remove(anchor)
    }
    // A button's help wins over a containing row's help, regardless of event order.
    let next = hovered.allObjects.filter {
      $0.window?.isVisible == true && !$0.visibleAnchorRect.isEmpty
    }
    .min {
      $0.visibleAnchorRect.width * $0.visibleAnchorRect.height < $1.visibleAnchorRect.width
        * $1.visibleAnchorRect.height
    }
    guard next !== activeAnchor else {
      if next === anchor, panel != nil { show(anchor) }
      return
    }
    hidePanel()
    pending?.cancel()
    activeAnchor = next
    guard let next else { return }
    observe(next.window)
    pending = Task { @MainActor [weak self, weak next] in
      try? await Task.sleep(for: .milliseconds(450))
      guard !Task.isCancelled, let self, let next, self.activeAnchor === next else { return }
      self.show(next)
    }
  }

  func show(_ anchor: DockHoverTipAnchorView) {
    guard let window = anchor.window, window.isVisible, !anchor.visibleAnchorRect.isEmpty,
      !anchor.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return }
    let anchorFrame = window.convertToScreen(anchor.convert(anchor.visibleAnchorRect, to: nil))
    let center = CGPoint(x: anchorFrame.midX, y: anchorFrame.midY)
    guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) ?? window.screen
    else { return }
    hidePanel()
    let font = DockSkinPresentation.nativeFont(size: 12, weight: .medium)
    let textWidth = min(
      320, screen.visibleFrame.width - 30,
      ceil((anchor.text as NSString).size(withAttributes: [.font: font]).width))
    let tip = Text(anchor.text)
      .dockFont(.control)
      .foregroundStyle(Color.dockPrimaryText)
      .lineLimit(12)
      .frame(width: textWidth, alignment: .leading)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.horizontal, 7)
      .padding(.vertical, 4)
      .background(RoundedRectangle(cornerRadius: 5).fill(Color.dockOpaqueCanvas))
      .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.dockBorderStrong, lineWidth: 1))
      .accessibilityHidden(true)
      .dockThemedRoot()
    let host = NSHostingController(rootView: tip)
    host.sizingOptions = []
    let size = host.sizeThatFits(
      in: CGSize(width: textWidth + 14, height: screen.visibleFrame.height - 16))
    let frame = DockHoverTipPlacement.frame(
      anchor: anchorFrame, size: size,
      edge: anchor.edge, gap: anchor.gap, visibleFrame: screen.visibleFrame)
    let panel = DockHoverTipPanel(
      contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
      defer: false)
    panel.isReleasedWhenClosed = false
    panel.backgroundColor = NSColor(Color.dockOpaqueCanvas).withAlphaComponent(1)
    panel.isOpaque = true
    panel.hasShadow = false
    panel.ignoresMouseEvents = true
    panel.hidesOnDeactivate = false
    panel.level = window.level
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.appearance = window.effectiveAppearance
    panel.contentViewController = host
    panel.setFrame(frame, display: true)
    window.addChildWindow(panel, ordered: .above)
    panel.orderFrontRegardless()
    self.panel = panel
    observe(window)
  }

  private func observe(_ window: NSWindow?) {
    guard let window else { return }
    let center = NotificationCenter.default
    for name in [
      NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification,
      NSWindow.didMoveNotification, NSWindow.didResizeNotification,
      NSWindow.didChangeOcclusionStateNotification,
    ] {
      observers.append(
        center.addObserver(forName: name, object: window, queue: .main) {
          [weak self, weak window] _ in
          MainActor.assumeIsolated {
            if name == NSWindow.didChangeOcclusionStateNotification,
              let window, window.isVisible, window.occlusionState.contains(.visible)
            {
              return
            }
            self?.dismiss()
          }
        })
    }
    observers.append(
      center.addObserver(
        forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.dismiss() }
      })
    eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [
      .leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .scrollWheel,
    ]) { [weak self] event in
      MainActor.assumeIsolated { self?.dismiss() }
      return event
    }
  }

  func dismiss() {
    pending?.cancel()
    activeAnchor = nil
    hovered.removeAllObjects()
    hidePanel()
  }

  private func hidePanel() {
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    observers.removeAll()
    if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
    eventMonitor = nil
    if let panel {
      panel.parent?.removeChildWindow(panel)
      panel.orderOut(nil)
    }
    panel = nil
  }
}
