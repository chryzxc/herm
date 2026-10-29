import Foundation

#if !HERM_BROWSER_REPRO_STANDALONE
    import Testing
    @testable import Herm
#endif

/// Opt-in protocol reproduction; never opens a real Herm or personal Chrome profile.
struct AgentBrowserStartupReproductionTests {
    #if !HERM_BROWSER_REPRO_STANDALONE
        @Test
    #endif
    func fixedPortDiscoversBrowserWithoutFile() async throws {
        guard ProcessInfo.processInfo.environment["HERM_BROWSER_STARTUP_REPRO"] == "1" else { return }
        let executable = URL(fileURLWithPath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
        let random = try await launch(executable: executable, port: 0)
        guard random.ready, random.hasPortFile, let selectedPort = random.port else {
            throw NSError(
                domain: "Herm.BrowserReproduction", code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: "Random-port control did not start with a discovery file"
                ])
        }
        let fixed = try await launch(executable: executable, port: selectedPort)
        print("Browser discovery: random ready=\(random.ready) file=\(random.hasPortFile)")
        print("Browser discovery: fixed ready=\(fixed.ready) file=\(fixed.hasPortFile)")
        guard fixed.ready else {
            throw NSError(
                domain: "Herm.BrowserReproduction", code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey: "Fixed-port control did not serve /json/version"
                ])
        }
        guard fixed.discovered else {
            throw NSError(
                domain: "Herm.BrowserReproduction", code: 3,
                userInfo: [
                    NSLocalizedDescriptionKey: "Herm could not discover the healthy fixed-port browser"
                ])
        }
    }

    private func launch(executable: URL, port: Int) async throws -> (
        port: Int?, ready: Bool, hasPortFile: Bool, discovered: Bool
    ) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("herm-browser-repro-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let portFile = root.appendingPathComponent("DevToolsActivePort")
        let process = Process()
        process.executableURL = executable
        process.arguments = [
            "--headless=new", "--remote-debugging-port=\(port)", "--user-data-dir=\(root.path)",
            "--no-first-run", "--no-default-browser-check", "about:blank",
        ]
        process.standardOutput = FileHandle.nullDevice
        let announcement = AgentBrowserAnnouncement()
        let errors = Pipe()
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { announcement.consume(data) }
        }
        process.standardError = errors
        try process.run()
        defer {
            process.terminate()
            process.waitUntilExit()
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 0.5
        configuration.timeoutIntervalForResource = 0.5
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var selectedPort: Int? = port == 0 ? nil : port
        for _ in 0..<80 {
            try await Task.sleep(for: .milliseconds(100))
            if selectedPort == nil,
                let text = try? String(contentsOf: portFile, encoding: .utf8),
                let first = text.split(separator: "\n").first
            {
                selectedPort = Int(first)
            }
            guard let selectedPort,
                let url = URL(string: "http://127.0.0.1:\(selectedPort)/json/version"),
                let (data, response) = try? await session.data(from: url),
                (response as? HTTPURLResponse)?.statusCode == 200,
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                json["webSocketDebuggerUrl"] as? String != nil
            else { continue }
            try await Task.sleep(for: .milliseconds(300))
            let endpoint = await AgentBrowserEndpoint.discoverLaunched(
                portFile: portFile, fixedPort: port == 0 ? nil : port,
                process: process, announcement: announcement, session: session)
            if port == 0 {
                let rivalRoot = root.appendingPathComponent("rival")
                try FileManager.default.createDirectory(at: rivalRoot, withIntermediateDirectories: true)
                let rival = Process()
                rival.executableURL = executable
                rival.arguments = [
                    "--headless=new", "--remote-debugging-port=\(selectedPort)", "--user-data-dir=\(rivalRoot.path)",
                    "--no-first-run", "--no-default-browser-check", "about:blank",
                ]
                let rivalAnnouncement = AgentBrowserAnnouncement()
                let rivalErrors = Pipe()
                rivalErrors.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty { handle.readabilityHandler = nil } else { rivalAnnouncement.consume(data) }
                }
                rival.standardOutput = FileHandle.nullDevice
                rival.standardError = rivalErrors
                try rival.run()
                defer {
                    if rival.isRunning { rival.terminate() }
                    rival.waitUntilExit()
                }
                try await Task.sleep(for: .milliseconds(800))
                let stolen = await AgentBrowserEndpoint.discoverLaunched(
                    portFile: rivalRoot.appendingPathComponent("DevToolsActivePort"), fixedPort: selectedPort,
                    process: rival, announcement: rivalAnnouncement, session: session)
                guard stolen == nil else {
                    throw NSError(
                        domain: "Herm.BrowserReproduction", code: 4,
                        userInfo: [NSLocalizedDescriptionKey: "Competing browser was accepted"])
                }
                print("Browser discovery: competing listener rejected")
            }
            let expected = json["webSocketDebuggerUrl"] as? String
            return (
                selectedPort, true, FileManager.default.fileExists(atPath: portFile.path),
                endpoint?.port == selectedPort && endpoint?.ws.absoluteString == expected
            )
        }
        return (selectedPort, false, FileManager.default.fileExists(atPath: portFile.path), false)
    }
}

#if HERM_BROWSER_REPRO_STANDALONE
    @main
    struct BrowserStartupReproduction {
        static func main() async {
            do {
                try await AgentBrowserStartupReproductionTests().fixedPortDiscoversBrowserWithoutFile()
            } catch {
                print("REPRO_FAILED: \(error)")
                exit(1)
            }
        }
    }
#endif
