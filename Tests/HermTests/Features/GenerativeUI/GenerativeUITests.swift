import AppKit
import SwiftUI
import Testing

@testable import Herm

@MainActor
private final class RichFormRPC: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    var acknowledgment = "streaming"
    var prompts = 0
    func connect() async throws {}
    func close() {}
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        if method == "session.resume" {
            return ["session_id": params["session_id"] ?? "owner", "running": false]
        }
        if method == "prompt.submit" {
            prompts += 1
            return ["status": acknowledgment]
        }
        return [:]
    }
}

@MainActor
struct GenerativeUITests {
    static let monthlySalesSource = """
        {
          "version": 1,
          "id": "fictional-monthly-sales-dashboard",
          "title": "Monthly Sales — Fictional Data",
          "fallback": "Fictional monthly sales: January 12, February 18, March 15, and April 24.",
          "kind": "native",
          "blocks": [
            {
              "type": "text",
              "text": "Illustrative figures only — this is fictional data, not actual sales."
            },
            {
              "type": "table",
              "columns": ["Month", "Fictional sales"],
              "rows": [
                ["January", 12],
                ["February", 18],
                ["March", 15],
                ["April", 24]
              ]
            },
            {
              "type": "chart",
              "style": "bar",
              "points": [
                {"label": "January", "value": 12},
                {"label": "February", "value": 18},
                {"label": "March", "value": 15},
                {"label": "April", "value": 24}
              ]
            }
          ]
        }
        """

    private var surface: RichSurface {
        RichSurface(
            version: 1, id: "results", title: "Build results", fallback: "Two checks passed.",
            kind: .native,
            blocks: [
                RichBlock(
                    type: .table, columns: ["Check", "Result"],
                    rows: [["Build", "Passed"], ["Tests", "Passed"]]),
                RichBlock(
                    type: .chart, style: "bar",
                    points: [RichPoint(label: "Before", value: 8), RichPoint(label: "After", value: 3)]),
            ])
    }
    private func fenced(_ value: RichSurface) throws -> String {
        "```herm-ui\n" + String(decoding: try JSONEncoder().encode(value), as: UTF8.self) + "\n```"
    }
    @Test func completeSurfacesValidateAndProjectEverywhere() throws {
        let text = try fenced(surface)
        let doc = RichDocument(text)
        #expect(doc.hasSurfaces)
        #expect(doc.plainText.contains("Build | Passed"))
        #expect(!doc.plainText.contains("```herm-ui"))
        #expect(GenerativeUIIntegration.readableText(ChatMessage(role: .hermes, text: text)) == doc.plainText)
        #expect(GenerativeUIIntegration.readableText(ChatMessage(role: .user, text: text)) == text)
        #expect(RichDocument(text, streaming: true).segments == [.pending])
        #expect(RichDocument("````swift\n" + text + "\n````").plainText.contains("```herm-ui"))
        #expect(RichPromptContext.display(RichPromptContext.prepare("Hello")) == "Hello")
        #expect(
            RichPromptContext.prepare(RichPromptContext.prepare("Hello"))
                == RichPromptContext.prepare("Hello"))
    }
    @Test func malformedOversizedAndStaleSchemasFallBack() throws {
        #expect(RichDocument("```herm-ui\n{", streaming: true).segments == [.pending])
        #expect(
            RichDocument("```herm-ui\n{\"fallback\":\"Readable result\",\"version\":9}\n```").plainText
                == "Readable result")
        #expect(
            RichDocument(
                "```herm-ui\n" + String(repeating: "x", count: RichDocument.maximumBytes + 1) + "\n```"
            ).plainText.contains("limit"))
        var huge = surface
        huge.blocks = Array(repeating: RichBlock(type: .text, text: "x"), count: 101)
        #expect(!huge.validate())
        #expect(!RichBlock(type: .table, columns: ["A"], rows: [["A", "B"]]).validate())
        let repeated = RichDocument(try fenced(surface) + "\n" + fenced(surface))
        #expect(repeated.segments.filter { if case .surface = $0 { true } else { false } }.count == 1)
        #expect(RichResourcePolicy.url("https://127.0.0.1/private") == nil)
        #expect(RichResourcePolicy.url("file:///etc/passwd") == nil)
        #expect(RichResourcePolicy.url("https://a.localhost/private") == nil)
    }

    @Test func numericSalesDashboardRetainsTableAndChart() async throws {
        let source = Self.monthlySalesSource
        let text = "```herm-ui\n" + source + "\n```"
        let document = await RichDocumentCache.shared.document(text, identity: UUID().uuidString, streaming: false)
        let surface = try #require(
            document.segments.compactMap { segment -> RichSurface? in
                if case .surface(let surface, _) = segment { return surface }
                return nil
            }.first)
        #expect(surface.validate())
        #expect(surface.blocks?.map(\.type) == [.text, .table, .chart])
        #expect(
            surface.blocks?.first(where: { $0.type == .table })?.rows == [
                ["January", "12"], ["February", "18"], ["March", "15"], ["April", "24"],
            ])
        #expect(surface.blocks?.last?.points?.map(\.value) == [12, 18, 15, 24])
        #expect(document.segments == [.surface(surface, source: source)])
        #expect(document.plainText.contains("January | 12"))
        #expect(document.plainText.contains("Illustrative figures only — this is fictional data, not actual sales."))
        #expect(RichDocument(text, streaming: true).segments == [.pending])
    }

    @Test(arguments: ["{}", "[]", "true", "null"])
    func unsupportedTableCellsRemainUnavailable(_ cell: String) {
        let source = """
            {"version":1,"id":"sales","title":"Sales","fallback":"Readable result","kind":"native","blocks":[{"type":"table","columns":["Month","Sales"],"rows":[["January",\(cell)]]}]}
            """
        #expect(
            RichDocument("```herm-ui\n" + source + "\n```").segments
                == [.unavailable("Readable result", source: source)])
    }

    @Test func numericTableCellsPreserveValues() throws {
        let block = try JSONDecoder().decode(
            RichBlock.self,
            from: Data(
                #"{"type":"table","columns":["Integer","Decimal","Negative","Exponent","Text"],"rows":[[0,18.5,-24,1e3,"12.00"]]}"#
                    .utf8))
        #expect(block.validate())
        #expect(block.rows == [["0", "18.5", "-24", "1000", "12.00"]])
        #expect(try JSONDecoder().decode(RichBlock.self, from: JSONEncoder().encode(block)) == block)
    }

    @Test func formDraftsSurviveRemountingAndValidateAnswers() throws {
        let state = RichReplyState()
        let draft = state.form(key: "profile/session/message/surface")
        draft.values["count"] = ["three"]
        let fields = [RichField(id: "count", label: "Count", type: .number, required: true)]
        #expect(throws: (any Error).self) { try draft.answer(fields: fields) }
        draft.values["count"] = ["3"]
        #expect(
            try state.form(key: "profile/session/message/surface").answer(fields: fields) == "Count: 3")
        #expect(state.form(key: "other/session/message/surface") !== draft)
    }
    @Test func receiptsPreserveDraftIdentity() {
        let state = RichReplyState()
        let message = ChatMessage(role: .hermes, text: "Original")
        let temporary = state.sourceKey(session: "p/s", message: message, reference: nil)
        let receipt = StoredMessageReference(rowID: 8, uid: nil)
        #expect(state.sourceKey(session: "p/s", message: message, reference: receipt) == temporary)
        let restored = ChatMessage(role: .hermes, text: "Original")
        #expect(state.sourceKey(session: "p/s", message: restored, reference: receipt) == temporary)
        #expect(state.sourceKey(session: "other/s", message: restored, reference: receipt) != temporary)
    }

    @Test func formSubmissionsPreserveComposerAndBlockUncertainRetries() async throws {
        for uncertain in [false, true] {
            let rpc = RichFormRPC()
            rpc.acknowledgment = uncertain ? "queued" : "streaming"
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let model = DockModel(
                sessionAgentStateFileURL: root.appendingPathComponent("agents.json"),
                defaults: UserDefaults(suiteName: UUID().uuidString)!, initialSessionID: "owner",
                botActivityFileURL: root.appendingPathComponent("bots.json"), rpcClient: rpc)
            model.status = .idle
            let message = ChatMessage(role: .hermes, text: try fenced(surface))
            model.messages = [message]
            model.draft = "Unfinished workspace request"
            let context = RichReplyContext(model: model, message: message, state: RichReplyState())
            #expect(context.isCurrent)
            let store = QuickDraftStore(directory: root.appendingPathComponent("drafts"))
            let draft = RichFormDraft()
            draft.values["answer"] = ["Yes"]
            let fields = [RichField(id: "answer", label: "Answer", type: .text)]
            await context.submit(draft, surface: surface, fields: fields, store: store)
            #expect(rpc.prompts == 1)
            #expect(model.draft == "Unfinished workspace request")
            #expect(draft.sent == !uncertain)
            #expect(uncertain ? draft.submission?.delivery == .needsReview : store.records.isEmpty)
            await context.submit(draft, surface: surface, fields: fields, store: store)
            #expect(rpc.prompts == 1)
            model.messages = [ChatMessage(id: message.id, role: .hermes, text: "Changed")]
            #expect(!context.isCurrent)
            model.shutdown()
            try? FileManager.default.removeItem(at: root)
        }
    }

    @Test func renderThemes() async throws {
        guard let directory = ProcessInfo.processInfo.environment["HERM_GENERATIVE_SNAPSHOT_DIR"] else {
            return
        }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let saved = DockThemeRuntime.current
        let revision = DockThemeRuntime.revision
        defer {
            DockThemeRuntime.current = saved
            DockThemeRuntime.revision = revision
        }
        let activity = [
            ActiveToolCall(
                id: "read", name: "read_file", input: "", context: "Package.swift", startedAt: .now, isComplete: true),
            ActiveToolCall(
                id: "test", name: "terminal", input: "", context: "swift test", startedAt: .now, isComplete: false),
        ]
        for (theme, dark): (DockThemeID, Bool) in [
            (.clean, false), (.clean, true), (.glass, false), (.glass, true), (.mono, false),
            (.mono, true), (.notebook, false), (.terminal, true),
        ] {
            DockThemeRuntime.current = theme
            DockThemeRuntime.revision &+= 1
            for width: CGFloat in [380, 760] {
                let root = ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Activity").font(.system(size: 16, weight: .semibold)).foregroundStyle(
                            Color.dockPrimaryText)
                        TurnActivityView(
                            activity: activity, runningSince: Date().addingTimeInterval(-12), duration: nil)
                        RichSurfaceView(surface: surface, source: try! fenced(surface))
                    }.padding(16)
                }.frame(width: width, height: 760).background(Color.dockCanvas)
                    .environment(\.colorScheme, dark ? .dark : .light).dockThemedRoot()
                let host = NSHostingView(rootView: root)
                host.frame = NSRect(x: 0, y: 0, width: width, height: 760)
                let window = NSWindow(
                    contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentView = host
                window.orderFrontRegardless()
                for _ in 0..<3 {
                    host.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(100))
                }
                let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: rep)
                let png = try #require(rep.representation(using: .png, properties: [:]))
                try png.write(
                    to: URL(fileURLWithPath: directory).appendingPathComponent(
                        "\(theme.rawValue)-\(dark ? "dark" : "light")-\(Int(width)).png"))
                window.orderOut(nil)
            }
        }
    }
}
