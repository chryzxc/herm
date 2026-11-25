import Foundation
import Testing

@testable import Herm

@MainActor
struct VoiceHomeBotTests {
    @Test(arguments: [true, false])
    func reopensTheSameMainChatAcrossNotchProjections(rosterAvailable: Bool) async throws {
        let rpc = VoiceHomeChatRPC()
        if rosterAvailable {
            rpc.profiles = [
                ["id": "another", "chat": ["session_id": "other-chat"]],
                ["id": "default", "is_default": true, "chat": ["resolved_id": "main-tip"]],
            ]
        }
        let workspace = makeWorkspace(rpc)
        defer { workspace.shutdown() }
        workspace.draft = "Keep this draft"

        for _ in 0..<2 {
            let projection = EdgeQuickConversationModel()
            let notch = projection.prepareVoice(runtime: workspace)
            defer { projection.shutdown() }
            #expect(await notch.resumeVoiceHomeChat(generation: notch.voiceConversationGeneration))
            #expect(notch.sessionID == "runtime-main-tip")
            #expect(notch.sessionStorageID == "main-tip")
            #expect(notch.sessionProfileID == "default")
            #expect(notch.messages.first?.text == "Earlier request")
            notch.stopVoiceConversation()
            #expect(await notch.resumeVoiceHomeChat(generation: notch.voiceConversationGeneration))
        }

        #expect(rpc.resumes.map(\.id) == ["main-tip", "main-tip"])
        #expect(rpc.resumes.map(\.profile) == ["default", "default"])
        #expect(rpc.lookups.count == (rosterAvailable ? 0 : 4))
        #expect(rpc.lookups.allSatisfy { $0.title == "Bot Chat" && $0.profile == "default" })
        #expect(!rpc.methods.contains("session.create"))
        #expect(workspace.sessionID == "workspace")
        #expect(workspace.draft == "Keep this draft")
    }

    @Test func missingMainChatKeepsTheAssistantLocal() async {
        let rpc = VoiceHomeChatRPC()
        rpc.lookupRows = [["id": "ordinary-session", "title": "An unrelated chat"]]
        let workspace = makeWorkspace(rpc)
        let projection = EdgeQuickConversationModel()
        let notch = projection.prepareVoice(runtime: workspace)
        defer {
            projection.shutdown()
            workspace.shutdown()
        }
        notch.isVoiceMicMuted = true
        notch.voiceAssistant.isLocal = true
        notch.voiceState = .listening
        notch.voiceRepliesEnabled = false
        #expect(notch.receiveAssistantRequest("Explain the latest changes."))
        await notch.voiceAssistant.task?.value
        #expect(notch.voiceSpokenCaption == VoiceAssistantSession.mainChatUnavailable)
        #expect(notch.voiceAssistant.isLocal)
        #expect(notch.sessionID == nil)
        #expect(!notch.newSessionCreationAuthorized)
        #expect(rpc.resumes.isEmpty)
        #expect(!rpc.methods.contains("session.create"))
        #expect(!rpc.methods.contains("prompt.submit"))
    }

    @Test func aFailedMainChatResumeCanBeRetried() async {
        let rpc = VoiceHomeChatRPC()
        rpc.profiles = [["id": "default", "is_default": true, "chat": ["session_id": "main-tip"]]]
        let workspace = makeWorkspace(rpc)
        let projection = EdgeQuickConversationModel()
        let notch = projection.prepareVoice(runtime: workspace)
        defer {
            projection.shutdown()
            workspace.shutdown()
        }
        rpc.refuseResume = true
        #expect(!(await notch.resumeVoiceHomeChat(generation: notch.voiceConversationGeneration)))
        #expect(!notch.sessionActionsReady)
        rpc.refuseResume = false
        #expect(await notch.resumeVoiceHomeChat(generation: notch.voiceConversationGeneration))
        #expect(rpc.resumes.map(\.id) == ["main-tip", "main-tip"])
        #expect(!rpc.methods.contains("session.create"))
    }

    private func makeWorkspace(_ rpc: VoiceHomeChatRPC) -> DockModel {
        let workspace = DockModel(
            defaults: UserDefaults(suiteName: UUID().uuidString)!,
            initialSessionID: "workspace", loadArchives: false, rpcClient: rpc)
        workspace.isHermesConnected = true
        return workspace
    }
}

@MainActor
private final class VoiceHomeChatRPC: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    var profiles: [[String: Any]]?
    var lookupRows: [[String: Any]] = [
        ["id": "main-root", "resolved_id": "main-tip", "root_title": "Bot Chat", "title": ""]
    ]
    var refuseResume = false
    var methods: [String] = []
    var resumes: [(id: String?, profile: String?)] = []
    var lookups: [(title: String?, profile: String?)] = []

    func connect() async throws {}
    func close() {}

    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        methods.append(method)
        switch method {
        case "profiles.list":
            guard let profiles else { throw HermesGateway.GatewayError.httpError(503) }
            return ["profiles": profiles]
        case "session.list":
            lookups.append((params["title"] as? String, params["profile"] as? String))
            return ["sessions": lookupRows]
        case "session.resume":
            let id = params["session_id"] as? String
            resumes.append((id, params["profile"] as? String))
            guard !refuseResume, let id else { throw HermesGateway.GatewayError.httpError(404) }
            return [
                "session_id": "runtime-" + id,
                "session_key": id,
                "messages": [["role": "user", "text": "Earlier request"]],
            ]
        default:
            return [:]
        }
    }
}

@MainActor
struct EdgeVoiceIslandHeightTests {
    @Test func panelHeightRoundsUpSoSmallChangesNeverResize() {
        #expect(EdgeVoiceIsland.paddedHeight(81) == 120)
        #expect(EdgeVoiceIsland.paddedHeight(100) == 120)
        #expect(EdgeVoiceIsland.paddedHeight(120) == 120)
    }
}
