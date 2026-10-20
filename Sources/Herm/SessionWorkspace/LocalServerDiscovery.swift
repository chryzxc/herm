import Foundation

struct LocalPreviewServer: Identifiable, Equatable, Sendable {
    let pid: Int32
    let port: Int
    var processName: String? = nil
    var host = "127.0.0.1"
    var id: String { "\(pid):\(port)" }
    var url: URL { URL(string: "http://\(host.contains(":") ? "[" + host + "]" : host):\(port)")! }
}

enum LocalServerDiscovery {
    static func descendants(roots: Set<Int32>, processTable: String) -> Set<Int32> {
        let pairs = processTable.split(separator: "\n").compactMap { row -> (Int32, Int32)? in
            let fields = row.split(whereSeparator: \.isWhitespace)
            guard fields.count == 2, let child = Int32(fields[0]), let parent = Int32(fields[1]) else { return nil }
            return (child, parent)
        }
        var result = roots
        for _ in 0..<32 {
            let children = Set(pairs.filter { result.contains($0.1) }.map(\.0))
            let merged = result.union(children)
            if merged == result { break }
            result = merged
        }
        return result
    }
    static func parse(_ text: String, owned: Set<Int32>) -> [LocalPreviewServer] {
        var pid: Int32 = 0
        var command: String?
        var servers: [LocalPreviewServer] = []
        for row in text.split(separator: "\n") {
            if row.first == "p" {
                pid = Int32(row.dropFirst()) ?? 0
                command = nil
            }
            if row.first == "c" { command = String(row.dropFirst().prefix(80)) }
            if row.first == "n", owned.contains(pid), let last = row.lastIndex(of: ":"),
                let port = Int(row[row.index(after: last)...]), (1...65535).contains(port)
            {
                let address = String(row.dropFirst()[..<last])
                guard ["127.0.0.1", "[::1]", "*", "localhost"].contains(address) else { continue }
                let server = LocalPreviewServer(
                    pid: pid, port: port, processName: command, host: address == "[::1]" ? "::1" : "127.0.0.1")
                if let index = servers.firstIndex(where: { $0.id == server.id }) {
                    if server.host == "127.0.0.1" { servers[index] = server }
                } else {
                    servers.append(server)
                }
            }
        }
        return servers.sorted { $0.port < $1.port }
    }
    static func discover(roots: [Int32]) async throws -> [LocalPreviewServer] {
        guard !roots.isEmpty else { return [] }
        let candidates = try await Task.detached(priority: .utility) {
            func run(_ command: String, _ arguments: [String], emptyExit: Int32? = nil) throws -> String {
                let process = Process()
                let pipe = Pipe()
                process.executableURL = URL(fileURLWithPath: command)
                process.arguments = arguments
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                try process.run()
                let output = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0 || process.terminationStatus == emptyExit else {
                    throw NSError(
                        domain: "Herm.LocalPreviews", code: Int(process.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: "Could not inspect local terminal listeners."])
                }
                return String(decoding: output.prefix(128 * 1024), as: UTF8.self)
            }
            let owned = descendants(roots: Set(roots), processTable: try run("/bin/ps", ["-axo", "pid=,ppid="]))
            let output = try run(
                "/usr/sbin/lsof",
                [
                    "-nP", "-a", "-p", owned.sorted().prefix(500).map(String.init).joined(separator: ","), "-iTCP",
                    "-sTCP:LISTEN", "-Fpcn",
                ], emptyExit: 1)
            return parse(output, owned: owned)
        }.value
        return await withTaskGroup(of: LocalPreviewServer?.self) { group in
            for candidate in candidates.prefix(32) {
                group.addTask { await LocalPreviewProbe.reachable(candidate) ? candidate : nil }
            }
            var reachable: [LocalPreviewServer] = []
            for await candidate in group { if let candidate { reachable.append(candidate) } }
            return reachable.sorted { $0.port < $1.port }
        }
    }
}
