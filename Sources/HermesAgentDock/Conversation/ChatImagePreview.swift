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
            Color.black.opacity(0.96)
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 900, maxHeight: 700)
                .padding(28)
            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.white)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Color.white.opacity(0.14)))
            }
            .buttonStyle(.plain)
            .help("Close image preview")
            .padding(16)
        }
        .frame(minWidth: 520, minHeight: 420)
    }
}
