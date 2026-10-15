import Foundation
import Testing
@testable import Herm

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
            "pet.info", "pet.info.meta", "pet.gallery", "pet.thumb", "pet.select", "pet.disable", "pet.scale",
            "session.list", "session.active_list", "session.activate", "session.resume", "session.delete",
            "session.interrupt", "session.messages", "session.usage", "session.context_breakdown", "session.close", "session.set_hidden", "session.events.since", "project.facts", "verification.status",
            "prompt.background", "bot_relay.deliver", "groups.capabilities", "groups.list", "groups.create", "groups.state", "groups.send", "groups.log", "groups.rename", "groups.stop", "groups.disband", "groups.approve", "groups.retry", "groups.peer.invite", "groups.peer.register", "session.title", "session.steer", "session.branch", "session.compress", "session.undo",
            "session.redirect", "delegation.pause", "subagent.interrupt", "process.kill", "approval.respond", "approval.pending", "request.answer", "clarify.lock",
            "delegation.status", "cron.manage", "reload.mcp", "process.list", "tools.list", "plugins.list", "config.show",
            "projects.tree", "projects.project_sessions", "projects.create", "projects.archive", "projects.delete", "projects.set_active", "projects.add_folder", "shell.exec", "image.attach_bytes", "image.detach", "pdf.attach", "file.attach", "session.create", "prompt.submit", "voice.toggle",
            "complete.slash", "complete.path", "commands.catalog", "slash.exec", "command.dispatch", "prompt.btw",
            "voice.record", "voice.tts", "config.get", "config.set", "model.options",
            "profiles.list", "profiles.describe", "profiles.create", "profiles.configure",
            "profiles.set_asset", "profiles.get_asset", "image.generate", "insights.get", "rollback.list", "rollback.diff", "rollback.restore", "gateway.capabilities",
            "skills.manage", "mcp.catalog", "mcp.servers.list", "mcp.servers.add", "mcp.servers.set_api_key", "mcp.servers.test", "mcp.servers.remove", "mcp.servers.oauth.start", "mcp.servers.oauth.poll", "mcp.servers.oauth.cancel", "subagent.list", "subagent.steer", "learning.detail", "learning.edit", "learning.delete", "browser.manage"
        ]
        #expect(Set(HermesFeatureIDs.transportIDs) == Set(expectedMethods))

        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Herm/HermesRuntime/HermesControlTransport.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        #expect(!source.contains("client.request(\""), "transport methods must route through HermesFeatureIDs")
    }

    @Test func productionRPCCallersUseTheAuthoritativeFeatureRegistry() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Herm")
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
