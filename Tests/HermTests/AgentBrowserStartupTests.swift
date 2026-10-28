import Foundation
import Testing

@testable import Herm

@MainActor
struct AgentBrowserStartupTests {
    @Test func fixedPortRequiresOwnAnnouncementAndRetries() async throws {
        var probes = 0
        var sleeps: [Duration] = []
        let startup = HermAgentBrowserStartup(
            sleep: { sleeps.append($0) },
            load: { request in
                probes += 1
                return (
                    Self.version,
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                )
            })
        let endpoint = try await startup.waitForEndpoint(
            URL(fileURLWithPath: "/missing"), fixedPort: 9333,
            announced: { _ in probes >= 2 }, isRunning: { true })
        #expect(endpoint.ws.absoluteString == "ws://127.0.0.1:9333/devtools/browser/test")
        #expect(probes == 2)
        #expect(sleeps == [.milliseconds(50)])
    }

    @Test func readyEndpointDoesNotSleep() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try "9333\n/devtools/browser/test".write(to: file, atomically: true, encoding: .utf8)
        var sleeps: [Duration] = []
        let startup = HermAgentBrowserStartup(
            sleep: { sleeps.append($0) },
            load: { request in
                (
                    Self.version,
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                )
            })
        let endpoint = try await startup.waitForEndpoint(file, isRunning: { true })
        #expect(endpoint.port == 9333)
        #expect(sleeps.isEmpty, "A ready browser must be probed before sleeping")
    }

    @Test func delayedEndpointUsesFastPolling() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try "9333\n/devtools/browser/test".write(to: file, atomically: true, encoding: .utf8)
        var sleeps: [Duration] = []
        var probes = 0
        let startup = HermAgentBrowserStartup(
            sleep: { sleeps.append($0) },
            load: { request in
                probes += 1
                return (
                    Self.version,
                    HTTPURLResponse(
                        url: request.url!, statusCode: probes == 3 ? 200 : 503,
                        httpVersion: nil, headerFields: nil)!
                )
            })
        _ = try await startup.waitForEndpoint(file, isRunning: { true })
        #expect(sleeps == [.milliseconds(50), .milliseconds(50)])
        #expect(probes == 3)
    }

    @Test func readinessBudgetExpires() async throws {
        var time: Duration = .zero
        var sleeps = 0
        let startup = HermAgentBrowserStartup(
            now: { time },
            sleep: { duration in
                sleeps += 1
                time += duration
            })
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        await #expect(throws: NSError.self) {
            try await startup.waitForEndpoint(missing, isRunning: { true })
        }
        #expect(time == .seconds(15))
        #expect(sleeps == 300)
    }

    @Test func cancellationDuringProbeRejectsSuccessfulResponse() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try "9333\n/devtools/browser/test".write(to: file, atomically: true, encoding: .utf8)
        let task = Task {
            let startup = HermAgentBrowserStartup(load: { request in
                withUnsafeCurrentTask { $0?.cancel() }
                return (
                    Self.version,
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                )
            })
            return try await startup.waitForEndpoint(file, isRunning: { true })
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func successfulProbeAfterDeadlineIsRejected() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try "9333\n/devtools/browser/test".write(to: file, atomically: true, encoding: .utf8)
        var time: Duration = .zero
        var probes = 0
        let startup = HermAgentBrowserStartup(
            now: { time },
            load: { request in
                probes += 1
                time = .seconds(15)
                return (
                    Self.version,
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                )
            })
        await #expect(throws: NSError.self) { try await startup.waitForEndpoint(file, isRunning: { true }) }
        #expect(probes == 1)
    }

    @Test func exitedProcessStopsWaiting() async throws {
        var probes = 0
        let startup = HermAgentBrowserStartup(load: { _ in
            probes += 1
            throw URLError(.cannotConnectToHost)
        })
        await #expect(throws: NSError.self) {
            try await startup.waitForEndpoint(URL(fileURLWithPath: "/missing"), isRunning: { false })
        }
        #expect(probes == 0)
    }

    @Test func endpointAndOccupancyResponses() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try "9333\n/devtools/browser/test".write(to: file, atomically: true, encoding: .utf8)
        var status = 200
        let startup = HermAgentBrowserStartup(
            now: { .zero },
            load: { request in
                #expect(request.timeoutInterval == 0.5)
                return (
                    Self.version,
                    HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
                )
            })
        let endpoint = try await startup.endpoint(file, deadline: .seconds(1))
        #expect(endpoint?.ws.absoluteString == "ws://127.0.0.1:9333/devtools/browser/test")
        status = 503
        #expect(try await startup.endpoint(file, deadline: .seconds(1))?.port == nil)
        #expect(try await startup.occupied(9333, deadline: .seconds(1)))
        #expect(!(try await startup.occupied(9333, deadline: .zero)))
    }

    private static let version = Data(#"{"webSocketDebuggerUrl":"ws://127.0.0.1:9333/devtools/browser/test"}"#.utf8)
}
