import Foundation
import SwiftUI

/// Reusable conversation-only presentation primitives. They render DockModel
/// state but deliberately do not own transport, session, or input state.
struct ThinkingDots: View {
  var body: some View {
    TimelineView(.animation) { context in
      let t = context.date.timeIntervalSinceReferenceDate
      HStack(spacing: 4) {
        ForEach(0..<3) { i in
          let p = (t + Double(i) * 0.2).truncatingRemainder(dividingBy: 1.4) / 1.4
          let s = 0.6 + 0.4 * max(0, sin(p * .pi * 2))
          Circle().fill(Color.scifiAccent).frame(width: 6, height: 6).scaleEffect(s).opacity(s)
        }
      }
    }
  }
}

struct VoiceModeToolbar: View {
  var onReturnToChat: () -> Void
  var onToggleWorkspace: () -> Void
  var isWorkspaceVisible: Bool
  var canStopRequest: Bool
  var onStopRequest: () -> Void

  var body: some View {
    HStack {
      Button(action: onReturnToChat) {
        Image(systemName: "text.bubble").font(.system(size: 13, weight: .medium)).foregroundStyle(
          Color.scifiMuted
        ).frame(width: 36, height: 36).background(Circle().fill(Color.scifiSurface4))
      }
      .buttonStyle(.scifiPress).dockHitTarget().help("Return to chat")
      Spacer()
      HStack(spacing: 8) {
        Button(action: onToggleWorkspace) {
          Image(
            systemName: isWorkspaceVisible ? "rectangle.compress.vertical" : "rectangle.split.2x1"
          )
          .font(.system(size: 12, weight: .medium)).foregroundStyle(
            isWorkspaceVisible ? Color.scifiAccent : Color.scifiMuted
          ).frame(width: 36, height: 36)
          .background(
            Circle().fill(isWorkspaceVisible ? Color.scifiAccent.opacity(0.1) : Color.scifiSurface4)
          )
        }
        .buttonStyle(.scifiPress).dockHitTarget().help(
          isWorkspaceVisible ? "Hide Workspace" : "Show Workspace")
        if canStopRequest {
          Button(action: onStopRequest) {
            Image(systemName: "stop.fill").font(.system(size: 12, weight: .semibold))
              .foregroundStyle(Color.scifiDestructive).frame(width: 36, height: 36).background(
                Circle().fill(Color.scifiDestructive.opacity(0.1)))
          }
          .buttonStyle(.scifiPress).dockHitTarget().help("Stop Hermes request")
        }
      }
    }
  }
}

struct AgentAvatar: View {
  let identity: String
  let statusColor: Color

  private var seed: Int { identity.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) } }

  var body: some View {
    let rotation = Double(seed % 360)
    let secondaryRotation = Double((seed / 7) % 360)
    ZStack {
      Circle().fill(
        RadialGradient(
          colors: [Color.scifiAccent.opacity(0.3), Color.scifiAccent.opacity(0.08)],
          center: UnitPoint(x: 0.32, y: 0.24), startRadius: 1, endRadius: 20))
      Circle().stroke(Color.scifiAccent.opacity(0.36), lineWidth: 0.6)
      Circle().trim(from: 0.08, to: 0.43).stroke(
        Color.scifiAccent.opacity(0.8), style: StrokeStyle(lineWidth: 1, lineCap: .round)
      ).rotationEffect(.degrees(rotation)).padding(4)
      Circle().trim(from: 0.58, to: 0.77).stroke(
        Color.white.opacity(0.3), style: StrokeStyle(lineWidth: 0.6, lineCap: .round)
      ).rotationEffect(.degrees(secondaryRotation)).padding(7)
      Circle().fill(statusColor).frame(width: 4, height: 4).offset(x: 8, y: -7).shadow(
        color: statusColor.opacity(0.8), radius: 3)
      Circle().fill(Color.scifiAccent.opacity(0.9)).frame(width: 5, height: 5)
    }
    .shadow(color: Color.scifiAccent.opacity(0.18), radius: 6).accessibilityLabel("Agent avatar")
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

struct MarkdownMessageView: View {
  let markdown: String
  private enum Block {
    case heading(level: Int, text: String)
    case paragraph(String)
    case listItem(text: String, marker: String)
    case code(String, language: String?)
    case quote(String)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
        switch block {
        case .heading(let level, let text):
          renderedText(text).font(.system(size: Self.headingSize(level), weight: .bold)).padding(
            .top, 2)
        case .paragraph(let text): renderedText(text).font(.system(size: 14)).lineSpacing(3)
        case .listItem(let text, let marker):
          HStack(alignment: .top, spacing: 6) {
            Text(marker).font(.system(size: 14, weight: .medium)).foregroundStyle(Color.scifiAccent)
              .frame(minWidth: 16, alignment: .trailing)
            renderedText(text).font(.system(size: 14)).lineSpacing(3)
          }
        case .code(let code, let language): codeBlock(code, language: language)
        case .quote(let text):
          renderedText(text).font(.system(size: 14)).foregroundStyle(Color.scifiMuted).padding(
            .leading, 10
          ).overlay(alignment: .leading) { Rectangle().fill(Color.scifiBorder).frame(width: 2) }
        }
      }
    }
  }

  private func renderedText(_ value: String) -> some View {
    Text(inlineMarkdown(value)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
  }
  private func codeBlock(_ code: String, language: String?) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      if let language {
        Text(language).font(.system(size: 12, weight: .medium, design: .monospaced))
          .foregroundStyle(Color.scifiMuted).textCase(.uppercase).padding(.horizontal, 8).padding(
            .top, 6)
      }
      ScrollView(.horizontal, showsIndicators: false) {
        Text(code).font(.system(size: 12.5, design: .monospaced)).textSelection(.enabled).frame(
          maxWidth: .infinity, alignment: .leading
        ).padding(.horizontal, 8).padding(.vertical, 6)
      }
    }.background(
      RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.scifiSurface4).stroke(
        Color.scifiBorder, lineWidth: 0.5))
  }
  private static func headingSize(_ level: Int) -> CGFloat {
    level == 1 ? 20 : level == 2 ? 17 : level == 3 ? 15 : 14
  }
  private var blocks: [Block] {
    var result: [Block] = []
    var code: [String] = []
    var language: String?
    var inCode = false
    var paragraph: [String] = []
    var orderedIndex = 0
    func flushParagraph() {
      let text = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
      paragraph.removeAll()
      orderedIndex = 0
      if !text.isEmpty { result.append(.paragraph(text)) }
    }
    func flushCode() {
      result.append(.code(code.joined(separator: "\n"), language: language))
      code.removeAll()
      language = nil
    }
    for line in markdown.components(separatedBy: "\n") {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
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
      if let level = Self.headingLevel(trimmed) {
        flushParagraph()
        result.append(
          .heading(
            level: level,
            text: String(trimmed.drop(while: { $0 == "#" }).drop(while: { $0 == " " }))))
        continue
      }
      if let content = Self.orderedListContent(trimmed) {
        flushParagraph()
        orderedIndex += 1
        result.append(.listItem(text: content, marker: "\(orderedIndex)."))
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
  private static func headingLevel(_ line: String) -> Int? {
    let hashes = line.prefix(while: { $0 == "#" }).count
    guard hashes > 0, hashes <= 6, line.count > hashes,
      line[line.index(line.startIndex, offsetBy: hashes)] == " "
    else { return nil }
    return hashes
  }
  private static func orderedListContent(_ line: String) -> String? {
    guard let dotIndex = line.firstIndex(of: "."), !line[..<dotIndex].isEmpty,
      line[..<dotIndex].allSatisfy(\.isNumber), line.index(after: dotIndex) < line.endIndex,
      line[line.index(after: dotIndex)] == " "
    else { return nil }
    return String(line[line.index(dotIndex, offsetBy: 2)...]).trimmingCharacters(in: .whitespaces)
  }
  private static func unorderedListItem(_ line: String) -> String? {
    for prefix in ["- ", "* ", "+ "] where line.hasPrefix(prefix) {
      return String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
    }
    return nil
  }
  private func inlineMarkdown(_ value: String) -> AttributedString {
    (try? AttributedString(
      markdown: groupedNumbers(in: value),
      options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
      ?? AttributedString(value)
  }
  private func groupedNumbers(in value: String) -> String {
    guard
      let regex = try? NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9_./-])\d{4,}(?![A-Za-z0-9_./-])"#)
    else { return value }
    var result = value
    let range = NSRange(value.startIndex..., in: value)
    for match in regex.matches(in: value, range: range).reversed() {
      guard let matchRange = Range(match.range, in: result) else { continue }
      let number = String(result[matchRange])
      guard !(number.count == 4 && (number.hasPrefix("19") || number.hasPrefix("20"))) else {
        continue
      }
      let digits = Array(number)
      var grouped = ""
      for index in digits.indices {
        if index > 0 && (digits.count - index).isMultiple(of: 3) { grouped.append(",") }
        grouped.append(digits[index])
      }
      result.replaceSubrange(matchRange, with: grouped)
    }
    return result
  }
}

struct ConversationBottomPreferenceKey: PreferenceKey {
  static let defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct ConversationActivityRow: View {
  @ObservedObject var model: DockModel
  var horizontalInset: CGFloat = 20
  private var latestPipelineActivity: AgentActivityPresentation.PipelineActivity? {
    AgentActivityPresentation.pipeline(
      activities: model.agentActivities, toolCalls: model.activeToolCalls,
      subagents: model.displayedSubagents
    ).first(where: \.isActive)
  }
  private var title: String {
    guard latestPipelineActivity != nil else { return "Responding" }
    return AgentActivityPresentation.conversationTitle(
      latestPipelineActivity: latestPipelineActivity, recentEvents: model.recentEvents)
  }
  var body: some View {
    HStack(spacing: 6) {
      ThinkingDots()
      Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.scifiMuted)
        .lineLimit(1).truncationMode(.tail)
    }.padding(.horizontal, horizontalInset).padding(.vertical, 8).frame(
      maxWidth: .infinity, alignment: .leading)
  }
}
