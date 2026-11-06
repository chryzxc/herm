import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Herm

@MainActor
private final class ModelSwitchNoticeRPC: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    var onFetch: (() -> Void)?
    var rejectsSwitch = false
    var paths: [String] = []
    var rows: [[String: Any]] = []

    func connect() async throws {}
    func close() {}
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        if method == "config.set" {
            if rejectsSwitch { throw NSError(domain: "fixture", code: 1) }
            return ["key": "model", "value": "chosen", "scope": "session"]
        }
        return [:]
    }
    func fetchHTTP(_ path: String) async throws -> [String: Any] {
        paths.append(path)
        onFetch?()
        return ["messages": rows]
    }
}

@MainActor
struct ModelSwitchNoticeTests {
    private let marker =
        "[System: The active model for this chat has changed to chosen via provider example. From this point forward, use this runtime metadata when answering questions about what model/provider is active.]"

    private func makeModel(_ rpc: ModelSwitchNoticeRPC) -> DockModel {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return DockModel(
            sessionAgentStateFileURL: root.appendingPathComponent("agents.json"),
            defaults: UserDefaults(suiteName: UUID().uuidString)!,
            initialSessionID: "owner", botActivityFileURL: root.appendingPathComponent("bots.json"), rpcClient: rpc)
    }

    private func row() -> [String: Any] {
        ["id": 42, "role": "user", "content": marker, "display_kind": "model_switch", "timestamp": 1000]
    }

    @Test func noticeWrapsAtNarrowWidths() throws {
        _ = NSApplication.shared
        for scheme in [ColorScheme.light, .dark] {
            var heights: [CGFloat] = []
            for width: CGFloat in [280, 680] {
                let host = NSHostingView(
                    rootView: SystemEventCard(
                        event: SystemEvent(label: "Model switch", isModelSwitch: true),
                        text: marker, timeLabel: "10:24"
                    )
                    .frame(width: width)
                    .dockThemedRoot()
                    .preferredColorScheme(scheme))
                let size = host.fittingSize
                #expect(size.width <= width)
                #expect(size.height > 0 && size.height.isFinite)
                heights.append(size.height)
                host.frame = CGRect(origin: .zero, size: size)
                host.layoutSubtreeIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let data = try #require(bitmap.representation(using: .png, properties: [:]))
                try data.write(
                    to: FileManager.default.temporaryDirectory.appendingPathComponent(
                        "herm-model-switch-\(scheme)-\(Int(width)).png"))
            }
            #expect(heights[0] > heights[1])
        }
    }

    @Test func storedNoticeRestoresWithTheSamePresentation() throws {
        let restored = DockModel.parseMessages(TranscriptHistoryPaging.displayRows(fromStoredRows: [row()]))
        let message = try #require(restored.messages.first)
        #expect(message.systemEvent?.isModelSwitch == true)
        #expect(message.role == .hermes)
        #expect(message.timestamp == Date(timeIntervalSince1970: 1000))
        #expect(restored.rowIDs[42] == message.id)
        #expect(SystemEvent.modelSwitchSummary(message.text) == "Switched to chosen via provider example")
        #expect(SystemEvent.classify(role: "user", text: marker, displayKind: nil)?.isModelSwitch == true)
        #expect(SystemEvent.modelSwitchSummary("Future marker format") == "Future marker format")
    }

    @Test func confirmedSwitchLoadsDurableNoticeAndDeduplicatesPaging() async throws {
        let rpc = ModelSwitchNoticeRPC()
        rpc.rows = [row()]
        let model = makeModel(rpc)
        model.sessionStorageID = "stored-owner"
        model.sessionProfileID = "profile"
        model.transcriptHistoryCursor = TranscriptHistoryCursor(storageSessionID: "stored-owner", profileID: "profile")
        model.updateSessionModel(HermesModelOption(provider: "example", model: "chosen"))
        for _ in 0..<500 {
            if !model.isUpdatingSessionModel { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!model.isUpdatingSessionModel)
        let message = try #require(model.messages.first)
        #expect(message.systemEvent?.isModelSwitch == true)
        #expect(model.storedMessageReferences[message.id]?.rowID == 42)
        #expect(rpc.paths.first?.contains("stored-owner/messages") == true)
        #expect(rpc.paths.first?.contains("profile=profile") == true)
        await model.refreshModelSwitchNotice(
            sessionID: "owner", generation: model.sessionResumeGeneration, profile: "profile")
        #expect(model.messages.count == 1)
        var cursor = try #require(model.transcriptHistoryCursor)
        let page = try #require(TranscriptHistoryPaging.page(from: ["messages": rpc.rows]))
        #expect(TranscriptHistoryPaging.advance(&cursor, with: page, limit: 120).isEmpty)
    }

    @Test func sessionSwitchDuringReadCannotInsertIntoAnotherChat() async {
        let rpc = ModelSwitchNoticeRPC()
        rpc.rows = [row()]
        let model = makeModel(rpc)
        model.sessionStorageID = "stored-owner"
        rpc.onFetch = {
            model.sessionResumeGeneration += 1
            model.sessionID = "other"
        }
        await model.refreshModelSwitchNotice(
            sessionID: "owner", generation: model.sessionResumeGeneration, profile: nil)
        #expect(model.messages.isEmpty)
    }

    @Test func rejectedSwitchDoesNotCreateANotice() async throws {
        let rpc = ModelSwitchNoticeRPC()
        rpc.rejectsSwitch = true
        let model = makeModel(rpc)
        model.sessionStorageID = "stored-owner"
        model.updateSessionModel(HermesModelOption(provider: "example", model: "chosen"))
        for _ in 0..<500 {
            if !model.isUpdatingSessionModel { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.messages.isEmpty)
        #expect(rpc.paths.isEmpty)
        #expect(model.runtimeConfigurationError != nil)
    }
}
