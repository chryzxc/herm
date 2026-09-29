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
          DockIcon(.user)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(statusColor)
        }
        .overlay {
          Circle().stroke(Color.dockBorder, lineWidth: 0.5)
        }
      Circle()
        .fill(statusColor)
        .frame(width: 6, height: 6)
        .overlay(Circle().stroke(Color.dockCanvas, lineWidth: 1))
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
          renderedText(text).font(.system(size: Self.headingSize(level), weight: .semibold)).foregroundStyle(Color.dockMarkdownText).padding(
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
          .background(RoundedRectangle(cornerRadius: DockLayout.controlRadius - 2, style: .continuous).fill(Color.dockSurface4))
          .overlay(RoundedRectangle(cornerRadius: DockLayout.controlRadius - 2, style: .continuous).stroke(Color.dockBorder, lineWidth: 0.5))
        }
      }
    }
    .textSelection(.enabled)
  }

  private func renderedText(_ value: AttributedString) -> some View {
    // Keep long-form Markdown softer than chrome while retaining theme colors.
    // Native AttributedString links retain AppKit/SwiftUI pointer and keyboard
    // focus behavior; styling only their ranges keeps safe URL opening intact.
    Text(value)
      .foregroundStyle(Color.dockMarkdownText)
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
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 8) {
        Text((language ?? "").lowercased()).font(DockTypography.machineMetadata)
          .foregroundStyle(Color.dockMetadataText).lineLimit(1)
        Spacer(minLength: 8)
        MarkdownCodeCopyButton(code: code)
      }.padding(.leading, 10).padding(.trailing, 4).frame(height: 28)
      Rectangle().fill(Color.dockBorder).frame(height: 0.5)
      ScrollView(.horizontal, showsIndicators: false) {
        Text(code).font(.system(size: 12.5, design: .monospaced)).foregroundStyle(Color.dockMarkdownText).frame(
          maxWidth: .infinity, alignment: .leading
        ).padding(.horizontal, 10).padding(.vertical, 8)
      }
    }.background(
      RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous).fill(Color.dockSurface4).stroke(
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
    linkAffordances(in: NativeMarkdownAttributedTextBuilder.inlineMarkdown(value))
  }
}

/// Long streaming messages use AppKit's text system to keep incremental
/// rendering responsive. Completed messages use one native text view below so
/// a selection can span every Markdown block.
enum CompletedMarkdownRendererPolicy {
  static let nativeThresholdBytes = 8_192

  static func usesNativeRenderer(for markdown: String) -> Bool {
    markdown.utf8.count >= nativeThresholdBytes
  }
}

@MainActor
struct NativeMarkdownMessageView: NSViewRepresentable, Equatable {
  let markdown: String
  let themeRevision: Int

  init(
    markdown: String,
    themeRevision: Int = DockThemeRuntime.revision
  ) {
    self.markdown = markdown
    self.themeRevision = themeRevision
  }

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.markdown == rhs.markdown && lhs.themeRevision == rhs.themeRevision
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> NativeMarkdownTextSectionView {
    let view = NativeMarkdownTextSectionView()
    view.update(markdown: markdown, kind: .prose)
    return view
  }

  func updateNSView(_ nsView: NativeMarkdownTextSectionView, context: Context) {
    nsView.update(markdown: markdown, kind: .prose)
  }

  func sizeThatFits(
    _ proposal: ProposedViewSize,
    nsView: NativeMarkdownTextSectionView,
    context: Context
  ) -> CGSize? {
    let width: CGFloat
    if let proposed = proposal.width, proposed.isFinite, proposed > 1 {
      width = proposed
    } else if nsView.bounds.width > 1 {
      width = nsView.bounds.width
    } else {
      width = NativeMarkdownDocumentSizing.fallbackWidth
    }
    return CGSize(width: width, height: nsView.measuredHeight(forWidth: width))
  }

  @MainActor
  final class Coordinator {
    static func attributedString(for markdown: String) -> NSAttributedString {
      let result = NSMutableAttributedString()
      let blocks = MarkdownMessageView.renderBlocks(for: markdown)
      for (index, block) in blocks.enumerated() {
        if index > 0 { result.append(NSAttributedString(string: "\n")) }
        switch block {
        case .heading(let level, let text):
          append(text, to: result, font: .systemFont(ofSize: headingSize(level), weight: .semibold), color: NSColor(Color.dockMarkdownText))
        case .paragraph(let text):
          append(text, to: result, font: .systemFont(ofSize: 14), color: NSColor(Color.dockMarkdownText))
        case .listItem(let text, let marker):
          append(NSAttributedString(string: "\(marker) "), to: result, font: .systemFont(ofSize: 14, weight: .medium), color: NSColor(Color.dockAccent))
          append(text, to: result, font: .systemFont(ofSize: 14), color: NSColor(Color.dockMarkdownText))
        case .quote(let text):
          append(NSAttributedString(string: "│ "), to: result, font: .systemFont(ofSize: 14), color: NSColor(Color.dockSecondaryText))
          append(text, to: result, font: .systemFont(ofSize: 14), color: NSColor(Color.dockSecondaryText))
        case .code(let code, let language):
          if let language, !language.isEmpty {
            append(NSAttributedString(string: language.uppercased() + "\n"), to: result, font: .monospacedSystemFont(ofSize: 12, weight: .medium), color: NSColor(Color.dockMetadataText))
          }
          append(NSAttributedString(string: code), to: result, font: .monospacedSystemFont(ofSize: 12.5, weight: .regular), color: NSColor(Color.dockMarkdownText))
        case .tableRow(let columns):
          for (columnIndex, column) in columns.enumerated() {
            if columnIndex > 0 { append(NSAttributedString(string: "  │  "), to: result, font: .systemFont(ofSize: 12.5), color: NSColor(Color.dockMetadataText)) }
            append(column, to: result, font: .systemFont(ofSize: 12.5), color: NSColor(Color.dockMarkdownText))
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

/// Viewport geometry in top-origin document coordinates, matching the SwiftUI
/// "conversation-document" coordinate space used by row frames.
struct ConversationScrollGeometry: Equatable {
    var visibleTop: CGFloat
    var visibleHeight: CGFloat
    var documentHeight: CGFloat

    var distanceToBottom: CGFloat { max(0, documentHeight - visibleTop - visibleHeight) }
}

/// Direct, non-publishing access to the transcript's native clip view. Used
/// to hold the reader's position while history pages mount above them, in
/// the same layout pass, instead of a SwiftUI state round trip (a visible
/// jump followed by a correction).
@MainActor
final class ConversationScrollController {
    weak var clipView: NSClipView?

    var geometry: ConversationScrollGeometry? {
        guard let clipView, let documentView = clipView.documentView else { return nil }
        let visible = clipView.documentVisibleRect
        let documentHeight = documentView.bounds.height
        let top = documentView.isFlipped ? visible.minY : documentHeight - visible.maxY
        return ConversationScrollGeometry(
            visibleTop: top,
            visibleHeight: visible.height,
            documentHeight: documentHeight
        )
    }

    /// Moves the viewport by a document-space delta relative to wherever it
    /// is now, so in-flight momentum keeps its progress. If the hosting
    /// document has not adopted its new height yet, the clamped remainder is
    /// applied once on the next run-loop turn.
    func shiftVisibleTop(by delta: CGFloat) {
        let remaining = delta - applyShift(delta)
        guard abs(remaining) > 0.5 else { return }
        DispatchQueue.main.async { [weak self] in
            _ = self?.applyShift(remaining)
        }
    }

    private func applyShift(_ delta: CGFloat) -> CGFloat {
        guard abs(delta) > 0.5, let clipView, let documentView = clipView.documentView else { return delta }
        let sign: CGFloat = documentView.isFlipped ? 1 : -1
        let current = clipView.bounds.origin.y
        let maxY = max(0, documentView.bounds.height - clipView.bounds.height)
        let target = min(max(0, current + sign * delta), maxY)
        clipView.scroll(to: NSPoint(x: clipView.bounds.origin.x, y: target))
        (clipView.superview as? NSScrollView)?.reflectScrolledClipView(clipView)
        return (target - current) * sign
    }
}

/// Observes the native clip view without publishing its live bounds through
/// SwiftUI. Trackpad scrolling can produce dozens of bounds changes per frame;
/// `onScroll` receives them synchronously for cheap edge checks, and only the
/// settled transition is reported through `onScrollSettled`.
struct ConversationScrollEventObserver: NSViewRepresentable {
    var controller: ConversationScrollController
    var onScroll: (ConversationScrollGeometry, _ deltaTop: CGFloat) -> Void
    var onScrollSettled: (ConversationScrollGeometry) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller, onScroll: onScroll, onScrollSettled: onScrollSettled)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.isHidden = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onScroll = onScroll
        coordinator.onScrollSettled = onScrollSettled
        guard coordinator.clipView == nil else { return }
        DispatchQueue.main.async {
            coordinator.attachIfNeeded(from: nsView)
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject {
        static let settleDelayNanoseconds: UInt64 = 80_000_000

        let controller: ConversationScrollController
        var onScroll: (ConversationScrollGeometry, CGFloat) -> Void
        var onScrollSettled: (ConversationScrollGeometry) -> Void
        weak var clipView: NSClipView?
        nonisolated(unsafe) private var observer: NSObjectProtocol?
        private var lastBoundsChange: UInt64 = 0
        private var lastVisibleTop: CGFloat?
        private var settleTask: Task<Void, Never>?

        init(
            controller: ConversationScrollController,
            onScroll: @escaping (ConversationScrollGeometry, CGFloat) -> Void,
            onScrollSettled: @escaping (ConversationScrollGeometry) -> Void
        ) {
            self.controller = controller
            self.onScroll = onScroll
            self.onScrollSettled = onScrollSettled
        }

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

        func detach() {
            settleTask?.cancel()
            settleTask = nil
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            clipView = nil
        }

        private func attach(to clipView: NSClipView) {
            self.clipView = clipView
            controller.clipView = clipView
            observer = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: clipView,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.boundsDidChange() }
            }
            clipView.postsBoundsChangedNotifications = true
            reportSettled()
        }

        private func boundsDidChange() {
            lastBoundsChange = DispatchTime.now().uptimeNanoseconds
            if let geometry = controller.geometry {
                let delta = geometry.visibleTop - (lastVisibleTop ?? geometry.visibleTop)
                lastVisibleTop = geometry.visibleTop
                onScroll(geometry, delta)
            }
            scheduleSettle()
        }

        /// One sleeping task per gesture instead of one per bounds change:
        /// the task re-arms itself until the clip view has been still for the
        /// settle delay.
        private func scheduleSettle() {
            guard settleTask == nil else { return }
            settleTask = Task { @MainActor [weak self] in
                var remaining = Self.settleDelayNanoseconds
                while true {
                    try? await Task.sleep(nanoseconds: remaining)
                    guard let self, !Task.isCancelled else { return }
                    let elapsed = DispatchTime.now().uptimeNanoseconds &- self.lastBoundsChange
                    if elapsed >= Self.settleDelayNanoseconds {
                        self.settleTask = nil
                        self.reportSettled()
                        return
                    }
                    remaining = Self.settleDelayNanoseconds - elapsed
                }
            }
        }

        private func reportSettled() {
            guard let geometry = controller.geometry else { return }
            lastVisibleTop = geometry.visibleTop
            onScrollSettled(geometry)
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}

/// The tool calls behind one response, shown above its bubble. While the
/// response streams the list stays open and grows per call; once complete it
/// collapses to a "Worked for …" summary the reader can expand.
struct TurnActivityView: View {
  let activity: [ActiveToolCall]
  /// Turn start while streaming; nil once the response is complete.
  let runningSince: Date?
  let duration: TimeInterval?
  @State private var isExpanded = false
  @State private var expandedThoughtIDs: Set<String> = []
  @State private var expandedDiffIDs: Set<String> = []

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      if let runningSince {
        steps
        HStack(spacing: 6) {
          ProgressView().controlSize(.mini)
          TimelineView(.periodic(from: .now, by: 1)) { context in
            Text("Running for about \(Self.roughDuration(context.date.timeIntervalSince(runningSince)))")
          }
        }
        .font(.system(size: 12))
        .foregroundStyle(Color.dockMetadataText)
        .padding(.vertical, 4)
      } else {
        Button {
          withAnimation(.dockEase(duration: 0.18)) { isExpanded.toggle() }
        } label: {
          HStack(spacing: 6) {
            Text(summary).font(.system(size: 12, weight: .medium))
            DockIcon(isExpanded ? .caretDown : .caretRight, size: 10)
          }
          .foregroundStyle(Color.dockSecondaryText)
          .padding(.vertical, 6)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isExpanded ? "Hide activity" : "Show activity")
        if isExpanded { steps }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// Whole units only: "45 seconds", "3 minutes", "2 hours".
  static func roughDuration(_ seconds: TimeInterval) -> String {
    let s = max(0, Int(seconds))
    let (value, unit) = s < 60 ? (s, "second") : s < 3600 ? (s / 60, "minute") : (s / 3600, "hour")
    return "\(value) \(unit)\(value == 1 ? "" : "s")"
  }

  private var summary: String {
    let count = "\(activity.count) step\(activity.count == 1 ? "" : "s")"
    return duration.map { "Worked for \(Self.roughDuration($0)) · \(count)" } ?? "Worked · \(count)"
  }

  private var steps: some View {
    VStack(alignment: .leading, spacing: 6) {
      ForEach(activity) { call in
        if call.name == ActiveToolCall.thinkingName {
          thoughtRow(call)
        } else if call.name == ActiveToolCall.compactionName {
          CompactionStepRow(call: call)
        } else {
          toolRow(call)
        }
      }
    }
    .padding(.vertical, 4)
  }

  private func thoughtRow(_ call: ActiveToolCall) -> some View {
    let isOpen = expandedThoughtIDs.contains(call.id)
    let seconds = call.completedAt.map { $0.timeIntervalSince(call.startedAt) }
    let title = call.isComplete
      ? seconds.map { "Thought for \(Self.roughDuration($0))" } ?? "Thought"
      : "Thinking"
    return VStack(alignment: .leading, spacing: 4) {
      Button {
        withAnimation(.dockEase(duration: 0.18)) {
          if isOpen { expandedThoughtIDs.remove(call.id) } else { expandedThoughtIDs.insert(call.id) }
        }
      } label: {
        HStack(spacing: 8) {
          stepIcon(.brain)
          Text(title).font(.system(size: 12)).foregroundStyle(Color.dockSecondaryText)
          if !call.isComplete { ProgressView().controlSize(.mini) }
          DockIcon(isOpen ? .caretDown : .caretRight, size: 9, color: Color.dockMetadataText)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(isOpen ? "Hide thinking" : "Show thinking")
      if isOpen {
        Text((call.result ?? "").isEmpty ? "…" : call.result ?? "")
          .font(.system(size: 12))
          .foregroundStyle(Color.dockMetadataText)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.leading, 28)
      }
    }
  }

  private func stepIcon(_ icon: Ph) -> some View {
    DockIcon(icon, size: 13, color: Color.dockSecondaryText).frame(width: 16, height: 16)
  }

  @ViewBuilder
  private func toolRow(_ call: ActiveToolCall) -> some View {
    if let diff = call.diffPreview, let stats = call.diffStats {
      // Edits carry their diff, collapsed until asked for.
      let isOpen = expandedDiffIDs.contains(call.id)
      VStack(alignment: .leading, spacing: 4) {
        Button {
          withAnimation(.dockEase(duration: 0.18)) {
            if isOpen { expandedDiffIDs.remove(call.id) } else { expandedDiffIDs.insert(call.id) }
          }
        } label: {
          HStack(spacing: 8) {
            toolLabel(call)
            Text("+\(stats.added)").foregroundStyle(Color.dockSuccess)
            Text("−\(stats.removed)").foregroundStyle(Color.dockDestructive)
            DockIcon(isOpen ? .caretDown : .caretRight, size: 9, color: Color.dockMetadataText)
          }
          .font(.system(size: 11, weight: .medium, design: .monospaced))
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isOpen ? "Hide changes" : "Show changes")
        if isOpen {
          ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 0) {
              ForEach(PullRequestDiffPresentation.lines(diff)) { line in
                PullRequestDiffLineView(line: line)
              }
            }
          }
          .frame(maxHeight: 280)
          .background(RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous).fill(Color.dockCanvas))
          .overlay(RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous).stroke(Color.dockBorderLight, lineWidth: 0.5))
          .padding(.leading, 24)
        }
      }
    } else {
      toolLabel(call)
    }
  }

  private func toolLabel(_ call: ActiveToolCall) -> some View {
    HStack(spacing: 8) {
      stepIcon(Self.icon(for: call.name))
      Text(AgentActivityPresentation.toolActivityTitle(name: call.name, context: call.context))
        .font(.system(size: 12))
        .foregroundStyle(Color.dockSecondaryText)
        .lineLimit(1).truncationMode(.tail)
      if !call.isComplete { ProgressView().controlSize(.mini) }
    }
    .help(call.result ?? call.input)
  }

  static func icon(for toolName: String) -> Ph {
    let name = toolName.lowercased().replacingOccurrences(of: "-", with: "_")
    switch name {
    case "terminal", "shell", "exec", "exec_command", "process": return .terminal
    case "patch", "apply_patch", "edit_file", "write_file": return .pencilSimple
    case "read_file": return .fileText
    case "search_files", "search", "grep": return .magnifyingGlass
    case "view_image", "vision_analyze": return .image
    case "todo": return .listChecks
    default:
      if name.contains("delegate") || name.contains("subagent") { return .usersThree }
      if name.contains("browser") || name.contains("web") || name.contains("fetch") { return .globe }
      if name.contains("memory") || name.contains("skill") { return .brain }
      return .wrench
    }
  }
}

extension ActiveToolCall {
  /// Added and removed line counts of `diffPreview`, ignoring file headers.
  var diffStats: (added: Int, removed: Int)? {
    guard let diffPreview, !diffPreview.isEmpty else { return nil }
    var added = 0, removed = 0
    for line in diffPreview.split(separator: "\n", omittingEmptySubsequences: false) {
      if line.hasPrefix("+"), !line.hasPrefix("+++") { added += 1 }
      if line.hasPrefix("-"), !line.hasPrefix("---") { removed += 1 }
    }
    return (added, removed)
  }
}

/// Live compaction step: transcript lines squeeze into one while a shimmer
/// sweeps the label, settling into a static "Compacted context" step.
private struct CompactionStepRow: View {
  let call: ActiveToolCall
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isSqueezed = false
  @State private var shimmer: CGFloat = -1

  var body: some View {
    HStack(spacing: 8) {
      if call.isComplete {
        DockIcon(.arrowsInLineVertical, size: 13, color: Color.dockSecondaryText).frame(width: 16, height: 16)
          .transition(.scale.combined(with: .opacity))
        Text(title).font(.system(size: 12)).foregroundStyle(Color.dockSecondaryText)
      } else {
        squeezeGlyph.frame(width: 16, height: 16)
        Text("Compacting context")
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(Color.dockAccent)
          .overlay { if !reduceMotion { shimmerOverlay } }
      }
    }
    .animation(.dockEase(duration: 0.25), value: call.isComplete)
    .help("Hermes summarizes older turns to free context")
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(call.isComplete ? title : "Compacting context")
    .onAppear {
      guard !reduceMotion, !call.isComplete else { return }
      withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { isSqueezed = true }
      withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) { shimmer = 1 }
    }
  }

  private var title: String {
    call.completedAt.map { "Compacted context in \(TurnActivityView.roughDuration($0.timeIntervalSince(call.startedAt)))" }
      ?? "Compacted context"
  }

  /// Three transcript lines that fold toward the middle one and back.
  private var squeezeGlyph: some View {
    ZStack {
      ForEach(Array([(-4.5, 10.0), (0, 14.0), (4.5, 8.0)].enumerated()), id: \.offset) { index, line in
        Capsule()
          .fill(Color.dockAccent.opacity(index == 1 ? 1 : isSqueezed ? 0.25 : 0.7))
          .frame(width: isSqueezed ? 14 : line.1, height: 2)
          .offset(y: isSqueezed ? 0 : line.0)
      }
    }
  }

  private var shimmerOverlay: some View {
    GeometryReader { proxy in
      LinearGradient(colors: [.clear, .white.opacity(0.55), .clear], startPoint: .leading, endPoint: .trailing)
        .frame(width: proxy.size.width * 0.5)
        .offset(x: shimmer * proxy.size.width)
    }
    .mask(Text("Compacting context").font(.system(size: 12, weight: .medium)))
    .allowsHitTesting(false)
  }
}

/// Copies one fenced block and briefly confirms it in place.
private struct MarkdownCodeCopyButton: View {
  let code: String

  var body: some View {
    DockCopyButton(code, accessibilityLabel: "Copy code", presentation: .text)
      .font(DockTypography.control)
      .padding(.horizontal, 6).frame(height: 28).contentShape(Rectangle())
    .buttonStyle(.plain)
  }
}
