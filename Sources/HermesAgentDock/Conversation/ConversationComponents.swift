import Foundation
import SwiftUI

/// Reusable conversation-only presentation primitives. They render DockModel
/// state but deliberately do not own transport, session, or input state.
struct ThinkingDots: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    if reduceMotion {
      dots(at: 0)
    } else {
      // This indicator is informative, not motion-critical. Eight updates a
      // second reads smoothly enough while avoiding a display-rate wakeup.
      TimelineView(.periodic(from: .now, by: 1.0 / 8.0)) { context in
        dots(at: context.date.timeIntervalSinceReferenceDate)
      }
    }
  }

  private func dots(at time: TimeInterval) -> some View {
    HStack(spacing: 4) {
      ForEach(0..<3) { i in
        let p = (time + Double(i) * 0.2).truncatingRemainder(dividingBy: 1.4) / 1.4
        let s = 0.6 + 0.4 * max(0, sin(p * .pi * 2))
        Circle().fill(Color.dockAccent).frame(width: 6, height: 6).scaleEffect(s).opacity(s)
      }
    }
  }
}

struct AgentAvatar: View {
  let identity: String
  let statusColor: Color

  var body: some View {
    ZStack {
      Circle()
        .fill(statusColor.opacity(0.12))
        .overlay {
          LucideImage(systemName: "person.fill")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(statusColor)
        }
        .overlay {
          Circle().stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        }
      Circle()
        .fill(statusColor)
        .frame(width: 6, height: 6)
        .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1))
        .offset(x: 8, y: -8)
    }
    .accessibilityLabel("Agent avatar")
  }
}

struct MessageBubbleShape: Shape {
  let isUser: Bool

  func path(in rect: CGRect) -> Path {
    let b: CGFloat = 18
    let s: CGFloat = 6
    let br = isUser ? s : b
    let bl = isUser ? b : s
    return Path { p in
      p.move(to: CGPoint(x: rect.minX + b, y: rect.minY))
      p.addLine(to: CGPoint(x: rect.maxX - b, y: rect.minY))
      p.addArc(
        center: CGPoint(x: rect.maxX - b, y: rect.minY + b), radius: b, startAngle: .degrees(-90),
        endAngle: .degrees(0), clockwise: false)
      p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
      p.addArc(
        center: CGPoint(x: rect.maxX - br, y: rect.maxY - br), radius: br, startAngle: .degrees(0),
        endAngle: .degrees(90), clockwise: false)
      p.addLine(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
      p.addArc(
        center: CGPoint(x: rect.minX + bl, y: rect.maxY - bl), radius: bl, startAngle: .degrees(90),
        endAngle: .degrees(180), clockwise: false)
      p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + b))
      p.addArc(
        center: CGPoint(x: rect.minX + b, y: rect.minY + b), radius: b, startAngle: .degrees(180),
        endAngle: .degrees(270), clockwise: false)
      p.closeSubpath()
    }
  }
}

/// Caps the unmarked-JSON detection scan in `MarkdownMessageView`. The scan
/// walks up to this many lines/bytes seeking a brace-balanced boundary, so
/// without a cap a single large message can monopolize the main actor on
/// first render.
enum MarkdownJSONScanPolicy {
    static let maxScanLines = 400
    static let maxScanBytes = 1_048_576
}

struct MarkdownMessageView: View, Equatable {
  let markdown: String
  private let blocks: [RenderBlock]

  /// Fully-rendered row payloads. Inline `AttributedString` parsing happens
  /// once per distinct message, not on every body evaluation.
  enum RenderBlock {
    case heading(level: Int, text: AttributedString)
    case paragraph(AttributedString)
    case listItem(text: AttributedString, marker: String)
    case code(String, language: String?)
    case quote(AttributedString)
    case tableRow([AttributedString])
  }

  init(markdown: String) {
    self.markdown = markdown
    // SwiftUI rebuilds each transcript row's view value on every parent
    // render and each lazy row build while scrolling. The shared cache keeps
    // that to a dictionary hit instead of re-parsing the message Markdown.
    self.blocks = RenderCache.renderBlocks(for: markdown)
  }

  /// Transcript activity and scrolling can invalidate the surrounding stack
  /// without changing a completed message. The Markdown body is immutable,
  /// so use it as the equality boundary and let SwiftUI retain the already
  /// laid-out rich subtree until the message itself changes.
  nonisolated static func == (lhs: MarkdownMessageView, rhs: MarkdownMessageView) -> Bool {
    lhs.markdown == rhs.markdown
  }

  /// Parsed-and-rendered output keyed by the raw Markdown string. NSCache is
  /// thread-safe and evicts under memory pressure without copying its keys.
  @MainActor
  private enum RenderCache {
    private static let cache: NSCache<NSString, Entry> = {
      let cache = NSCache<NSString, Entry>()
      // Hermes bounds restored transcripts to 500 messages. Keep one full
      // transcript resident so exact (non-lazy) row layout does not turn an
      // activity update into a Markdown reparse cascade.
      cache.countLimit = 600
      return cache
    }()

    private final class Entry {
      let blocks: [RenderBlock]
      init(blocks: [RenderBlock]) { self.blocks = blocks }
    }

    static func renderBlocks(for markdown: String) -> [RenderBlock] {
      let key = markdown as NSString
      if let entry = cache.object(forKey: key) { return entry.blocks }
      // Always use the same renderer for restored and live messages. A
      // cheap-looking plain-text shortcut can miss inline Markdown (for
      // example `*italic*`, `_emphasis_`, or backticks), which makes resumed
      // assistant replies display their source syntax instead of formatting.
      let blocks = MarkdownMessageView.renderBlocks(for: markdown)
      cache.setObject(Entry(blocks: blocks), forKey: key)
      return blocks
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
        switch block {
        case .heading(let level, let text):
          renderedText(text).font(.system(size: Self.headingSize(level), weight: .semibold)).foregroundStyle(Color.dockPrimaryText).padding(
            .top, 2)
        case .paragraph(let text): renderedText(text).font(.system(size: 14)).lineSpacing(3)
        case .listItem(let text, let marker):
          HStack(alignment: .top, spacing: 6) {
            Text(marker).font(.system(size: 14, weight: .medium)).foregroundStyle(Color.dockAccent)
              .frame(minWidth: 16, alignment: .trailing)
            renderedText(text).font(.system(size: 14)).lineSpacing(3)
          }
        case .code(let code, let language): codeBlock(code, language: language)
        case .quote(let text):
          renderedText(text).font(.system(size: 14)).foregroundStyle(Color.dockSecondaryText).padding(
            .leading, 10
          ).overlay(alignment: .leading) { Rectangle().fill(Color.dockBorder).frame(width: 2) }
        case .tableRow(let columns):
          // Render markdown table rows as clean structured cards to avoid eye strain from raw syntax
          HStack(spacing: 8) {
            ForEach(Array(columns.enumerated()), id: \.offset) { _, col in
              renderedText(col)
                .font(.system(size: 12.5, weight: .regular))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
          }
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.dockSurface4))
          .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.dockBorder, lineWidth: 0.5))
        }
      }
    }
    .textSelection(.enabled)
  }

  private func renderedText(_ value: AttributedString) -> some View {
    // Explicitly apply soft dockPrimaryText text color to eliminate pure white glare.
    // Native AttributedString links retain AppKit/SwiftUI pointer and keyboard
    // focus behavior; styling only their ranges keeps safe URL opening intact.
    Text(Self.linkAffordances(in: value))
      .foregroundStyle(Color.dockPrimaryText)
      .tint(Color.dockAccent)
      .fixedSize(horizontal: false, vertical: true)
  }

  static func linkAffordances(in value: AttributedString) -> AttributedString {
    var styled = value
    for run in styled.runs where run.link != nil {
      styled[run.range].foregroundColor = Color.dockAccent
      styled[run.range].underlineStyle = .single
    }
    return styled
  }

  static func renderBlocks(for markdown: String) -> [RenderBlock] {
    renderBlocks(from: parseBlocks(markdown))
  }

  private func codeBlock(_ code: String, language: String?) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      if let language {
        Text(language).font(.system(size: 12, weight: .medium, design: .monospaced))
          .foregroundStyle(Color.dockSecondaryText).textCase(.uppercase).padding(.horizontal, 8).padding(
            .top, 6)
      }
      ScrollView(.horizontal, showsIndicators: false) {
        Text(code).font(.system(size: 12.5, design: .monospaced)).foregroundStyle(Color.dockPrimaryText).frame(
          maxWidth: .infinity, alignment: .leading
        ).padding(.horizontal, 8).padding(.vertical, 6)
      }
    }.background(
      RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.dockSurface4).stroke(
        Color.dockBorder, lineWidth: 0.5))
  }
  private static func headingSize(_ level: Int) -> CGFloat {
    level == 1 ? 18 : level == 2 ? 16 : level == 3 ? 14.5 : 14
  }

  /// Line-level parse output before inline Markdown is rendered.
  private enum ParsedBlock {
    case heading(level: Int, text: String)
    case paragraph(String)
    case listItem(text: String, marker: String)
    case code(String, language: String?)
    case quote(String)
    case tableRow([String])
  }

  private static func parseBlocks(_ markdown: String) -> [ParsedBlock] {
    var result: [ParsedBlock] = []
    var code: [String] = []
    var language: String?
    var inCode = false
    var paragraph: [String] = []
    func flushParagraph() {
      let text = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
      paragraph.removeAll()
      if !text.isEmpty { result.append(.paragraph(text)) }
    }
    func flushCode() {
      result.append(.code(code.joined(separator: "\n"), language: language))
      code.removeAll()
      language = nil
    }
    let lines = markdown.components(separatedBy: "\n")
    var skippedJSONLines = 0
    for (index, line) in lines.enumerated() {
      if index < skippedJSONLines { continue }
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if !inCode, let json = Self.unmarkedJSONObject(in: lines, startingAt: index) {
        flushParagraph()
        result.append(.code(json.text, language: "json"))
        skippedJSONLines = json.nextLineIndex
        continue
      }
      if trimmed.hasPrefix("```") {
        if inCode {
          flushCode()
        } else {
          flushParagraph()
          let suffix = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
          language = suffix.isEmpty ? nil : suffix
        }
        inCode.toggle()
        continue
      }
      if inCode {
        code.append(line)
        continue
      }
      if trimmed.hasPrefix("|") && trimmed.hasSuffix("|") {
        if trimmed.contains("---") {
          continue // skip table separator syntax lines cleanly
        }
        let cols = trimmed.split(separator: "|").map { String($0).trimmingCharacters(in: .whitespaces) }
        if !cols.isEmpty {
          flushParagraph()
          result.append(.tableRow(cols))
          continue
        }
      }
      if let level = Self.headingLevel(trimmed) {
        flushParagraph()
        result.append(
          .heading(
            level: level,
            text: String(trimmed.drop(while: { $0 == "#" }).drop(while: { $0 == " " }))))
        continue
      }
      if let item = Self.orderedListItem(trimmed) {
        flushParagraph()
        // Honor the authored marker. The former synthesized counter reset on
        // prose/blank lines, incorrectly rendering valid `4.` and `5.` as 1.
        result.append(.listItem(text: item.content, marker: item.marker))
        continue
      }
      if let item = Self.unorderedListItem(trimmed) {
        flushParagraph()
        result.append(.listItem(text: item, marker: "•"))
        continue
      }
      if trimmed.hasPrefix(">") {
        flushParagraph()
        let content = String(trimmed.dropFirst().trimmingCharacters(in: .whitespaces))
        if !content.isEmpty { result.append(.quote(content)) }
        continue
      }
      if trimmed.isEmpty {
        flushParagraph()
        continue
      }
      paragraph.append(line)
    }
    if inCode { flushCode() } else { flushParagraph() }
    return result
  }

  /// Hermes status messages can contain a prose summary followed by a raw
  /// JSON result. JSON is only Markdown when fenced, but its object syntax is
  /// unambiguous and should still be readable as structured output instead
  /// of flowing through a proportional prose paragraph.
  private static func unmarkedJSONObject(
    in lines: [String], startingAt start: Int
  ) -> (text: String, nextLineIndex: Int)? {
    guard lines[start].trimmingCharacters(in: .whitespaces).hasPrefix("{") else {
      return nil
    }

    // A JSON object can only parse where braces balance outside string
    // literals, so track depth in a single pass and attempt the validating
    // JSONSerialization call only at those boundaries instead of re-parsing
    // the whole growing candidate after every accumulated line.
    var candidate = ""
    var candidateBytes = 0
    var depth = 0
    var inString = false
    var escaped = false
    let lastLine = min(lines.count, start + MarkdownJSONScanPolicy.maxScanLines)
    for end in start..<lastLine {
      let line = lines[end]
      if !candidate.isEmpty {
        candidate.append("\n")
        candidateBytes += 1
      }
      candidate.append(line)
      candidateBytes += line.utf8.count
      if candidateBytes > MarkdownJSONScanPolicy.maxScanBytes { return nil }
      for character in line {
        if inString {
          if escaped {
            escaped = false
          } else if character == "\\" {
            escaped = true
          } else if character == "\"" {
            inString = false
          }
          continue
        }
        switch character {
        case "\"": inString = true
        case "{": depth += 1
        case "}":
          depth -= 1
          if depth < 0 { return nil }
        default: continue
        }
      }
      guard depth == 0 else { continue }
      guard let data = candidate.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data),
            object is [String: Any] else {
        continue
      }
      return (candidate, end + 1)
    }
    return nil
  }

  static func codeBlockLanguages(in markdown: String) -> [String?] {
    parseBlocks(markdown).compactMap { block in
      guard case .code(_, let language) = block else { return nil }
      return language
    }
  }
  static func orderedListMarkers(in markdown: String) -> [String] {
    parseBlocks(markdown).compactMap { block in
      guard case .listItem(_, let marker) = block, marker != "•" else { return nil }
      return marker
    }
  }
  private static func headingLevel(_ line: String) -> Int? {
    let hashes = line.prefix(while: { $0 == "#" }).count
    guard hashes > 0, hashes <= 6, line.count > hashes,
      line[line.index(line.startIndex, offsetBy: hashes)] == " "
    else { return nil }
    return hashes
  }
  private static func orderedListItem(_ line: String) -> (marker: String, content: String)? {
    guard let dotIndex = line.firstIndex(of: "."), !line[..<dotIndex].isEmpty,
      line[..<dotIndex].allSatisfy(\.isNumber), line.index(after: dotIndex) < line.endIndex,
      line[line.index(after: dotIndex)] == " "
    else { return nil }
    return (
      marker: String(line[...dotIndex]),
      content: String(line[line.index(dotIndex, offsetBy: 2)...]).trimmingCharacters(in: .whitespaces)
    )
  }
  private static func unorderedListItem(_ line: String) -> String? {
    for prefix in ["- ", "* ", "+ "] where line.hasPrefix(prefix) {
      return String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
    }
    return nil
  }
  private static func renderBlocks(from parsed: [ParsedBlock]) -> [RenderBlock] {
    parsed.map { block in
      switch block {
      case .heading(let level, let text): return .heading(level: level, text: inlineMarkdown(text))
      case .paragraph(let text): return .paragraph(inlineMarkdown(text))
      case .listItem(let text, let marker): return .listItem(text: inlineMarkdown(text), marker: marker)
      case .code(let code, let language): return .code(code, language: language)
      case .quote(let text): return .quote(inlineMarkdown(text))
      case .tableRow(let columns): return .tableRow(columns.map(inlineMarkdown))
      }
    }
  }

  private static func inlineMarkdown(_ value: String) -> AttributedString {
    (try? AttributedString(
      markdown: value,
      options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    )) ?? AttributedString(value)
  }
}

/// Content bounds from the restored SwiftUI transcript. This has one purpose:
/// determine whether the reader is at the real tail so streaming never steals
/// their position while they browse older messages.
struct ConversationContentBounds: Equatable {
    var topMinY: CGFloat
    var bottomMaxY: CGFloat
}

struct ConversationContentBoundsPreferenceKey: PreferenceKey {
    static let defaultValue = ConversationContentBounds(topMinY: 0, bottomMaxY: 0)

    static func reduce(value: inout ConversationContentBounds, nextValue: () -> ConversationContentBounds) {
        value = nextValue()
    }
}

struct ConversationActivityRow: View {
  @ObservedObject var model: DockModel
  var horizontalInset: CGFloat = 20
  private var latestPipelineActivity: AgentActivityPresentation.PipelineActivity? {
    model.agentPresentationSnapshot.pipeline.first(where: \.isActive)
  }
  private var title: String {
    switch model.conversationActivityPhase {
    case .thinking: return "Thinking"
    case .responding: break
    case .idle: break
    }
    // Read once: each access re-runs the presentation snapshot cache's input
    // equality check over the full agent and activity arrays.
    let activity = latestPipelineActivity
    guard activity != nil else { return "Responding" }
    return AgentActivityPresentation.conversationTitle(
      latestPipelineActivity: activity, recentEvents: model.recentEvents)
  }
  var body: some View {
    HStack(spacing: 6) {
      ThinkingDots()
      Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.dockSecondaryText)
        .lineLimit(1).truncationMode(.tail)
      if let startedAt = model.streamingResponseStartedAt {
        Spacer(minLength: 8)
        ResponseDurationLabel(startedAt: startedAt, finishedDuration: nil)
          .font(.system(size: 12, design: .monospaced))
          .foregroundStyle(Color.dockMetadataText)
          .accessibilityLabel("Response duration")
      }
    }.padding(.horizontal, horizontalInset).padding(.vertical, 8).frame(
      maxWidth: .infinity, alignment: .leading)
  }
}
