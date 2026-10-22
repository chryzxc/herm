import AppKit
import SwiftUI

/// User-authored drafts share the existing durable attachment/recovery store.
struct SavedPromptLibrary: View {
    @ObservedObject var model: DockModel
    @ObservedObject private var store = QuickDraftStore.shared
    @State private var name = ""
    @State private var error: String?
    @State private var saving = false
    @Environment(\.dismiss) private var dismiss
    private var prompts: [QuickDraftRecord] {
        store.records.filter { $0.savedName != nil && $0.destination.profileID == model.profileScopeID }
    }
    var body: some View {
        DockModal(title: "Saved prompts", width: nil) {
            HStack {
                TextField("Name for current draft", text: $name).textFieldStyle(.dockGlass)
                Button(saving ? "Saving…" : "Save current draft") { save() }.buttonStyle(.dockPrimary)
                    .disabled(
                        saving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || (model.draft.isEmpty && model.pendingImages.isEmpty && model.pendingPDFURL == nil
                                && model.attachedContexts.isEmpty)
                    )
            }
            ScrollView {
                ForEach(prompts) { record in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(record.savedName ?? "Prompt").dockFont(size: 12, weight: .semibold)
                            Spacer()
                            Button("Restore") { restore(record) }.buttonStyle(.dockCompact)
                            Button("Delete") {
                                store.remove(record)
                                store.flush()
                            }.buttonStyle(.dockCompact)
                        }
                        Text(
                            (record.contexts ?? []).reduce(record.text) { value, context in
                                context.inlineToken.map {
                                    value.replacingOccurrences(of: $0, with: "[" + context.title + "]")
                                } ?? value
                            }
                        ).dockFont(.body).foregroundStyle(Color.dockSecondaryText).lineLimit(3)
                        Divider().overlay(Color.dockBorderLight)
                    }.padding(.vertical, 8)
                }
                if prompts.isEmpty {
                    Text("Save a draft to reuse its text and attachments later.").dockFont(.body)
                        .foregroundStyle(Color.dockSecondaryText)
                }
            }
            if let error { Text(error).dockFont(.body).foregroundStyle(Color.dockWarning) }
        } footer: {
            Spacer()
            Button("Close") { dismiss() }.buttonStyle(.dockSecondary)
        }.dockFont(.body).foregroundStyle(Color.dockPrimaryText).frame(width: 560, height: 440)
            .interactiveDismissDisabled(saving).disabled(saving)
    }
    private func save() {
        let text = model.draft
        let images = model.pendingImages
        let pdf = model.pendingPDFURL
        let contexts = model.attachedContexts
        let profile = model.profileScopeID
        let savedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        saving = true
        Task { @MainActor in
            defer { saving = false }
            do {
                var record = QuickDraftRecord(destination: QuickDestination(profileID: profile), text: text)
                record.savedName = savedName
                for image in images {
                    guard let data = image.image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data),
                        let png = bitmap.representation(using: .png, properties: [:])
                    else { throw QuickDraftError.message("An image could not be saved.") }
                    record.files.append(try await store.pasteImage(png))
                }
                if let pdf { record.files.append(try await QuickDraftFile.capture(pdf)) }
                for context in contexts {
                    if let url = context.attachmentURL { record.files.append(try await QuickDraftFile.capture(url)) }
                }
                record.contexts = contexts
                store.save(record)
                store.flush()
                if let error = store.error { throw QuickDraftError.message(error) }
                name = ""
                error = nil
            } catch { self.error = error.localizedDescription }
        }
    }
    private func restore(_ record: QuickDraftRecord) {
        do {
            let urls = try record.files.map { try $0.url() }
            let images = try zip(record.files, urls).filter { $0.0.kind == .image }.map { _, url in
                guard let image = NSImage(contentsOf: url) else {
                    throw QuickDraftError.message("A saved image is unavailable. Select it again.")
                }
                return image
            }
            guard !record.files.contains(where: { $0.kind == .pdf }) || model.pendingPDFURL == nil else {
                throw QuickDraftError.message(
                    "The composer already has a PDF. Keep it or remove it before restoring this prompt.")
            }
            var imageIndex = 0
            for (file, url) in zip(record.files, urls) {
                if file.kind == .image {
                    _ = model.stageImage(images[imageIndex])
                    imageIndex += 1
                } else if file.kind == .pdf {
                    model.stagePDFFile(at: url)
                }
            }
            model.restoreCapturedText(
                record.text,
                contexts: record.contexts
                    ?? record.sources.map { ChatContext(id: UUID().uuidString, title: "Saved context", body: $0) })
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
