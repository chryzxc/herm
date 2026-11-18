import Foundation
import Testing

@testable import Herm

struct DesktopPluginBridgeTests {
    @Test func parsesRequestsAndRejectsUnknownOps() throws {
        let message = try DesktopPluginMessage.parse(
            #"{"id":3,"op":"request","args":{"method":"session.history","params":{"session_id":"s1"},"profile":"work"}}"#
        )
        #expect(message.id == 3)
        guard case .request(let method, let params, let profile) = message.op else {
            Issue.record("expected request")
            return
        }
        #expect(method == "session.history")
        #expect(params["session_id"] as? String == "s1")
        #expect(profile == "work")

        #expect(throws: DesktopPluginBridgeError.unsupported("socket")) {
            try DesktopPluginMessage.parse(#"{"id":1,"op":"socket","args":{}}"#)
        }
        #expect(throws: DesktopPluginBridgeError.malformed) { try DesktopPluginMessage.parse("not json") }
        #expect(throws: DesktopPluginBridgeError.malformed) {
            try DesktopPluginMessage.parse(#"{"id":1,"op":"rest","args":{"path":"/x","method":"TRACE"}}"#)
        }
    }

    @Test func restStaysInsideThePluginNamespace() throws {
        #expect(try DesktopPluginMessage.restSuffix("inbox") == "/inbox")
        #expect(try DesktopPluginMessage.restSuffix("/boards/b1?x=..") == "/boards/b1?x=..")
        #expect(throws: DesktopPluginBridgeError.illegalPath("/../config")) {
            try DesktopPluginMessage.restSuffix("/../config")
        }
        #expect(throws: DesktopPluginBridgeError.illegalPath("/%2E%2E/config")) {
            try DesktopPluginMessage.restSuffix("/%2E%2E/config")
        }
        #expect(
            DesktopPluginMessage.restPath(pluginID: "whiteboard", suffix: "/inbox") == "/api/plugins/whiteboard/inbox")
        #expect(DesktopPluginMessage.restPath(pluginID: "a/b", suffix: "/x") == "/api/plugins/a%2Fb/x")
    }

    @Test func statusAndSavePathMessagesDecode() throws {
        guard case .ready = try DesktopPluginMessage.parse(#"{"id":0,"op":"status","args":{"state":"ready"}}"#).op
        else {
            Issue.record("expected ready")
            return
        }
        let save = try DesktopPluginMessage.parse(
            #"{"id":2,"op":"pickSavePath","args":{"defaultPath":"board.md","filters":[{"extensions":["md"]}]}}"#)
        guard case .pickSavePath(let path, _, let extensions) = save.op else {
            Issue.record("expected save")
            return
        }
        #expect(path == "board.md")
        #expect(extensions == ["md"])
    }

    @Test func schemeServesOnlyHostAndPluginFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let hostRoot = root.appendingPathComponent("host")
        let pluginRoot = root.appendingPathComponent("plugin")
        try FileManager.default.createDirectory(at: hostRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: pluginRoot, withIntermediateDirectories: true)
        for file in [hostRoot.appendingPathComponent("host.html"), pluginRoot.appendingPathComponent("plugin.js")]
            + [hostRoot.appendingPathComponent("vendor/react.js")]
        {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: file)
        }
        try FileManager.default.createSymbolicLink(
            at: pluginRoot.appendingPathComponent("escape"), withDestinationURL: root)
        func resolve(_ path: String) -> String? {
            DesktopPluginFiles.resolve(
                URL(string: "herm-plugin://board\(path)")!, hostRoot: hostRoot, pluginRoot: pluginRoot
            )?.lastPathComponent
        }
        #expect(resolve("/") == "host.html")
        #expect(resolve("/vendor/react.js") == "react.js")
        #expect(resolve("/plugin/plugin.js") == "plugin.js")
        #expect(resolve("/plugin/../host/host.html") == nil)
        #expect(resolve("/../plugin/plugin.js") == nil)
        #expect(resolve("/plugin/escape/host/host.html") == nil)
        #expect(resolve("/plugin/") == nil)
        #expect(DesktopPluginFiles.mimeType(URL(fileURLWithPath: "/a/plugin.js")) == "text/javascript")
    }

    @Test func eachPluginIDGetsItsOwnOrigin() {
        #expect(DesktopPluginFiles.origin(for: "hermes-whiteboard") == "hermes-whiteboard")
        let spelled = ["my_plugin", "myplugin", "MyPlugin", "my.plugin", "___"].map(DesktopPluginFiles.origin(for:))
        #expect(Set(spelled).count == spelled.count)
        #expect(DesktopPluginFiles.origin(for: "my_plugin") == "x.6d795f706c7567696e")
        #expect(spelled.allSatisfy { URL(string: "herm-plugin://\($0)/host.html")?.host == $0 })
    }
}
