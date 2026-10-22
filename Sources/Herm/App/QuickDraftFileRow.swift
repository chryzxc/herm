import SwiftUI

struct QuickDraftFileRow: View {
  let file: QuickDraftFile
  let disabled: Bool
  let remove: () -> Void
  @State private var diagnostic: String?

  var body: some View {
    HStack(spacing: 6) {
      if file.kind == .image, diagnostic == nil, let url = try? file.url() {
        AttachmentThumbnailView(url: url).frame(width: 20, height: 20)
      } else {
        FileTypeIcon(fileName: file.name, size: 20)
      }
      VStack(alignment: .leading, spacing: 2) {
        Text(file.name).lineLimit(1).truncationMode(.middle)
        if let diagnostic { Text(diagnostic).foregroundStyle(Color.dockSecondaryText).lineLimit(2) }
      }
      Spacer(minLength: 4)
      if file.uploaded {
        Text("Uploaded").foregroundStyle(Color.dockSecondaryText)
      } else {
        Button(action: remove) { DockIcon(.x, size: 11) }.buttonStyle(.dockHover).disabled(disabled)
          .accessibilityLabel("Remove \(file.name)")
      }
    }
    .dockFont(size: 11)
    .task(id: file.digest) {
      diagnostic = await file.referenceDiagnostic()
    }
  }
}
