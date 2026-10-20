import SwiftUI

struct ComposerContextPreview: View {
    let context: ChatContext
    var insertAsText: ((String) -> Void)?
    @State private var fullText: String?
    @State private var text = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        DockModal(title: context.title, width: nil) {
            ScrollView {
                Text(text.isEmpty ? context.body : text).font(DockTypography.body).textSelection(.enabled).frame(
                    maxWidth: .infinity, alignment: .leading)
            }
        } footer: {
            if let fullText, let insertAsText {
                Button("Paste as text") {
                    insertAsText(fullText)
                    dismiss()
                }.buttonStyle(.dockSecondary)
            }
            Spacer()
            Button("Close") { dismiss() }.buttonStyle(.dockSecondary)
        }.foregroundStyle(Color.dockPrimaryText).frame(width: 540, height: 420)
            .task {
                if let url = context.attachmentURL {
                    let contents = await Task.detached { () -> String? in
                        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                            size <= 8 * 1024 * 1024,
                            let data = try? Data(contentsOf: url), data.count <= 8 * 1024 * 1024
                        else { return nil }
                        return String(data: data, encoding: .utf8)
                    }.value
                    guard !Task.isCancelled else { return }
                    fullText = contents
                    text =
                        contents.map {
                            String($0.prefix(256 * 1024)) + ($0.count > 256 * 1024 ? "\nPreview truncated." : "")
                        } ?? "Attachment is unavailable. The reference has been kept."
                }
            }
    }
}
