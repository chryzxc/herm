import AppKit
import SwiftUI

/// NSPopover places itself using the content size at show time; content that grows afterwards
/// (async loads) can end up off-screen. Re-clamp the popover window into the visible screen on every layout.
private struct PopoverScreenClamp: NSViewRepresentable {
    final class ClampView: NSView {
        override func layout() {
            super.layout()
            DispatchQueue.main.async { [weak self] in self?.clamp() }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in self?.clamp() }
        }

        private func clamp() {
            guard let window, let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
            var frame = window.frame
            frame.origin.x = max(visible.minX, min(frame.origin.x, visible.maxX - frame.width))
            frame.origin.y = max(visible.minY, min(frame.origin.y, visible.maxY - frame.height))
            if frame != window.frame { window.setFrame(frame, display: true) }
        }
    }

    func makeNSView(context: Context) -> ClampView { ClampView() }
    func updateNSView(_ view: ClampView, context: Context) { view.needsLayout = true }
}

extension View {
    /// One opaque themed canvas covers both the content and native presentation chrome.
    func dockPresentationSurface() -> some View {
        background(Color.dockOpaqueCanvas)
            .presentationBackground(Color.dockOpaqueCanvas)
            .dockThemedRoot()
    }

    func dockPopover<Content: View>(
        isPresented: Binding<Bool>, attachmentAnchor: PopoverAttachmentAnchor = .rect(.bounds),
        arrowEdge: Edge? = nil, @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        popover(isPresented: isPresented, attachmentAnchor: attachmentAnchor, arrowEdge: arrowEdge) {
            content().dockPresentationSurface().background(PopoverScreenClamp())
        }
    }

    func dockPopover<Item: Identifiable, Content: View>(
        item: Binding<Item?>, attachmentAnchor: PopoverAttachmentAnchor = .rect(.bounds),
        arrowEdge: Edge? = nil, @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        popover(item: item, attachmentAnchor: attachmentAnchor, arrowEdge: arrowEdge) { item in
            content(item).dockPresentationSurface().background(PopoverScreenClamp())
        }
    }

    func dockSheet<Content: View>(
        isPresented: Binding<Bool>, onDismiss: (() -> Void)? = nil, @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        sheet(isPresented: isPresented, onDismiss: onDismiss) {
            content().dockPresentationSurface()
        }
    }

    func dockSheet<Item: Identifiable, Content: View>(
        item: Binding<Item?>, onDismiss: (() -> Void)? = nil, @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        sheet(item: item, onDismiss: onDismiss) { item in
            content(item).dockPresentationSurface()
        }
    }
}
