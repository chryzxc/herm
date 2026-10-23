import AppKit
import SwiftUI

struct ChatImagePreview: Identifiable {
    let id = UUID()
    let image: NSImage
}

struct ChatImagePreviewModal: View {
    @Environment(\.dismiss) private var dismiss
    let image: NSImage

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.dockOpaqueCanvas
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 900, maxHeight: 700)
                .padding(28)
            Button(action: { dismiss() }) {
                DockIcon(.x)
                    .dockFont(.navigation, weight: .bold)
                    .foregroundStyle(Color.dockPrimaryText)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Color.dockControlSurface))
            }
            .buttonStyle(.dockHover)
            .help("Close image preview")
            .padding(16)
        }
        .frame(minWidth: 520, minHeight: 420)
    }
}
