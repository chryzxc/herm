import SwiftUI

struct ConversationContextPicker: View {
    @ObservedObject var model: DockModel
    @State private var query = ""
    @StateObject private var excerpts = ConversationExcerptModel()
    @State private var selected = Set<Int>()
    @Environment(\.dismiss) private var dismiss
    private var sessions: [HermesSession] {
        model.sessions.filter { query.isEmpty || $0.displayTitle.localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        DockModal(title: "Attach conversation excerpts", width: nil) {
            TextField("Find a conversation", text: $query).textFieldStyle(.dockGlass)
            HSplitView {
                List(sessions) { session in
                    Button(session.displayTitle) { load(session) }.buttonStyle(.dockLink)
                }.scrollContentBackground(.hidden).background(Color.dockCanvas).overlay {
                    if sessions.isEmpty {
                        Text(model.sessions.isEmpty ? "No conversations available." : "No matching conversations.")
                            .dockFont(.body)
                            .foregroundStyle(Color.dockSecondaryText).padding(12)
                    }
                }.frame(minWidth: 180)
                ScrollView {
                    VStack(alignment: .leading, spacing: DockSpacing.control) {
                        if excerpts.loading { ProgressView().controlSize(.small) }
                        if excerpts.messages.isEmpty && !excerpts.loading {
                            Text(
                                excerpts.source == nil
                                    ? "Choose a conversation to select excerpts."
                                    : "No messages available in this conversation."
                            )
                            .dockFont(.body).foregroundStyle(Color.dockSecondaryText)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                        }
                        ForEach(excerpts.messages.indices, id: \.self) { index in
                            Toggle(
                                isOn: Binding(
                                    get: { selected.contains(index) },
                                    set: { if $0 { selected.insert(index) } else { selected.remove(index) } })
                            ) {
                                Text(excerpts.messages[index]).dockFont(.body).lineLimit(8)
                            }.toggleStyle(.checkbox).padding(.vertical, 6)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(minWidth: 280)
            }
            if excerpts.partial {
                Text("Showing the last 500 messages. Only selected excerpts will be attached.").font(
                    DockTypography.metadata
                ).foregroundStyle(Color.dockSecondaryText)
            }
            if let error = excerpts.error { Text(error).dockFont(.body).foregroundStyle(Color.dockWarning) }
        } footer: {
            Button("Cancel") { dismiss() }.buttonStyle(.dockSecondary)
            Spacer()
            Button("Attach selected excerpts") {
                guard excerpts.isCurrent(model), let source = excerpts.source else { return }
                let text = selected.sorted().filter { excerpts.messages.indices.contains($0) }.map {
                    excerpts.messages[$0]
                }.joined(separator: "\n\n")
                model.attachedContexts.append(
                    ChatContext(
                        id: UUID().uuidString, title: source.displayTitle,
                        body: "Conversation excerpts from \(source.displayTitle) (\(source.id)):\n"
                            + String(text.prefix(24_000))))
                dismiss()
            }.buttonStyle(.dockPrimary).disabled(selected.isEmpty || excerpts.loading || !excerpts.isCurrent(model))
        }.dockFont(.body).foregroundStyle(Color.dockPrimaryText).frame(width: 750, height: 520)
    }
    private func load(_ session: HermesSession) {
        selected = []
        excerpts.load(session, owner: model)
    }
}
