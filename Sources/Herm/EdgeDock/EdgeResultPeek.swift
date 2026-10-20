import SwiftUI
import Translation

/// A captured destination, independent of whichever workspace is selected next.
struct EdgeResultTarget: Identifiable {
  let task: EdgeNotchTask
  let session: HermesSession
  var id: String { "\(session.profileID ?? "")/\(session.id)" }
}

struct EdgeResultContent: Equatable {
  let text: String
  let artifacts: [ArtifactRecord]
  var loadedAt = Date()
  var revisionID: String? = nil

  /// Read the most recent saved answer and only files from its own user turn.
  /// Never substitute the session-list preview or ask the agent for a summary.
  static func parse(_ result: [String: Any], session: HermesSession) throws -> Self? {
    if let owner = result["session_id"] as? String, owner != session.id {
      throw HermesGateway.GatewayError.malformedResponse
    }
    if let owner = result["profile"] as? String, owner != (session.profileID ?? "default") {
      throw HermesGateway.GatewayError.malformedResponse
    }
    guard let messages = result["data"] as? [[String: Any]],
      messages.allSatisfy({ $0["role"] is String })
    else {
      throw HermesGateway.GatewayError.malformedResponse
    }
    let start = messages.lastIndex { $0["role"] as? String == "user" } ?? messages.startIndex
    let turn = Array(messages.dropFirst(start))
    let replies = turn.filter {
      $0["role"] as? String == "assistant" && ($0["tool_calls"] as? [Any] ?? []).isEmpty
    }
    guard let reply = replies.last else { return nil }
    let text: String
    if let value = reply["content"] as? String ?? reply["text"] as? String {
      text = value
    } else if let blocks = reply["content"] as? [[String: Any]] {
      text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
        .joined(separator: "\n")
    } else {
      text = ""
    }
    let artifacts = ArtifactService.extract(session: session, messages: turn)
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !artifacts.isEmpty else {
      return nil
    }
    return Self(
      text: String(GenerativeUIIntegration.plainText(text).prefix(12_000)), artifacts: Array(artifacts.prefix(12)),
      revisionID: (TranscriptHistoryPaging.rowID(reply, key: "row_id") ?? TranscriptHistoryPaging.rowID(reply)).map(String.init) ?? (reply["id"] as? String))
  }
}

struct EdgeResultPeek: View {
  let target: EdgeResultTarget
  let load: (HermesSession) async throws -> EdgeResultContent?
  let back: () -> Void
  let reply: () -> Void
  let openSession: () -> Void
  var reviewed: () -> Void = {}
  var refresh: () -> Void = {}
  var hasNewerResult = false
  @Binding var showingComparison: Bool
  @State private var content: EdgeResultContent?
  @State private var error: String?
  @State private var isLoading = true
  @State private var translating = false
  @State private var revision = 0
  @State private var previousContent: EdgeResultContent?
  @State private var comparison: ResultTextComparison?
  @State private var localComparison: ObservedRequestComparison?
  var reviewInWorkspace: ((ObservedRequestComparison?) -> Void)?

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Button {
          if showingComparison { showingComparison = false } else { back() }
        } label: {
          // A glyph-only label hits only its strokes; give it a full 28pt target.
          DockIcon(.caretLeft, size: 12, color: .dockSecondaryText)
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.dockHover)
        .accessibilityLabel(showingComparison ? "Back to current result" : "Back to tasks")
        VStack(alignment: .leading, spacing: 2) {
          Text(target.session.displayTitle).font(.system(size: 12, weight: .semibold)).lineLimit(1)
          Text(showingComparison ? "Compared with previous read" : "Latest completed reply").font(
            .system(size: 11)
          ).foregroundStyle(
            Color.dockSecondaryText)
        }
        Spacer(minLength: 4)
        if isLoading { ProgressView().controlSize(.mini) }
        Menu(hasNewerResult ? "Update" : "More") {
          Button(hasNewerResult ? "Update saved reply" : "Refresh saved reply") {
            refresh()
            showingComparison = false
            revision += 1
          }
          Button("Compare with previous read") { showingComparison = true }
            .disabled(previousContent == nil || comparison == nil)
          if #available(macOS 15.0, *) {
            Button("Translate reply") { translating = true }.disabled(content?.text.isEmpty ?? true)
          }
        }.modifier(ReplyTranslation(isPresented: $translating, text: content?.text ?? ""))
          .font(.system(size: 11)).menuStyle(.borderlessButton).fixedSize().disabled(isLoading)
          .accessibilityLabel("Result actions")
        if let content, !content.text.isEmpty {
          DockCopyButton(
            content.text, label: "Copy", accessibilityLabel: "Copy excerpt", iconSize: 12
          )
          .buttonStyle(.dockCompact)
        }
      }
      .padding(10)
      .frame(height: 48)
      Divider().overlay(Color.dockBorderLight)
      ScrollView {
        VStack(alignment: .leading, spacing: 10) {
          if showingComparison, let previousContent, let content, let comparison {
            EdgeResultComparison(
              previous: previousContent, current: content, comparison: comparison)
          } else if let content {
            if !content.text.isEmpty {
              MarkdownMessageView(markdown: content.text, bodySize: 12)
                .textSelection(.enabled)
            }
            if let error {
              Text("Update failed. Still showing the loaded excerpt.")
                .font(.system(size: 12, weight: .semibold))
              Text(error).font(.system(size: 12)).foregroundStyle(Color.dockSecondaryText)
            }
            ForEach(content.artifacts) { artifact in
              artifactRow(artifact)
            }
          } else if let error {
            Text("Couldn’t load the reply").font(.system(size: 12, weight: .semibold))
            Text(error).font(.system(size: 12)).foregroundStyle(Color.dockSecondaryText)
            Button("Retry") { revision += 1 }.buttonStyle(.dockCompact)
          } else if !isLoading {
            Text("No saved reply yet").font(.system(size: 12, weight: .semibold))
            Text("Open the session to review its activity.").font(.system(size: 12))
              .foregroundStyle(Color.dockSecondaryText)
          }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      Divider().overlay(Color.dockBorderLight)
      HStack {
        Button("Reply", action: reply).buttonStyle(.dockCompact)
        if localComparison != nil, reviewInWorkspace != nil {
          Button("Review changes") { reviewInWorkspace?(localComparison) }.buttonStyle(.dockCompact)
        }
        if localComparison == nil, reviewInWorkspace != nil, GatewayConnectionStore.shared.launchSettings.mode == .local,
           DeveloperWorkflowModel.shared.turnBaselines[QuickDestination(profileID: target.session.profileID, sessionID: target.session.id).sessionKey] != nil {
          Button("Current Git changes") { reviewInWorkspace?(nil) }.buttonStyle(.dockCompact)
        }
        Spacer()
        Button("Open session", action: openSession).buttonStyle(.dockCompact)
      }
      .font(.system(size: 12, weight: .medium))
      .padding(10)
    }
    .foregroundStyle(Color.dockPrimaryText)
    .onDisappear { showingComparison = false }
    .task(id: revision) {
      isLoading = true
      error = nil
      do {
        let loaded = try await load(target.session)
        guard !Task.isCancelled else { return }
        if let old = content, let loaded {
          let oldText = old.text
          let newText = loaded.text
          let result = await Task.detached(priority: .userInitiated) {
            ResultTextComparison.make(previous: oldText, current: newText)
          }.value
          guard !Task.isCancelled else { return }
          previousContent = old
          comparison = result
          content = loaded
        } else if content != nil, loaded == nil {
          error = "No completed reply is available yet. Still showing the loaded excerpt."
        } else {
          content = loaded
        }
        if let loaded {
          localComparison = await ObservedRequestChanges.shared.current(for: target.session, replyID: loaded.revisionID)
          reviewed()
        }
      } catch {
        guard !Task.isCancelled else { return }
        self.error = DockModel.safeUserDiagnostic(error.localizedDescription)
      }
      isLoading = false
    }
  }

  private func artifactRow(_ artifact: ArtifactRecord) -> some View {
    let url = ArtifactOpener.url(artifact.value)
    let absolute =
      artifact.value.hasPrefix("/") || artifact.value.hasPrefix("~/")
      || artifact.value.hasPrefix("file://") || url?.scheme == "https" || url?.scheme == "http"
    let exists =
      url?.isFileURL == false
      || (absolute && url.map { FileManager.default.fileExists(atPath: $0.path) } == true)
    return HStack(spacing: 6) {
      if artifact.kind == .image, exists, absolute, let url, url.isFileURL {
        AttachmentThumbnailView(url: url).frame(width: 24, height: 24)
      }
      Text(artifact.label).lineLimit(1).truncationMode(.middle)
      Spacer(minLength: 4)
      if !absolute {
        Button("Open session", action: openSession).buttonStyle(.dockCompact)
      } else if exists {
        Button("Open") { ArtifactOpener.open(artifact.value) }.buttonStyle(.dockCompact)
        if url?.isFileURL == true {
          Button("Reveal") { ArtifactOpener.reveal(artifact.value) }.buttonStyle(.dockCompact)
        }
      } else {
        Text("File not found").foregroundStyle(Color.dockSecondaryText)
      }
    }
    .font(.system(size: 11))
    .padding(8)
    .background(
      Color.dockSurface4.opacity(0.5), in: RoundedRectangle(cornerRadius: DockLayout.controlRadius))
  }
}

/// Apple's on-device Translation sheet for a reply; a no-op before macOS 15.
private struct ReplyTranslation: ViewModifier {
  @Binding var isPresented: Bool
  let text: String

  func body(content: Content) -> some View {
    if #available(macOS 15.0, *) {
      content.translationPresentation(isPresented: $isPresented, text: text)
    } else {
      content
    }
  }
}
