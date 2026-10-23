import Foundation
import Testing

@testable import Herm

@MainActor
struct HermesRuntimeConfigurationRefreshTests {
    private func configuration(_ name: String = "Fixture") -> HermesRuntimeConfiguration {
        HermesRuntimeConfiguration(
            agentName: name, model: "model", provider: "provider",
            configPath: "/fixture/config.yaml", maxTurns: "10", terminalTimeout: "15",
            skills: ["skill"], skillsInventory: .supported(["skill"]), mcpServers: ["server"], plugins: ["plugin"])
    }

    @Test func firstInspectionMetadataChangeCannotCertifyOldValues() async {
        var signature = "before"
        var reads = 0
        let refresh = HermesRuntimeConfigurationRefresh(
            scope: { "local" }, metadata: { _ in signature },
            reader: { _ in
                reads += 1
                return HermesRuntimeInspector.inspect(
                    runner: { arguments in
                        if arguments == ["config", "path"] { return "/fixture/config.yaml" }
                        if arguments == ["skills", "list", "--enabled-only"] { return "[]" }
                        if arguments == ["mcp", "list"] { return "No MCP servers configured" }
                        if arguments == ["plugins", "list", "--enabled", "--json"] { return "[]" }
                        return "value"
                    },
                    identityReader: { _ in
                        signature = "after"
                        return "Old identity"
                    }, signatureReader: { _ in signature })
            })
        await refresh.refresh()
        await refresh.refresh()
        #expect(reads == 2)
    }

    @Test func unavailablePreReadSignatureNeverCertifiesFreshness() async {
        var reads = 0
        let value = configuration()
        let refresh = HermesRuntimeConfigurationRefresh(
            scope: { "local" }, metadata: { _ in "after" },
            reader: { _ in
                reads += 1
                return .init(configuration: value, isComplete: true, initialSignature: nil)
            })
        await refresh.refresh()
        await refresh.refresh()
        #expect(reads == 2)
        #expect(refresh.configuration == value)
    }

    @Test func freshHitsTTLAndMetadataScopeChanges() async {
        var instant: TimeInterval = 0
        var signature = "original"
        var scope = "local"
        var reads = 0
        let value = configuration()
        let refresh = HermesRuntimeConfigurationRefresh(
            clock: { instant }, scope: { scope },
            metadata: { _ in signature },
            reader: { identity in
                reads += 1
                await identity(value.agentName)
                return .init(configuration: value, isComplete: true, initialSignature: signature)
            })
        await refresh.refresh()
        await refresh.refresh()
        #expect(reads == 1)
        instant = 29.999
        await refresh.refresh()
        #expect(reads == 1)
        instant = 30
        await refresh.refresh()
        #expect(reads == 2)
        signature = "replacement"
        await refresh.refresh()
        #expect(reads == 3)
        scope = "other"
        await refresh.refresh()
        #expect(reads == 4)
        await refresh.refresh(force: true)
        #expect(reads == 5)
        instant = 61
        await refresh.refresh()
        #expect(reads == 6)
    }

    @Test func failureIsRetryableAndRetainsGoodSnapshot() async {
        var complete = true
        var reads = 0
        let good = configuration()
        let partial = HermesRuntimeConfiguration(
            agentName: "Early", model: nil, provider: nil,
            configPath: nil, maxTurns: nil, terminalTimeout: nil, skills: [],
            skillsInventory: .unavailable(.emptyOutput), mcpServers: [], plugins: [])
        let refresh = HermesRuntimeConfigurationRefresh(
            scope: { "local" }, metadata: { _ in "same" },
            reader: { _ in
                reads += 1
                return .init(configuration: complete ? good : partial, isComplete: complete, initialSignature: "same")
            })
        await refresh.refresh()
        complete = false
        await refresh.refresh(force: true)
        #expect(refresh.configuration == good)
        #expect(refresh.error != nil)
        await refresh.refresh()
        #expect(reads == 3)
        #expect(refresh.configuration == good)
        complete = true
        await refresh.refresh()
        #expect(reads == 4)
        #expect(refresh.error == nil)
    }

    @Test func concurrentRequestsAndForceStormShareOneSerialFollowup() async {
        let first = configuration("Old")
        let latest = configuration("Latest")
        var continuation: CheckedContinuation<Void, Never>?
        var reads = 0
        var published: [String] = []
        let refresh = HermesRuntimeConfigurationRefresh(
            scope: { "local" }, metadata: { _ in "same" },
            reader: { identity in
                reads += 1
                let read = reads
                if read == 1 { await withCheckedContinuation { continuation = $0 } }
                await identity(read == 1 ? "Old" : "Latest")
                return .init(configuration: read == 1 ? first : latest, isComplete: true, initialSignature: "same")
            })
        refresh.onChange = {
            if let name = refresh.configuration?.agentName { published.append(name) }
        }
        let automatic = Task { await refresh.refresh() }
        while continuation == nil { await Task.yield() }
        let shared = Task { await refresh.refresh() }
        var forcesStarted = 0
        let force1 = Task {
            forcesStarted += 1
            await refresh.refresh(force: true)
        }
        let force2 = Task {
            forcesStarted += 1
            await refresh.refresh(force: true)
        }
        while forcesStarted < 2 { await Task.yield() }
        continuation?.resume()
        await automatic.value
        await shared.value
        await force1.value
        await force2.value
        #expect(reads == 2)
        #expect(refresh.configuration == latest)
        #expect(!published.contains("Old"))
        #expect(!refresh.isLoading)
    }

    @Test func unknownMetadataAndPartialFirstLoadNeverBecomeFresh() async {
        var reads = 0
        let value = configuration()
        let refresh = HermesRuntimeConfigurationRefresh(
            scope: { "local" }, metadata: { _ in nil },
            reader: { _ in
                reads += 1
                return .init(configuration: value, isComplete: false)
            })
        await refresh.refresh()
        #expect(refresh.configuration == value)
        #expect(refresh.error != nil)
        await refresh.refresh()
        #expect(reads == 2)
        let isolated = HermesRuntimeConfigurationRefresh(
            scope: { "local" }, metadata: { _ in "same" },
            reader: { _ in
                .init(configuration: value, isComplete: true, initialSignature: "same")
            })
        #expect(isolated.configuration == nil)
        let unknown = HermesRuntimeConfigurationRefresh(
            scope: { "local" }, metadata: { _ in nil },
            reader: { _ in
                reads += 1
                return .init(configuration: value, isComplete: true)
            })
        await unknown.refresh()
        await unknown.refresh()
        #expect(reads == 4)
    }

    @Test func earlyIdentityRetainsInventoriesAndCancellationRejectsLateOutput() async {
        var reads = 0
        var continuation: CheckedContinuation<Void, Never>?
        let good = configuration()
        let refresh = HermesRuntimeConfigurationRefresh(
            scope: { "local" }, metadata: { _ in "same" },
            reader: { identity in
                reads += 1
                if reads > 1 {
                    await identity("New identity")
                    await withCheckedContinuation { continuation = $0 }
                    await identity("Obsolete identity")
                }
                return .init(configuration: good, isComplete: true, initialSignature: "same")
            })
        await refresh.refresh()
        let pending = Task { await refresh.refresh(force: true) }
        while continuation == nil { await Task.yield() }
        #expect(refresh.configuration?.agentName == "New identity")
        #expect(refresh.configuration?.skills == good.skills)
        #expect(refresh.configuration?.mcpServers == good.mcpServers)
        refresh.cancel()
        continuation?.resume()
        await pending.value
        #expect(refresh.configuration?.agentName == "New identity")
        #expect(!refresh.isLoading)
        #expect(refresh.error != nil)
    }

    @Test func unavailableFirstLoadRetriesImmediately() async {
        var reads = 0
        let unavailable = HermesRuntimeInspector.inspect(runner: { _ in nil }, identityReader: { _ in nil })
        let good = configuration()
        let refresh = HermesRuntimeConfigurationRefresh(
            scope: { "local" }, metadata: { _ in "same" },
            reader: { _ in
                reads += 1
                return reads == 1 ? unavailable : .init(configuration: good, isComplete: true, initialSignature: "same")
            })
        await refresh.refresh()
        #expect(refresh.error != nil)
        #expect(refresh.configuration?.agentName == nil)
        await refresh.refresh()
        #expect(reads == 2)
        #expect(refresh.configuration == good)
        #expect(refresh.error == nil)
    }

    @Test func scopeChangeDuringInspectionRejectsOldIdentityAndSnapshot() async {
        var scope = "old"
        var continuation: CheckedContinuation<Void, Never>?
        var reads = 0
        let good = configuration("New")
        let old = configuration("Old")
        let refresh = HermesRuntimeConfigurationRefresh(
            scope: { scope }, metadata: { _ in "same" },
            reader: { identity in
                reads += 1
                let first = reads == 1
                if first { await withCheckedContinuation { continuation = $0 } }
                await identity(first ? "Old" : "New")
                return .init(configuration: first ? old : good, isComplete: true, initialSignature: "same")
            })
        let pending = Task { await refresh.refresh() }
        while continuation == nil { await Task.yield() }
        scope = "new"
        continuation?.resume()
        await pending.value
        #expect(reads == 2)
        #expect(refresh.configuration == good)
    }

    @Test func metadataTracksEditReplacementDeletionAndSoul() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("config.yaml")
        let soul = root.appendingPathComponent("SOUL.md")
        try Data("first".utf8).write(to: config)
        let original = await HermesRuntimeConfigurationRefresh.fileSignature(config.path)
        try Data("longer edit".utf8).write(to: config)
        let edited = await HermesRuntimeConfigurationRefresh.fileSignature(config.path)
        #expect(original != edited)
        try Data("# Fixture".utf8).write(to: soul)
        let identity = await HermesRuntimeConfigurationRefresh.fileSignature(config.path)
        #expect(edited != identity)
        try FileManager.default.removeItem(at: config)
        let missing = await HermesRuntimeConfigurationRefresh.fileSignature(config.path)
        #expect(identity != missing)
        try Data("replacement".utf8).write(to: config)
        #expect(await HermesRuntimeConfigurationRefresh.fileSignature(config.path) != missing)
    }
}
