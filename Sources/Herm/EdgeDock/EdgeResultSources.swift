import SwiftUI
import UniformTypeIdentifiers

enum ResultSourceLinks {
  static func candidates(in text: String) -> [String] {
    guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    else { return [] }
    var seen = Set<String>()
    return detector.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text))
      .compactMap { match in
        guard let url = match.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
          url.host != nil,
          seen.insert(url.absoluteString).inserted
        else { return nil }
        return url.absoluteString
      }
  }
  static func markdown(_ content: EdgeResultContent, origin: QuickDestination, pins: [PinnedSource])
    -> String
  {
    let source = "\(origin.profileID ?? "Launch profile")/\(origin.sessionID ?? "")"
    let links = pins.filter { $0.origin.key == origin.key }.map {
      "- \($0.label?.replacingOccurrences(of: "\n", with: " ") ?? "Pinned source"): \($0.url)\($0.revisionID.map { " (pinned from reply reference \($0))" } ?? " (conversation reference)")"
    }.joined(separator: "\n")
    return
      "# Reviewed reply excerpt\n\nOrigin: \(source)\n\(content.revisionID.map { "Reply reference: \($0)\n" } ?? "Reply identity unavailable; latest completed reply.\n")\n\(content.text)\n\n## Pinned sources\n\n\(links)\n"
  }
}

struct EdgeResultSources: View {
  let content: EdgeResultContent
  let origin: QuickDestination
  let correct: (String, [String]) -> Void
  let activate: () -> Void
  @ObservedObject private var preferences = CommandCenterPreferencesStore.shared
  @State private var url = ""
  @State private var label = ""
  @State private var note = ""
  @State private var quote = ""
  @State private var selected = Set<UUID>()
  @State private var status: String?
  private var pins: [PinnedSource] { preferences.sourcePins.filter { $0.origin.key == origin.key } }
  var body: some View {
    DisclosureGroup("Sources & corrections") {
      VStack(alignment: .leading, spacing: 8) {
        Text("Links in the response excerpt").font(.system(size: 11)).foregroundStyle(
          Color.dockSecondaryText)
        ForEach(ResultSourceLinks.candidates(in: content.text), id: \.self) { candidate in
          HStack {
            Button(URL(string: candidate)?.host ?? candidate) {
              if let url = URL(string: candidate) { ExternalOpen.open(url) }
            }.buttonStyle(.dockHover)
            Spacer()
            Button(
              pins.contains(where: { $0.url == candidate && $0.revisionID == content.revisionID })
                ? "Pinned" : "Pin"
            ) {
              preferences.pinSource(origin: origin, url: candidate, revisionID: content.revisionID)
            }.buttonStyle(.dockHover).disabled(
              pins.contains(where: { $0.url == candidate && $0.revisionID == content.revisionID }))
          }
        }
        DockTextField("Add a source URL", text: $url).textFieldStyle(.dockGlass)
          .simultaneousGesture(TapGesture().onEnded(activate))
          .accessibilityAction(named: Text("Edit source correction"), activate)
        HStack {
          DockTextField("Label (optional)", text: $label).textFieldStyle(.dockGlass)
            .simultaneousGesture(TapGesture().onEnded(activate))
            .accessibilityAction(named: Text("Edit source correction"), activate)
          Button("Pin") {
            preferences.pinSource(
              origin: origin, url: url, label: label.isEmpty ? nil : label,
              revisionID: content.revisionID)
            if pins.contains(where: { $0.url == url }) {
              url = ""
              label = ""
              status = nil
            } else {
              status = "Enter an HTTP or HTTPS source URL."
            }
          }.buttonStyle(.dockHover)
        }
        Text("Pinned sources in this conversation").font(.system(size: 12, weight: .semibold))
        ForEach(pins) { pin in
          VStack(alignment: .leading, spacing: 3) {
            HStack {
              Toggle(
                pin.label ?? URL(string: pin.url)?.host ?? pin.url,
                isOn: Binding(
                  get: { selected.contains(pin.id) },
                  set: { if $0 { selected.insert(pin.id) } else { selected.remove(pin.id) } })
              ).toggleStyle(.checkbox).lineLimit(1)
              Button("Open") { if let url = URL(string: pin.url) { ExternalOpen.open(url) } }
                .buttonStyle(.dockHover)
              Button("Unpin") { preferences.removeSource(pin.id) }.buttonStyle(.dockHover)
            }
            Text(
              pin.revisionID.map {
                $0 == content.revisionID ? "Pinned from this reply" : "Pinned from an earlier reply"
              } ?? "Conversation reference; reply identity unavailable"
            )
            .font(.system(size: 11)).foregroundStyle(Color.dockSecondaryText)
          }
        }
        Text("Pinned links are references, not proof of a particular claim.").font(
          .system(size: 11)
        ).foregroundStyle(Color.dockSecondaryText)
        DockTextField("Quoted passage (optional)", text: $quote, axis: .vertical).textFieldStyle(
          .dockGlass
        ).lineLimit(1...3).simultaneousGesture(TapGesture().onEnded(activate))
          .accessibilityAction(named: Text("Edit source correction"), activate)
        DockTextField("Correction to this result", text: $note, axis: .vertical).textFieldStyle(
          .dockGlass
        ).lineLimit(1...3).simultaneousGesture(TapGesture().onEnded(activate))
          .accessibilityAction(named: Text("Edit source correction"), activate)
        HStack {
          Button("Correct in quick draft") {
            let quoted = ReplyQuote(
              author: origin.title, text: quote.isEmpty ? content.text : quote
            ).composing(note)
            correct(quoted, pins.filter { selected.contains($0.id) }.map(\.url))
          }.buttonStyle(.dockHover).disabled(
            note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          Button("Export…", action: export).buttonStyle(.dockHover)
        }
        if let status { Text(status).foregroundStyle(Color.dockWarning) }
      }.padding(.top, 8)
    }.font(.system(size: 12))
  }
  private func export() {
    let picker = NSSavePanel()
    picker.nameFieldStringValue = "reviewed-reply.md"
    picker.allowedContentTypes = [.plainText]
    guard picker.runModal() == .OK, let url = picker.url else { return }
    let markdown = ResultSourceLinks.markdown(content, origin: origin, pins: pins)
    Task {
      do {
        try await Task.detached(priority: .userInitiated) {
          let access = url.startAccessingSecurityScopedResource()
          defer { if access { url.stopAccessingSecurityScopedResource() } }
          try markdown.write(to: url, atomically: true, encoding: .utf8)
        }.value
        status = "Exported reviewed excerpt and pinned references."
      } catch { status = "The export could not be saved. Choose another destination." }
    }
  }
}
