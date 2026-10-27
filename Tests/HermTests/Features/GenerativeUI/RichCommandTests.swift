import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Herm

@MainActor
@Suite(.serialized)
struct RichCommandTests {
    @Test func commandsRejectHiddenInputAndKeepExactShellText() throws {
        for text in [
            "", "   ", "pwd\nwhoami", "pwd\r", "echo\tvalue", "pwd\u{0}", "pwd\u{1b}[A", "echo \u{202e}hidden",
            String(repeating: "x", count: 513),
        ] {
            #expect(!RichCommand(command: text).validate())
        }
        let command = RichCommand(command: "printf '%s' 'hello world' && pwd")
        #expect(command.validate())
        #expect(try JSONDecoder().decode(RichCommand.self, from: JSONEncoder().encode(command)) == command)
        let invalid =
            #"{"version":2,"id":"a","title":"Run","fallback":"Copy the command","kind":"native","blocks":[{"type":"command","id":"c","payload":{"command":"pwd\nwhoami"}}]}"#
        #expect(
            RichDocument("```herm-ui\n" + invalid + "\n```").segments == [
                .unavailable("Copy the command", source: invalid)
            ])
    }

    @Test func actionsRequireCurrentSourceAndMatchingDestination() throws {
        let previousTheme = DockThemeRuntime.current
        let previousRevision = DockThemeRuntime.revision
        DockThemeRuntime.current = .slate
        DockThemeRuntime.revision &+= 1
        defer {
            DockThemeRuntime.current = previousTheme
            DockThemeRuntime.revision = previousRevision
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let setting = GenerativeUIIntegration.preferenceKey
        let old = UserDefaults.standard.object(forKey: setting)
        UserDefaults.standard.set(true, forKey: setting)
        let model = DockModel(
            sessionAgentStateFileURL: root.appendingPathComponent("agents.json"),
            defaults: defaults, initialSessionID: "owner", botActivityFileURL: root.appendingPathComponent("bots.json"))
        defer {
            model.shutdown()
            defaults.removePersistentDomain(forName: suite)
            if let old {
                UserDefaults.standard.set(old, forKey: setting)
            } else {
                UserDefaults.standard.removeObject(forKey: setting)
            }
            try? FileManager.default.removeItem(at: root)
        }
        let message = ChatMessage(role: .hermes, text: "Original command")
        model.messages = [message]
        let context = RichReplyContext(model: model, message: message, state: RichReplyState())
        var received: [String] = []
        let terminal = RichHostActionRouter.TerminalAction(directory: "/tmp") { received.append($0) }
        let router = RichHostActionRouter(
            scope: .init(profileID: context.destination.profileID, resourceID: "owner"), terminal: terminal,
            features: [])
        let command = RichCommand(command: "bun run db:migrate")
        #expect(received.isEmpty)
        let surface = RichSurface(
            version: 2, id: "setup", title: "Drizzle setup", fallback: "Run the migration.",
            kind: .native, blocks: [.init(type: .command, id: "migrate", payload: .command(command))])
        let source = String(decoding: try JSONEncoder().encode(surface), as: UTF8.self)
        for width: CGFloat in [320, 800] {
            let host = NSHostingView(
                rootView: RichSurfaceView(surface: surface, source: source)
                    .environment(\.richReplyContext, context).environment(\.richHostActionRouter, router)
                    .padding(16).frame(width: width).background(Color.dockCanvas).dockThemedRoot())
            host.frame = NSRect(x: 0, y: 0, width: width, height: 220)
            host.layoutSubtreeIfNeeded()
            #expect(host.fittingSize.width <= width + 1)
            #expect(host.fittingSize.height > 0)
            if let directory = ProcessInfo.processInfo.environment["HERM_WORKFLOW_REVIEW_DIR"] {
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                host.frame.size.height = max(180, host.fittingSize.height)
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                try png.write(
                    to: URL(fileURLWithPath: directory).appendingPathComponent("command-enabled-\(Int(width)).png"))
            }
        }
        #expect(!router.canRunCommand(context: nil))
        let other = RichHostActionRouter(
            scope: .init(profileID: "other", resourceID: "owner"), terminal: terminal, features: [])
        #expect(!other.canRunCommand(context: context))
        #expect(throws: (any Error).self) { try other.run(command, context: context) }
        #expect(throws: (any Error).self) { try router.run(.init(command: "pwd\n"), context: context) }
        try router.run(command, context: context)
        #expect(received == [command.command])
        #expect(router.generationContext().terminalDirectory == "/tmp")
        #expect(
            router.contextProvider()(.init(profileID: nil, sessionID: "different", title: "Other")).terminalDirectory
                == nil)
        UserDefaults.standard.set(false, forKey: setting)
        #expect(throws: (any Error).self) { try router.run(command, context: context) }
        UserDefaults.standard.set(true, forKey: setting)
        model.messages = [ChatMessage(id: message.id, role: .hermes, text: "Changed")]
        #expect(throws: (any Error).self) { try router.run(command, context: context) }
        #expect(received == [command.command])
    }

    @Test func commandsUseFreshShellsInTheChosenDirectory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let tabs = TerminalTabStore()
        defer {
            tabs.closeAll()
            try? FileManager.default.removeItem(at: directory)
        }
        let first = tabs.selected
        try tabs.runInNewShell("printf first > first.txt", directory: directory.path)
        #expect(tabs.sessions.count == 1)
        #expect(tabs.selected === first)
        try tabs.runInNewShell("printf second > second.txt", directory: directory.path)
        #expect(tabs.sessions.count == 2)
        #expect(tabs.selected !== first)
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("second.txt").path),
                FileManager.default.fileExists(atPath: directory.appendingPathComponent("first.txt").path)
            {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(try String(contentsOf: directory.appendingPathComponent("first.txt"), encoding: .utf8) == "first")
        #expect(try String(contentsOf: directory.appendingPathComponent("second.txt"), encoding: .utf8) == "second")
        #expect(tabs.sessions.allSatisfy { $0.lastVerificationRun == nil })
        let selected = tabs.selected.id
        #expect(throws: (any Error).self) {
            try tabs.runInNewShell("pwd", directory: directory.appendingPathComponent("missing").path)
        }
        #expect(tabs.sessions.count == 2)
        #expect(tabs.selected.id == selected)
    }
}
