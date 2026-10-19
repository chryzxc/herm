import Foundation

enum RichContentRedaction {
  static func text(_ value: String, limit: Int = 4_000) -> String {
    var text = String(value.prefix(limit))
    let patterns = [
      #"(?i)(bearer\s+)[A-Za-z0-9._~+/=-]+"#,
      #"(?i)((?:api[_-]?key|access[_-]?token|refresh[_-]?token|password|secret|authorization)["']?\s*[=:]\s*[\"']?)[^\s\"',;}]+"#,
      #"\b(?:sk-[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9_]{16,})\b"#,
    ]
    for pattern in patterns {
      guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
      text = regex.stringByReplacingMatches(
        in: text, range: NSRange(text.startIndex..., in: text),
        withTemplate: regex.numberOfCaptureGroups > 0 ? "$1[redacted]" : "[redacted]")
    }
    text = text.replacingOccurrences(
      of: #"/Users/[^/\s]+/"#, with: "~/", options: .regularExpression)
    return text
  }
}

