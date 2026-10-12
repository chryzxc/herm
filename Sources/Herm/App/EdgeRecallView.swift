import Combine
import SwiftUI

struct RecallHit: Identifiable, Equatable {
  let session: HermesSession
  let snippet: String
  var id: String { "\(session.profileID ?? "")/\(session.id)" }
}

@MainActor
final class EdgeRecallModel: ObservableObject {
  @Published private(set) var hits: [RecallHit] = []
  @Published private(set) var loading = false
  @Published private(set) var error: String?
  private var generation = UUID()
  func search(_ query: String, profileID: String?, client: HermesRPCClientProtocol) async {
    let token = UUID()
    generation = token
    hits = []
    error = nil
    guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      loading = false
      return
    }
    loading = true
    defer { if generation == token { loading = false } }
    do {
      try await Task.sleep(for: .milliseconds(300))
      let rows = try await HermesControlRPC(client: client).searchSessions(
        query: query, limit: 20, profileID: profileID)
      guard !Task.isCancelled, generation == token else { return }
      hits = try rows.prefix(20).map { row in
        guard let id = row["session_id"] as? String ?? row["id"] as? String, !id.isEmpty else {
          throw HermesGateway.GatewayError.malformedResponse
        }
        if let expected = profileID, row["profile"] as? String != expected {
          throw HermesGateway.GatewayError.malformedResponse
        }
        let session = HermesSession(
          id: id, profileID: profileID, title: row["title"] as? String ?? "Conversation",
          preview: "", startedAt: nil, messageCount: 0, source: row["source"] as? String ?? "herm")
        return RecallHit(
          session: session, snippet: String((row["snippet"] as? String ?? "").prefix(2000)))
      }
    } catch {
      guard !Task.isCancelled, generation == token else { return }
      self.error = HermesDiagnosticsService.safeSummary(error.localizedDescription)
    }
  }
}

struct EdgeRecallView: View {
  let profileID: String?
  let client: HermesRPCClientProtocol
  let back: () -> Void
  let open: (HermesSession) -> Void
  let insert: (RecallHit) -> Void
  @StateObject private var search = EdgeRecallModel()
  @State private var query = ""
  @FocusState private var focused: Bool
  var body: some View {
    VStack(spacing: 0) {
      HStack {
        DockTextField("Search \(profileID ?? "Launch profile")", text: $query).textFieldStyle(
          .dockGlass
        ).focused($focused)
        if search.loading { ProgressView().controlSize(.mini) }
      }.padding(10).frame(height: 48)
      Divider().overlay(Color.dockBorderLight)
      ScrollView {
        VStack(alignment: .leading, spacing: 10) {
          if let error = search.error {
            Text(error).foregroundStyle(Color.dockWarning)
          } else if search.hits.isEmpty, !search.loading {
            Text(query.isEmpty ? "Search previous conversations" : "No matching conversations")
              .font(.system(size: 12, weight: .semibold))
          }
          ForEach(search.hits) { hit in
            VStack(alignment: .leading, spacing: 5) {
              Text(hit.session.displayTitle).font(.system(size: 12, weight: .semibold))
              Text(hit.snippet).font(.system(size: 12)).lineLimit(5)
              HStack {
                Button("Open conversation") { open(hit.session) }.buttonStyle(.dockHover)
                DockCopyButton(
                  hit.snippet, label: "Copy", accessibilityLabel: "Copy search snippet"
                ).buttonStyle(.dockHover)
                Button("Insert") { insert(hit) }.buttonStyle(.dockHover).accessibilityLabel(
                  "Insert snippet into quick draft with source reference")
              }.font(.system(size: 11))
            }
          }
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
      }
      Divider().overlay(Color.dockBorderLight)
      HStack {
        Button("Back", action: back).buttonStyle(.dockHover)
        Spacer()
        Text("Opens a conversation").foregroundStyle(Color.dockSecondaryText)
      }.font(.system(size: 11)).padding(10)
    }.foregroundStyle(Color.dockPrimaryText)
      .onAppear { focused = true }
      .task(id: query) { await search.search(query, profileID: profileID, client: client) }
  }
}
