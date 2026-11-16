import Darwin
import Foundation
import Testing

@testable import Herm

/// Stands in for `hermes serve`: it starts MCP-like children, announces a port, and waits.
private let fakeBackend = [
    "/bin/sh", "-c", "for i in 1 2 3; do /bin/sleep 600 & done; echo 'listening on 127.0.0.1:4242'; wait",
]

/// Stands in for Herm: it holds the write end of the backend's stdin and keeps it open until it dies.
private let hermStandIn = """
    pipe(my $r, my $w) or die;
    my $pid = fork;
    if (!$pid) { open STDIN, '<&', $r; close $w; close $r; exec @ARGV; die }
    close $r;
    $| = 1;
    print "$pid\\n";
    sleep 600;
    """

struct HermesBackendLaunchTests {
    @Test func backendTreeEndsWhenHermIsKilled() async throws {
        let backend = HermesBackendLaunch.process(command: fakeBackend)
        let parent = Process()
        parent.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        parent.arguments = ["-e", hermStandIn, try #require(backend.executableURL?.path)] + (backend.arguments ?? [])
        let output = Pipe()
        parent.standardOutput = output
        try parent.run()
        defer { kill(parent.processIdentifier, SIGKILL) }

        let line = String(decoding: output.fileHandleForReading.availableData, as: UTF8.self)
        let root = try #require(pid_t(line.trimmingCharacters(in: .whitespacesAndNewlines)))
        let tree = try await startedTree(root: root)
        defer { for pid in tree { kill(pid, SIGKILL) } }

        kill(parent.processIdentifier, SIGKILL)
        #expect(await allExit(tree), "backend processes outlived Herm: \(tree.filter(isAlive))")
    }

    @Test func backendTreeEndsWhenHermClosesItsEnd() async throws {
        let backend = HermesBackendLaunch.process(command: fakeBackend)
        backend.standardOutput = FileHandle.nullDevice
        try backend.run()
        let tree = try await startedTree(root: backend.processIdentifier)
        defer { for pid in tree { kill(pid, SIGKILL) } }

        let lifeline = try #require(backend.standardInput as? Pipe)
        try lifeline.fileHandleForWriting.close()
        #expect(await allExit(tree), "backend processes outlived Herm: \(tree.filter(isAlive))")
    }

    @Test func terminateEndsTheWholeBackendTree() async throws {
        let backend = HermesBackendLaunch.process(command: fakeBackend)
        backend.standardOutput = FileHandle.nullDevice
        try backend.run()
        let tree = try await startedTree(root: backend.processIdentifier)
        defer { for pid in tree { kill(pid, SIGKILL) } }

        backend.terminate()
        #expect(await allExit(tree), "backend processes outlived terminate: \(tree.filter(isAlive))")
    }

    /// Herm can be gone before the supervisor finishes starting, so the watcher sees EOF at once.
    /// The injected delay widens the startup window that a TERM must not reach before `stop` is trapped.
    @Test func backendEndsWhenHermIsGoneDuringStartup() async throws {
        let marker = String(Int.random(in: 100_000_000...999_999_999))
        let backend = HermesBackendLaunch.process(command: ["/bin/sleep", marker])
        var arguments = try #require(backend.arguments)
        let widened = arguments[1].replacingOccurrences(of: "exec 3<&-\n", with: "exec 3<&-\nsleep 0.2\n")
        try #require(widened != arguments[1], "supervisor no longer closes the lifeline where the test widens startup")
        arguments[1] = widened
        backend.arguments = arguments
        backend.standardOutput = FileHandle.nullDevice
        try #require(backend.standardInput as? Pipe).fileHandleForWriting.close()
        try backend.run()

        let orphans = {
            try ps(["-axo", "pid=,command="]).split(separator: "\n").filter { $0.hasSuffix("/bin/sleep \(marker)") }
        }
        defer {
            for row in (try? orphans()) ?? [] {
                if let pid = pid_t(row.split(separator: " ")[0]) { kill(pid, SIGKILL) }
            }
        }
        var attempts = 0
        while try backend.isRunning || !orphans().isEmpty, attempts < 60 {
            try await Task.sleep(for: .milliseconds(50))
            attempts += 1
        }
        #expect(!backend.isRunning, "supervisor did not exit after Herm's end closed")
        #expect(try orphans().isEmpty, "backend outlived a supervisor that saw EOF during startup")
    }

    @Test func backendOutputStillReachesHerm() throws {
        let backend = HermesBackendLaunch.process(command: ["/bin/sh", "-c", "echo 'listening on 127.0.0.1:4242'"])
        let output = Pipe()
        backend.standardOutput = output
        try backend.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        backend.waitUntilExit()
        #expect(text == "listening on 127.0.0.1:4242\n")
        #expect(backend.terminationStatus == 0)
    }
}

/// Waits until the three fake MCP children exist, then returns every process under `root`, `root` included.
private func startedTree(root: pid_t) async throws -> [pid_t] {
    for _ in 0..<100 {
        let tree = try descendants(of: root)
        if try tree.filter({ try command(of: $0) == "/bin/sleep" }).count == 3 { return [root] + tree }
        try await Task.sleep(for: .milliseconds(50))
    }
    Issue.record("fake backend never started its children")
    return [root]
}

private func allExit(_ pids: [pid_t]) async -> Bool {
    for _ in 0..<100 {
        if !pids.contains(where: isAlive) { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return false
}

private func isAlive(_ pid: pid_t) -> Bool {
    guard kill(pid, 0) == 0 else { return false }
    return (try? command(of: pid)) != nil
}

private func command(of pid: pid_t) throws -> String? {
    let line = try ps(["-o", "stat=,comm=", "-p", "\(pid)"]).trimmingCharacters(in: .whitespacesAndNewlines)
    let fields = line.split(separator: " ", maxSplits: 1)
    guard fields.count == 2, !fields[0].hasPrefix("Z") else { return nil }
    return fields[1].trimmingCharacters(in: .whitespaces)
}

private func descendants(of root: pid_t) throws -> [pid_t] {
    let pairs = try ps(["-axo", "pid=,ppid="]).split(separator: "\n").compactMap { row -> (pid_t, pid_t)? in
        let fields = row.split(separator: " ")
        guard fields.count == 2, let pid = pid_t(fields[0]), let ppid = pid_t(fields[1]) else { return nil }
        return (pid, ppid)
    }
    var found: [pid_t] = []
    var frontier = [root]
    while let parent = frontier.popLast() {
        let children = pairs.filter { $0.1 == parent }.map(\.0)
        found += children
        frontier += children
    }
    return found
}

private func ps(_ arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = arguments
    let output = Pipe()
    process.standardOutput = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}
