import Foundation
import AppKit
import SwiftUI

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
  private let cacheResult: Bool
  private let bodySize: CGFloat
  private let bodyWeight: NSFont.Weight
  /// Every message shares one identity, so the render cache is keyed by
  /// content. A per-view UUID missed the cache whenever paging remounted a row.
  private static let identity = UUID()
  typealias RenderBlock = MarkdownRenderDocumentBuilder.RenderBlock
  init(markdown: String, cacheResult: Bool = true, cacheKey: String? = nil, bodySize: CGFloat = DockTypography.size(.conversation), bodyWeight: NSFont.Weight = .regular) {
    self.markdown = markdown; self.bodySize = bodySize; self.bodyWeight = bodyWeight; self.cacheResult = cacheResult
  }
  nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.markdown == rhs.markdown && lhs.bodySize == rhs.bodySize && lhs.bodyWeight == rhs.bodyWeight && lhs.cacheResult == rhs.cacheResult }
  var body: some View {
    NativeMarkdownDocumentHost(source: markdown, key: Self.renderKey(for: markdown, bodySize: bodySize, bodyWeight: bodyWeight), bodySize: bodySize, bodyWeight: bodyWeight, cacheResult: cacheResult)
  }
  static func renderKey(for markdown: String, bodySize: CGFloat = DockTypography.size(.conversation), bodyWeight: NSFont.Weight = .regular) -> MarkdownRenderKey {
    MarkdownRenderKey(messageID: identity, contentRevision: markdown.hashValue, themeRevision: DockThemeRuntime.revision,
                      segment: Int(bodySize * 100 + bodyWeight.rawValue * 10))
  }
  static func renderBlocks(for markdown: String) -> [RenderBlock] { MarkdownRenderDocumentBuilder.renderBlocks(for: markdown) }
  static func codeBlockLanguages(in markdown: String) -> [String?] { MarkdownRenderDocumentBuilder.codeBlockLanguages(in: markdown) }
  static func orderedListMarkers(in markdown: String) -> [String] { MarkdownRenderDocumentBuilder.orderedListMarkers(in: markdown) }
  static func linkAffordances(in value: AttributedString) -> AttributedString {
    var styled = value
    for run in styled.runs where run.link != nil {
      styled[run.range].foregroundColor = Color.dockAccent
      styled[run.range].underlineStyle = .single
    }
    return styled
  }
}

