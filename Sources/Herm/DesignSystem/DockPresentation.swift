import SwiftUI

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
            content().dockPresentationSurface()
        }
    }

    func dockPopover<Item: Identifiable, Content: View>(
        item: Binding<Item?>, attachmentAnchor: PopoverAttachmentAnchor = .rect(.bounds),
        arrowEdge: Edge? = nil, @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        popover(item: item, attachmentAnchor: attachmentAnchor, arrowEdge: arrowEdge) { item in
            content(item).dockPresentationSurface()
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
