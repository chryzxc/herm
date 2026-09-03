import Foundation
import Testing
@testable import HermesAgentDock

struct HermesFeatureContractTests {
    @Test func featureIDsAreUniqueAndResolveThroughTheAuthoritativeRegistry() {
        #expect(Set(HermesFeatureIDs.all).count == HermesFeatureIDs.all.count)
        #expect(HermesFeatureIDs.lookup("gateway") == .gateway)
        #expect(HermesFeatureIDs.lookup("kanban.taskDetails") == .kanbanTaskDetails)
        #expect(HermesFeatureIDs.lookup("missing-feature") == nil)
    }

    @Test func featureIDLookupUsesTheSameIdentityAcrossCapabilityAndTransportSurfaces() {
        let capabilityIDs = HermesFeatureIDs.capabilityIDs
        let transportIDs = HermesFeatureIDs.transportIDs

        #expect(capabilityIDs.allSatisfy { HermesFeatureIDs.lookup($0) != nil })
        #expect(transportIDs.allSatisfy { HermesFeatureIDs.lookup($0) != nil })
        #expect(Set(capabilityIDs).isSubset(of: HermesFeatureIDs.all))
        #expect(Set(transportIDs).isSubset(of: HermesFeatureIDs.all))
    }

    @Test func everySupportedTransportMethodIsExplicitlyRegistered() throws {
        let expectedMethods = [
            "session.list", "session.active_list", "session.activate", "session.resume", "session.delete",
            "session.interrupt", "session.usage", "session.context_breakdown", "project.facts", "verification.status",
            "prompt.background", "session.title", "session.steer", "session.branch", "session.compress", "session.undo",
            "session.redirect", "delegation.pause", "subagent.interrupt", "process.kill", "approval.respond", "clarify.respond",
            "delegation.status", "cron.manage", "reload.mcp", "process.list", "tools.list", "plugins.list", "config.show",
            "projects.tree", "projects.project_sessions", "shell.exec", "image.attach_bytes", "session.create", "prompt.submit", "voice.toggle",
            "voice.record", "config.get", "config.set", "model.options",
            "profiles.list", "profiles.describe", "profiles.create", "profiles.configure",
            "profiles.set_asset", "profiles.get_asset", "image.generate"
        ]
        #expect(Set(HermesFeatureIDs.transportIDs) == Set(expectedMethods))

        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/HermesAgentDock/HermesRuntime/HermesControlTransport.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        #expect(!source.contains("client.request(\""), "transport methods must route through HermesFeatureIDs")
    }

    @Test func productionRPCCallersUseTheAuthoritativeFeatureRegistry() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/HermesAgentDock")
        let enumerator = FileManager.default.enumerator(at: sourceRoot, includingPropertiesForKeys: nil)
        let swiftFiles = (enumerator?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
        let directMethodPattern = try NSRegularExpression(pattern: #"(?:gateway|client|sessionRPCClient)\.request\(\s*\"[^\"]+\""#)
        let violations = swiftFiles.flatMap { url -> [String] in
            guard let source = try? String(contentsOf: url, encoding: .utf8) else { return [] }
            let range = NSRange(source.startIndex..<source.endIndex, in: source)
            return directMethodPattern.matches(in: source, range: range).map {
                "\(url.lastPathComponent):\(source.distance(from: source.startIndex, to: source.index(source.startIndex, offsetBy: $0.range.location)))"
            }
        }
        #expect(violations.isEmpty, "Production RPC methods must route through HermesFeatureIDs: \(violations)")
    }
}
