import Foundation

struct LocalProjectCommand: Equatable {
    let id: UUID
    let command: String
    var exitCode: Int?
    var interrupted = false
    var isRunning: Bool { exitCode == nil && !interrupted }

    static func payload(command: String, id: UUID) -> String? {
        guard !command.isEmpty, command.utf8.count <= 64 * 1024, !command.contains("\0") else { return nil }
        let quoted = "'" + command.replacingOccurrences(of: "'", with: "'\\''") + "'"
        // An ignored OSC reports completion without adding implementation markers to visible output.
        return "/bin/zsh -lc \(quoted); printf '\\033]777;herm-action;\(id.uuidString);%s\\007' \"$?\"\n"
    }
    static func exitCode(id: UUID, output: String) -> Int? {
        let prefix = "\u{1b}]777;herm-action;\(id.uuidString);"
        guard let start = output.range(of: prefix)?.upperBound,
            let end = output[start...].firstIndex(of: "\u{7}")
        else { return nil }
        return Int(output[start..<end])
    }
}
