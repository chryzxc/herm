import SwiftUI

struct MemoryCorrectionView: View {
  let service: HermesWorkflowRPC
  @State private var entries: [WorkflowMemoryEntry] = []
  @State private var selected: WorkflowMemoryEntry?
  @State private var content = ""
  @State private var status: String?
  @State private var pending = false
  @State private var confirmation: String?
  var body: some View {
    DisclosureGroup("Correct a memory entry") {
      VStack(alignment: .leading, spacing: 10) {
        Button("Load memory entries") { Task { await load() } }.buttonStyle(.dockCompact).disabled(
          pending)
        ForEach(entries) { entry in
          Button(entry.label) { Task { await inspect(entry) } }.buttonStyle(.dockCompact).disabled(
            pending)
        }
        if let selected {
          Text(selected.label).font(.system(size: 12, weight: .semibold))
          TextEditor(text: $content).font(.system(size: 12)).frame(height: 120).disabled(pending)
          HStack {
            Button("Save correction…") { confirmation = "Save" }.buttonStyle(.dockCompact)
            Button("Delete entry…", role: .destructive) { confirmation = "Delete" }.buttonStyle(
              .dockCompact)
          }.disabled(pending)
        }
        if let status { Text(status).foregroundStyle(Color.dockSecondaryText) }
      }.padding(.top, 8)
    }.font(.system(size: 12))
      .onDisappear {
        content = ""
        selected = nil
      }
      .confirmationDialog(
        "\(confirmation ?? "Change") memory entry?",
        isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } })
      ) {
        Button(
          confirmation == "Delete" ? "Delete entry" : "Save correction",
          role: confirmation == "Delete" ? .destructive : nil
        ) {
          let remove = confirmation == "Delete"
          confirmation = nil
          Task { await save(remove) }
        }
        Button("Cancel", role: .cancel) { confirmation = nil }
      } message: {
        Text(
          "\(selected?.label ?? "Entry") in profile \(service.profileID ?? "Launch profile"). Hermes validates the captured entry fingerprint before changing it."
        )
      }
  }
  private func load() async {
    pending = true
    defer { pending = false }
    do {
      entries = try await service.memoryEntries()
      status = entries.isEmpty ? "No editable fingerprinted memory entries were returned." : nil
    } catch { status = HermesDiagnosticsService.safeSummary(error.localizedDescription) }
  }
  private func inspect(_ entry: WorkflowMemoryEntry) async {
    guard !pending else { return }
    pending = true
    defer { pending = false }
    do {
      let text = try await service.memoryDetail(entry.id)
      selected = entry
      content = text
      status = nil
    } catch { status = HermesDiagnosticsService.safeSummary(error.localizedDescription) }
  }
  private func save(_ remove: Bool) async {
    guard !pending, let selected else { return }
    pending = true
    do {
      try await service.correctMemory(selected.id, content: remove ? nil : content)
      self.selected = nil
      content = ""
      entries = try await service.memoryEntries()
      status = "Memory change acknowledged."
    } catch { status = HermesDiagnosticsService.safeSummary(error.localizedDescription) }
    pending = false
  }
}
