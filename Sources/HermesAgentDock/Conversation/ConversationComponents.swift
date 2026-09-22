import Foundation
import AppKit
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

/// Shared fence rules keep streaming chunk boundaries and final rendering in
/// agreement, including tilde fences and shorter backticks inside code.
struct MarkdownFence {
  let marker: Character
  let length: Int
  let language: String?

  init(marker: Character, length: Int, language: String?) {
    self.marker = marker
    self.length = length
    self.language = language
  }

  init?(opening line: String) {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard let marker = trimmed.first, marker == "`" || marker == "~" else { return nil }
    let length = trimmed.prefix(while: { $0 == marker }).count
    guard length >= 3 else { return nil }
    let suffix = String(trimmed.dropFirst(length)).trimmingCharacters(in: .whitespaces)
    guard marker != "`" || !suffix.contains("`") else { return nil }
    self.marker = marker
    self.length = length
    self.language = suffix.isEmpty ? nil : suffix
  }

  func isClosed(by line: String) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    let count = trimmed.prefix(while: { $0 == marker }).count
    return count >= length && trimmed.dropFirst(count).trimmingCharacters(in: .whitespaces).isEmpty
  }
}

struct MarkdownMessageView: View, Equatable {
  let markdown: String
  private let renderCacheKey: String?
  private let blocks: [RenderBlock]

  /// Fully-rendered row payloads. Inline `AttributedString` parsing happens
  /// once per distinct message, not on every body evaluation.
  enum RenderBlock: Equatable {
    case heading(level: Int, text: AttributedString)
    case paragraph(AttributedString)
    case listItem(text: AttributedString, marker: String)
    case code(String, language: String?)
    case quote(AttributedString)
    case tableRow([AttributedString])
  }

  init(markdown: String, cacheResult: Bool = true, cacheKey: String? = nil) {
    self.markdown = markdown
    self.renderCacheKey = cacheKey
    // SwiftUI rebuilds each transcript row's view value on every parent
    // render and each lazy row build while scrolling. The shared cache keeps
    // that to a dictionary hit instead of re-parsing the message Markdown.
    // Transient prefixes must not evict completed messages from the cache.
    self.blocks = cacheResult
      ? RenderCache.renderBlocks(for: markdown, cacheKey: cacheKey)
      : Self.renderBlocks(for: markdown)
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
      cache.totalCostLimit = 32 * 1024 * 1024
      return cache
    }()

    private final class Entry {
      let blocks: [RenderBlock]
      init(blocks: [RenderBlock]) { self.blocks = blocks }
    }

    static func renderBlocks(for markdown: String, cacheKey: String?) -> [RenderBlock] {
      // Transcript rows pass a stable message/revision key, avoiding a full
      // long-string hash on every parent invalidation. Standalone previews
      // retain their source as the fallback identity.
      let key = (cacheKey ?? markdown) as NSString
      if let entry = cache.object(forKey: key) {
        DebugLog.writePerformance("markdown_cache_hit bytes=\(markdown.utf8.count)")
        return entry.blocks
      }
      // Always use the same renderer for restored and live messages. A
      // cheap-looking plain-text shortcut can miss inline Markdown (for
      // example `*italic*`, `_emphasis_`, or backticks), which makes resumed
      // assistant replies display their source syntax instead of formatting.
      let started = DispatchTime.now().uptimeNanoseconds
      let blocks = MarkdownMessageView.renderBlocks(for: markdown)
      let cost = max(markdown.utf8.count, blocks.count * 128)
      cache.setObject(Entry(blocks: blocks), forKey: key, cost: cost)
      let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
      DebugLog.writePerformance("markdown_parse cache_miss bytes=\(markdown.utf8.count) blocks=\(blocks.count) duration_ms=\(String(format: "%.2f", elapsed))")
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
    Text(value)
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
    var fence: MarkdownFence?
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
      if fence == nil, let json = Self.unmarkedJSONObject(in: lines, startingAt: index) {
        flushParagraph()
        result.append(.code(json.text, language: "json"))
        skippedJSONLines = json.nextLineIndex
        continue
      }
      if let active = fence {
        if active.isClosed(by: line) {
          flushCode()
          fence = nil
        } else {
          code.append(line)
        }
        continue
      }
      if let opening = MarkdownFence(opening: line) {
        flushParagraph()
        fence = opening
        language = opening.language
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
    if fence != nil { flushCode() } else { flushParagraph() }
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
    let parsed = (try? AttributedString(
      markdown: value,
      options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    )) ?? AttributedString(value)
    return linkAffordances(in: parsed)
  }
}

/// Long messages use AppKit's text system instead of one SwiftUI `Text` per
/// Markdown block.  The outer conversation scroll view still owns scrolling;
/// this view only owns text storage and intrinsic-height measurement.
enum CompletedMarkdownRendererPolicy {
  static let nativeThresholdBytes = 8_192

  static func usesNativeRenderer(for markdown: String) -> Bool {
    markdown.utf8.count >= nativeThresholdBytes
  }
}

@MainActor
struct NativeMarkdownMessageView: NSViewRepresentable, Equatable {
  let markdown: String
  let seedChunks: [StreamingPresentationChunk]?
  let themeRevision: Int

  init(
    markdown: String,
    seedChunks: [StreamingPresentationChunk]? = nil,
    themeRevision: Int = DockThemeRuntime.revision
  ) {
    self.markdown = markdown
    self.seedChunks = seedChunks
    self.themeRevision = themeRevision
  }

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.markdown == rhs.markdown && lhs.themeRevision == rhs.themeRevision
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> NativeMarkdownTextView {
    let view = NativeMarkdownTextView()
    context.coordinator.update(view, markdown: markdown, seedChunks: seedChunks, themeRevision: themeRevision)
    return view
  }

  func updateNSView(_ nsView: NativeMarkdownTextView, context: Context) {
    context.coordinator.update(nsView, markdown: markdown, seedChunks: seedChunks, themeRevision: themeRevision)
  }

  @MainActor
  final class Coordinator {
    private var renderedMarkdown: String?
    private var renderedThemeRevision: Int?

    func update(
      _ view: NativeMarkdownTextView,
      markdown: String,
      seedChunks: [StreamingPresentationChunk]? = nil,
      themeRevision: Int
    ) {
      guard renderedMarkdown != markdown || renderedThemeRevision != themeRevision else { return }
      renderedMarkdown = markdown
      renderedThemeRevision = themeRevision
      let started = DispatchTime.now().uptimeNanoseconds
      let attributed = seedChunks.map(Self.attributedString(for:)) ?? Self.attributedString(for: markdown)
      view.textStorage?.setAttributedString(attributed)
      view.invalidateIntrinsicContentSize()
      let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
      DebugLog.writePerformance("markdown_native_update mode=completed bytes=\(markdown.utf8.count) duration_ms=\(String(format: "%.2f", elapsed))")
    }

    static func attributedString(for markdown: String) -> NSAttributedString {
      let result = NSMutableAttributedString()
      let blocks = MarkdownMessageView.renderBlocks(for: markdown)
      for (index, block) in blocks.enumerated() {
        if index > 0 { result.append(NSAttributedString(string: "\n")) }
        switch block {
        case .heading(let level, let text):
          append(text, to: result, font: .systemFont(ofSize: headingSize(level), weight: .semibold), color: NSColor(Color.dockPrimaryText))
        case .paragraph(let text):
          append(text, to: result, font: .systemFont(ofSize: 14), color: NSColor(Color.dockPrimaryText))
        case .listItem(let text, let marker):
          append(NSAttributedString(string: "\(marker) "), to: result, font: .systemFont(ofSize: 14, weight: .medium), color: NSColor(Color.dockAccent))
          append(text, to: result, font: .systemFont(ofSize: 14), color: NSColor(Color.dockPrimaryText))
        case .quote(let text):
          append(NSAttributedString(string: "│ "), to: result, font: .systemFont(ofSize: 14), color: NSColor(Color.dockSecondaryText))
          append(text, to: result, font: .systemFont(ofSize: 14), color: NSColor(Color.dockSecondaryText))
        case .code(let code, let language):
          if let language, !language.isEmpty {
            append(NSAttributedString(string: language.uppercased() + "\n"), to: result, font: .monospacedSystemFont(ofSize: 12, weight: .medium), color: NSColor(Color.dockMetadataText))
          }
          append(NSAttributedString(string: code), to: result, font: .monospacedSystemFont(ofSize: 12.5, weight: .regular), color: NSColor(Color.dockPrimaryText))
        case .tableRow(let columns):
          for (columnIndex, column) in columns.enumerated() {
            if columnIndex > 0 { append(NSAttributedString(string: "  │  "), to: result, font: .systemFont(ofSize: 12.5), color: NSColor(Color.dockMetadataText)) }
            append(column, to: result, font: .systemFont(ofSize: 12.5), color: NSColor(Color.dockPrimaryText))
          }
        }
        if index < blocks.count - 1 { result.append(NSAttributedString(string: "\n")) }
      }
      return result
    }

    static func attributedString(for chunks: [StreamingPresentationChunk]) -> NSAttributedString {
      let result = NSMutableAttributedString()
      for (index, chunk) in chunks.enumerated() {
        if index > 0 { result.append(NSAttributedString(string: "\n")) }
        result.append(attributedString(for: source(for: chunk)))
      }
      return result
    }

    private static func source(for chunk: StreamingPresentationChunk) -> String {
      switch chunk.context {
      case .markdown, .paragraph, .list, .quote, .table, .inline:
        return chunk.text
      case .fencedCode(let marker, let length, let language):
        let fence = String(repeating: String(marker), count: length)
        return "\(fence)\(language.map { $0.isEmpty ? "" : "\($0)" } ?? "")\n\(chunk.text)\n\(fence)"
      }
    }

    private static func append(_ value: AttributedString, to result: NSMutableAttributedString, font: NSFont, color: NSColor) {
      append(NSAttributedString(value), to: result, font: font, color: color)
    }

    private static func append(_ value: NSAttributedString, to result: NSMutableAttributedString, font: NSFont, color: NSColor) {
      let copy = NSMutableAttributedString(attributedString: value)
      copy.addAttribute(.font, value: font, range: NSRange(location: 0, length: copy.length))
      copy.addAttribute(.foregroundColor, value: color, range: NSRange(location: 0, length: copy.length))
      result.append(copy)
    }

    private static func headingSize(_ level: Int) -> CGFloat {
      level == 1 ? 18 : level == 2 ? 16 : level == 3 ? 14.5 : 14
    }
  }
}

final class NativeMarkdownTextView: NSTextView {
  init() {
    let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
    let layout = NSLayoutManager()
    let storage = NSTextStorage()
    layout.addTextContainer(container)
    storage.addLayoutManager(layout)
    super.init(frame: .zero, textContainer: container)
    isEditable = false
    isSelectable = true
    isRichText = true
    linkTextAttributes = [
      .foregroundColor: NSColor.controlAccentColor,
      .underlineStyle: NSUnderlineStyle.single.rawValue
    ]
    drawsBackground = false
    isVerticallyResizable = true
    isHorizontallyResizable = false
    maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    textContainerInset = NSSize(width: 0, height: 0)
    textContainer?.widthTracksTextView = true
    textContainer?.lineFragmentPadding = 0
    allowsUndo = false
    isAutomaticSpellingCorrectionEnabled = false
    isAutomaticTextCompletionEnabled = false
    isAutomaticLinkDetectionEnabled = false
    isAutomaticQuoteSubstitutionEnabled = false
    isAutomaticDashSubstitutionEnabled = false
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override var intrinsicContentSize: NSSize {
    guard let textContainer, let layoutManager else { return NSSize(width: NSView.noIntrinsicMetric, height: 0) }
    layoutManager.ensureLayout(for: textContainer)
    let used = layoutManager.usedRect(for: textContainer)
    return NSSize(width: NSView.noIntrinsicMetric, height: ceil(used.height))
  }

  override func setFrameSize(_ newSize: NSSize) {
    let widthChanged = abs(frame.width - newSize.width) > 0.5
    super.setFrameSize(newSize)
    if widthChanged {
      // TextKit must recompute wrapping after a transcript resize, but an
      // ordinary scroll/layout pass must not continuously invalidate the
      // intrinsic height.
      invalidateIntrinsicContentSize()
    }
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

/// Observes the native clip view without publishing its live bounds through
/// SwiftUI. Trackpad scrolling can produce dozens of bounds changes per frame;
/// only the settled transition is sent back to the transcript presentation.
struct ConversationScrollEventObserver: NSViewRepresentable {
    var restoreDocumentTop: CGFloat?
    var onScrollSettled: (CGRect) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(restoreDocumentTop: restoreDocumentTop, onScrollSettled: onScrollSettled)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.isHidden = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onScrollSettled = onScrollSettled
        context.coordinator.restoreDocumentTop = restoreDocumentTop
        DispatchQueue.main.async {
            context.coordinator.attachIfNeeded(from: nsView)
            context.coordinator.restoreIfNeeded()
        }
    }

    final class Coordinator: NSObject, @unchecked Sendable {
        var onScrollSettled: (CGRect) -> Void
        var restoreDocumentTop: CGFloat?
        weak var clipView: NSClipView?
        private var observers: [NSObjectProtocol] = []
        private var settleGeneration = 0
        private var lastRestoredDocumentTop: CGFloat?

        init(restoreDocumentTop: CGFloat?, onScrollSettled: @escaping (CGRect) -> Void) {
            self.restoreDocumentTop = restoreDocumentTop
            self.onScrollSettled = onScrollSettled
        }

        @MainActor
        func restoreIfNeeded() {
            guard let clipView, let restoreDocumentTop,
                  restoreDocumentTop != lastRestoredDocumentTop else { return }
            lastRestoredDocumentTop = restoreDocumentTop
            var origin = clipView.bounds.origin
            origin.y = restoreDocumentTop
            clipView.setBoundsOrigin(origin)
        }

        @MainActor
        func attachIfNeeded(from view: NSView) {
            guard clipView == nil else { return }
            var candidate: NSView? = view
            while let current = candidate {
                if let scrollView = current as? NSScrollView {
                    attach(to: scrollView.contentView)
                    return
                }
                candidate = current.superview
            }
        }

        @MainActor
        private func attach(to clipView: NSClipView) {
            self.clipView = clipView
            let notification = NSView.boundsDidChangeNotification
            let token = NotificationCenter.default.addObserver(
                forName: notification,
                object: clipView,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, let clipView = self.clipView else { return }
                    self.settleGeneration &+= 1
                    let generation = self.settleGeneration
                    try? await Task.sleep(nanoseconds: 80_000_000)
                    guard generation == self.settleGeneration else { return }
                    self.onScrollSettled(clipView.bounds)
                }
            }
            observers.append(token)
            clipView.postsBoundsChangedNotifications = true
            onScrollSettled(clipView.bounds)
        }

        deinit {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
        }
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
