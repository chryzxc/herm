import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Herm

@MainActor
@Suite(.serialized)
struct GroupChatTests {
    @Test(arguments: ["groups.stop", "groups.rename", "groups.approve"])
    func failedRoomActionsKeepTheirErrorAndReleasePendingState(method: String) async throws {
        let client = RoomClient()
        client.failingMethod = method
        let store = GroupChatStore(defaults: freshDefaults())
        store.bind(to: client)
        switch method {
        case "groups.stop": await store.stop("r")
        case "groups.rename": await store.rename("r", to: "New name")
        default:
            let approval = try #require(
                GroupRoomApproval([
                    "kind": "approval", "member_id": "m", "task_id": "t", "request_id": "q",
                    "execution_generation": 1,
                ]))
            await store.respond(to: approval, in: "r", approve: true)
        }
        #expect(store.errorMessage?.contains("refused") == true)
        #expect(store.pendingRooms.isEmpty)
    }

    @Test func replyingMembersComeFromLiveDriverActivityInTheSelectedThread() throws {
        let activity = try #require(
            GroupMemberActivity.list(from: [
                "member_activity": [
                    ["member_id": "a", "status": "running", "thread_id": "main", "started_at": 1_700_000_000.0],
                    ["member_id": "b", "status": "queued", "thread_id": "main"],
                    ["member_id": "c", "status": "stopping"],
                    ["member_id": "d", "status": "running", "thread_id": "t-1"],
                    ["status": "running"],
                ]
            ]))
        #expect(activity.count == 4)
        // A stale turn.started row doesn't override the gateway's live view.
        let stale = [GroupRoomEvent(id: "1", seq: 1, kind: .started(memberID: "z"), text: "")]
        #expect(
            GroupReplying.memberIDs(activity: activity, events: stale, thread: "main", isWorking: true) == ["a", "c"])
        #expect(GroupReplying.memberIDs(activity: activity, events: [], thread: "t-1", isWorking: false) == ["d"])
        #expect(GroupReplying.memberIDs(activity: [], events: stale, thread: "main", isWorking: true).isEmpty)
    }

    @Test func pollingStaysFastBetweenChainedMemberTurns() {
        let now = Date(timeIntervalSince1970: 1_000)
        let idle = { (ago: TimeInterval?) in
            GroupChatStore.pollDelay(working: false, lastBusyAt: ago.map { now.addingTimeInterval(-$0) }, now: now)
        }
        #expect(GroupChatStore.pollDelay(working: true, lastBusyAt: nil, now: now) == .seconds(1))
        // The next member's task appears a beat after the previous reply settles.
        #expect(idle(2) == .seconds(1))
        #expect(idle(60) == .seconds(5))
        #expect(idle(nil) == .seconds(5))
    }

    @Test func olderGatewaysFallBackToOpenTurnStartedRows() {
        #expect(GroupMemberActivity.list(from: ["working": true]) == nil)
        let events = [
            GroupRoomEvent(id: "1", seq: 1, kind: .started(memberID: "a"), text: ""),
            GroupRoomEvent(id: "2", seq: 2, kind: .started(memberID: "b"), text: ""),
            GroupRoomEvent(id: "3", seq: 3, kind: .member(memberID: "a"), text: "hi"),
        ]
        #expect(GroupReplying.memberIDs(activity: nil, events: events, thread: "main", isWorking: true) == ["b"])
        #expect(GroupReplying.memberIDs(activity: nil, events: events, thread: "main", isWorking: false).isEmpty)
    }

    @Test func replyingLabelCollapsesLongStacks() {
        #expect(GroupReplying.label([]) == "")
        #expect(GroupReplying.label(["Ada"]) == "Ada is replying")
        #expect(GroupReplying.label(["Ada", "Bo", "Cy"]).hasSuffix("are replying"))
        #expect(GroupReplying.label(["Ada", "Bo", "Cy", "Di", "Ed"]) == "Ada, Bo and 3 others are replying")
    }

    @Test func mapsRoomLogEventsAndSkipsBookkeeping() {
        let rows: [[String: Any]] = [
            ["seq": 1, "event_id": "a", "kind": "room.created", "payload": [:]],
            [
                "seq": 2, "event_id": "b", "kind": "message.user",
                "payload": ["text": "@cypher hey", "thread_id": "main"],
            ],
            ["seq": 3, "event_id": "c", "kind": "turn.started", "payload": ["member_id": "cypher"]],
            ["seq": 4, "event_id": "d", "kind": "message.member", "payload": ["member_id": "cypher", "text": "hi"]],
            ["seq": 5, "event_id": "e", "kind": "turn.failed", "payload": ["member_id": "forge", "error": "boom"]],
            ["seq": 6, "event_id": "f", "kind": "turn.settled", "payload": ["member_id": "cypher"]],
        ]
        let events = rows.compactMap(GroupRoomEvent.init)
        #expect(
            events.map(\.kind) == [
                .user, .started(memberID: "cypher"), .member(memberID: "cypher"), .failed(memberID: "forge"),
            ])
        #expect(events[0].text == "@cypher hey")
        #expect(events[3].text == "boom")
    }

    @Test func dropsDisbandedRoomsAndDefaultsMemberLabels() {
        #expect(GroupRoom(["room_id": "r", "name": "x", "members": [], "disbanded_at": 1.0]) == nil)
        let room = GroupRoom([
            "room_id": "r", "name": "Audit",
            "members": [["member_id": "default", "profile": "default", "handle": "hermes"]],
        ])
        #expect(room?.member("default")?.displayName == "hermes")
    }

    @Test func pollPagesThroughTheLogAndResumesFromTheCursor() async {
        let client = RoomClient()
        let store = GroupChatStore(defaults: freshDefaults())
        store.bind(to: client)
        await store.poll("r")
        #expect(store.events["r"]?.map(\.seq) == [1, 2])
        #expect(client.sinceSeqs == [0, 0, 1])
        await store.poll("r")
        #expect(client.sinceSeqs.last == 2)
        #expect(store.events["r"]?.count == 2)
        #expect(store.workingRooms.contains("r"))
        #expect(store.approvals["r"]?.first?.summary == "rm -rf build")
        #expect(store.retries["r"]?.first?.taskID == "t9")
        #expect(store.blockedRooms.contains("r"))
    }

    @Test func malformedLogPageDoesNotCommitEarlierPages() async {
        let client = RoomClient()
        client.logOverrides[1] = ["events": "malformed", "cursor": 2, "has_more": false]
        let store = GroupChatStore(defaults: freshDefaults())
        store.bind(to: client)
        await store.poll("r")
        #expect(store.events["r", default: []].isEmpty)
        client.logOverrides = [:]
        await store.poll("r")
        #expect(store.events["r"]?.map(\.seq) == [1, 2])
    }

    @Test func overlappingPollsDoNotDuplicateEvents() async {
        let client = RoomClient()
        let (pause, release) = AsyncStream<Void>.makeStream()
        let (started, signal) = AsyncStream<Void>.makeStream()
        client.logPause = pause
        client.logStarted = signal
        let store = GroupChatStore(defaults: freshDefaults())
        store.bind(to: client)
        let old = Task { await store.poll("r") }
        for await _ in started { break }
        await store.poll("r")
        release.yield(())
        release.finish()
        await old.value
        #expect(store.events["r"]?.map(\.seq) == [1, 2])
    }

    @Test func retryUsesTheOfferedAttemptAndRejectsStaleActions() async throws {
        let client = RoomClient()
        let store = GroupChatStore(defaults: freshDefaults())
        store.bind(to: client)
        await store.poll("r")
        let action = try #require(store.retries["r"]?.first)
        await store.retry(action, in: "r")
        #expect(client.retryParams?["task_id"] as? String == "t9")
        #expect(client.retryParams?["member_id"] as? String == "cypher")
        #expect(client.retryParams?["execution_generation"] as? Int == 3)
        let stale = try #require(
            GroupRoomRetry([
                "kind": "retry", "task_id": "t9", "member_id": "cypher", "execution_generation": 2,
            ]))
        client.retryParams = nil
        await store.retry(stale, in: "r")
        #expect(client.retryParams == nil)
    }

    @Test func disbandRequiresAMatchingTombstone() async {
        let client = RoomClient()
        let store = GroupChatStore(defaults: freshDefaults())
        store.bind(to: client)
        await store.refreshRooms()
        await store.disband("r")
        #expect(store.rooms.contains { $0.id == "r" })
        #expect(store.errorMessage != nil)
    }

    @Test func disbandRemovesRoomOnlyAfterConfirmedRefresh() async {
        let client = RoomClient()
        let store = GroupChatStore(defaults: freshDefaults())
        store.bind(to: client)
        await store.refreshRooms()
        client.disbandResult = ["tombstone": ["room_id": "r", "disbanded_at": 1.0]]
        client.listPages = [0: ["rooms": []]]
        await store.disband("r")
        #expect(store.rooms.isEmpty)
        #expect(store.errorMessage == nil)
    }

    @Test func disbandDoesNotTreatFailedEmptyRefreshAsConfirmation() async {
        let client = RoomClient()
        client.listPages = [0: ["rooms": []]]
        let store = GroupChatStore(defaults: freshDefaults())
        store.bind(to: client)
        await store.refreshRooms()
        client.disbandResult = ["tombstone": ["room_id": "r", "disbanded_at": 1.0]]
        client.failingMethod = "groups.list"
        await store.disband("r")
        #expect(store.errorMessage?.contains("could not be verified") == true)
    }

    @Test func longRoomsOpenAtTheTailAndLoadEarlierOnDemand() async {
        let client = RoomClient()
        client.latest = GroupChatStore.historyWindow + 1
        let store = GroupChatStore(defaults: freshDefaults())
        store.bind(to: client)
        await store.poll("r")
        #expect(store.earliestLoadedSeq["r"] == 1)
        #expect(client.sinceSeqs.dropFirst().first == 1)
        await store.loadEarlier("r")
        #expect(store.earliestLoadedSeq["r"] == 0)
        #expect(store.events["r"]?.first?.seq == 1)
    }

    @Test func memberTurnsSplitOnDriverPromptsAndMatchRoomReplies() {
        let rows: [[String: Any]] = [
            ["role": "user", "content": "[Discussion] ..."],
            [
                "role": "assistant", "content": "",
                "tool_calls": [["id": "c1", "function": ["name": "terminal", "arguments": "{\"command\":\"ls\"}"]]],
            ],
            ["role": "tool", "content": "a.txt"],
            ["role": "assistant", "content": "Found a.txt"],
            ["role": "user", "content": "[Discussion] ..."],
        ]
        let turns = GroupMemberTurn.turns(from: rows)
        #expect(turns.count == 2)
        #expect(turns[0].tools.map(\.name) == ["terminal"])
        #expect(turns[0].matches("Found a.txt\n"))
        #expect(turns[1].reply == nil)
    }

    @Test func eventsCarryTheirThreadAndSendTargetsIt() async {
        let event = GroupRoomEvent([
            "seq": 1, "event_id": "a", "kind": "message.user", "payload": ["text": "hi", "thread_id": "t-1"],
        ])
        #expect(event?.threadID == "t-1")
        let client = RoomClient()
        let store = GroupChatStore(defaults: freshDefaults())
        store.bind(to: client)
        await store.send("hello", to: "r", thread: "t-1")
        let payload = client.sent?["payload"] as? [String: Any]
        #expect(payload?["thread_id"] as? String == "t-1")
        #expect(payload?["text"] as? String == "hello")
    }

    @Test func attachmentsUploadThenRideOnTheSendManifest() async throws {
        let client = RoomClient()
        let store = GroupChatStore(defaults: freshDefaults())
        store.bind(to: client)
        await store.refreshRooms()
        #expect(store.supportsAttachments)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("notes-\(UUID().uuidString).txt")
        try Data("hello".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try await store.uploadAttachment(url, to: "r")
        #expect(client.uploaded?["kind"] as? String == "file")
        #expect(client.uploaded?["mime"] as? String == "text/plain")
        #expect(client.uploaded?["data_base64"] as? String == Data("hello".utf8).base64EncodedString())
        await store.send("", attachments: [file], to: "r")
        let payload = client.sent?["payload"] as? [String: Any]
        #expect((payload?["attachments"] as? [[String: Any]])?.first?["attachment_id"] as? String == "att-1")
        let echoed = GroupRoomEvent([
            "seq": 3, "kind": "message.user", "payload": ["text": "", "attachments": [file.manifest]],
        ])
        #expect(echoed?.attachments == [file])
        #expect(GroupRoomAttachment.kind(forMIME: "image/png") == "image")
        #expect(GroupRoomAttachment.kind(forMIME: "application/pdf") == "pdf")
    }

    @Test func selectedFilesReachGroupUploadAndSend() async throws {
        let client = RoomClient()
        let store = GroupChatStore(defaults: freshDefaults())
        store.bind(to: client)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("group-\(UUID().uuidString).txt")
        try Data("selected".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        var selected: [URL] = []
        var error: String?
        GroupChatView.handleAttachmentSelection(.success([url]), upload: { selected = $0 }, report: { error = $0 })
        #expect(selected == [url])
        #expect(error == nil)
        let attachment = try await store.uploadAttachment(try #require(selected.first), to: "r")
        await store.send("draft", attachments: [attachment], to: "r")
        let payload = client.sent?["payload"] as? [String: Any]
        #expect(payload?["text"] as? String == "draft")
        #expect((payload?["attachments"] as? [[String: Any]])?.first?["attachment_id"] as? String == attachment.id)
    }

    @Test func attachFileActionCompletesNativePickerAndSendsManifest() async throws {
        let app = NSApplication.shared
        let accessibility = app.value(forKey: "accessibilityEnhancedUserInterface")
        app.setValue(true, forKey: "accessibilityEnhancedUserInterface")
        defer { app.setValue(accessibility, forKey: "accessibilityEnhancedUserInterface") }
        let client = RoomClient()
        let store = GroupChatStore(defaults: freshDefaults())
        store.bind(to: client)
        await store.refreshRooms()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("group-\(UUID().uuidString).txt")
        try Data("selected".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let view = GroupChatView(
            store: store, botMode: BotModeModel(), roomID: "r", toolbar: { title, _ in title }, onDisbanded: {}
        ).environment(\.dockHostVisible, false).frame(width: 420, height: 500)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 500),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        func elements(_ element: AnyObject) -> [AnyObject] {
            [element] + (element.accessibilityChildren?() ?? []).flatMap { elements($0 as AnyObject) }
        }
        host.layoutSubtreeIfNeeded()
        let insert = try #require(
            elements(host).first { $0.accessibilityLabel?() == "Attach files or insert a snippet" })
        #expect(insert.accessibilityPerformPress?() == true)
        var attach: AnyObject?
        for _ in 0..<100 {
            attach = app.windows.flatMap { elements($0) }.first { $0.accessibilityLabel?() == "Attach File" }
            if attach != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let before = Set(app.windows.map(ObjectIdentifier.init))
        #expect(try #require(attach).accessibilityPerformPress?() == true)
        var panel: NSOpenPanel?
        for _ in 0..<100 {
            panel =
                (window.attachedSheet as? NSOpenPanel)
                ?? (app.windows.first { !before.contains(ObjectIdentifier($0)) && $0 is NSOpenPanel } as? NSOpenPanel)
            if panel != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let picker = try #require(panel)
        #expect(picker.allowsMultipleSelection)
        defer { picker.cancel(nil) }
        picker.directoryURL = url.deletingLastPathComponent()
        var fileRow: AnyObject?
        for _ in 0..<200 {
            fileRow = elements(picker).first {
                $0.accessibilityLabel?() == url.lastPathComponent
                    && $0.accessibilityRole?() == .row
            }
            if fileRow != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try #require(fileRow).accessibilityPerformPress?() == true)
        picker.ok(nil)
        for _ in 0..<200 {
            host.layoutSubtreeIfNeeded()
            if elements(host).contains(where: { $0.accessibilityLabel?() == "Remove \(url.lastPathComponent)" }) {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(elements(host).contains { $0.accessibilityLabel?() == "Remove \(url.lastPathComponent)" })
        func findEditor(_ view: NSView) -> ComposerInputTextView? {
            if let editor = view as? ComposerInputTextView { return editor }
            return view.subviews.lazy.compactMap(findEditor).first
        }
        try #require(findEditor(host)).onSubmit?()
        for _ in 0..<200 where client.sent == nil { try await Task.sleep(for: .milliseconds(10)) }
        let payload = try #require(client.sent?["payload"] as? [String: Any])
        let manifest = try #require((payload["attachments"] as? [[String: Any]])?.first)
        #expect(manifest["attachment_id"] as? String == "att-1")
        #expect(manifest["name"] as? String == url.lastPathComponent)
    }

    @Test func pastingAFileInTheGroupComposerUploadsWithoutReplacingDraft() async throws {
        _ = NSApplication.shared
        let client = RoomClient()
        let store = GroupChatStore(defaults: freshDefaults())
        store.bind(to: client)
        await store.refreshRooms()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("group-\(UUID().uuidString).txt")
        try Data("pasted".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let view = GroupChatView(
            store: store, botMode: BotModeModel(), roomID: "r", toolbar: { title, _ in title }, onDisbanded: {}
        ).environment(\.dockHostVisible, false).frame(width: 420, height: 500)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 500),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        func findEditor(_ view: NSView) -> ComposerInputTextView? {
            if let editor = view as? ComposerInputTextView { return editor }
            return view.subviews.lazy.compactMap(findEditor).first
        }
        let editor = try #require(findEditor(host))
        window.makeFirstResponder(editor)
        editor.insertText("Keep draft", replacementRange: NSRange(location: NSNotFound, length: 0))
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        defer { pasteboard.clearContents() }
        #expect(pasteboard.writeObjects([url as NSURL]))
        let pasteItem = NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "")
        #expect(editor.validateUserInterfaceItem(pasteItem))
        editor.paste(nil)
        for _ in 0..<200 where client.uploaded == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(editor.string == "Keep draft")
        #expect(client.uploaded?["name"] as? String == url.lastPathComponent)
        #expect(client.uploaded?["room_id"] as? String == "r")
    }

    @Test func pastingAFileWithoutGatewaySupportKeepsDraftAndReportsError() async throws {
        _ = NSApplication.shared
        let client = RoomClient()
        client.supportsAttachments = false
        let store = GroupChatStore(defaults: freshDefaults())
        store.bind(to: client)
        await store.refreshRooms()
        let view = GroupChatView(
            store: store, botMode: BotModeModel(), roomID: "r", toolbar: { title, _ in title }, onDisbanded: {}
        ).environment(\.dockHostVisible, false).frame(width: 420, height: 500)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 500),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        func findEditor(_ view: NSView) -> ComposerInputTextView? {
            if let editor = view as? ComposerInputTextView { return editor }
            return view.subviews.lazy.compactMap(findEditor).first
        }
        let editor = try #require(findEditor(host))
        window.makeFirstResponder(editor)
        editor.insertText("Keep draft", replacementRange: NSRange(location: NSNotFound, length: 0))
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        defer { pasteboard.clearContents() }
        #expect(pasteboard.writeObjects([URL(fileURLWithPath: "/tmp/group-file.txt") as NSURL]))
        let pasteItem = NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "")
        #expect(editor.validateUserInterfaceItem(pasteItem))
        editor.paste(nil)
        #expect(editor.string == "Keep draft")
        #expect(client.uploaded == nil)
        #expect(store.errorMessage == "This gateway does not support group file attachments.")
    }

    @Test func failedAttachmentSendReportsFailure() async {
        let client = RoomClient()
        client.failingMethod = "groups.send"
        let store = GroupChatStore(defaults: freshDefaults())
        store.bind(to: client)
        let file = GroupRoomAttachment(id: "a", kind: "file", name: "file.txt", mime: "text/plain", size: 5)
        #expect(!(await store.send("draft", attachments: [file], to: "r")))
        #expect(store.errorMessage?.contains("Couldn't send:") == true)
    }

    @Test(arguments: [false, true])
    func attachmentSendKeepsNewerDraftAfterRoomUnmount(success: Bool) async throws {
        let app = NSApplication.shared
        let accessibility = app.value(forKey: "accessibilityEnhancedUserInterface")
        app.setValue(true, forKey: "accessibilityEnhancedUserInterface")
        defer { app.setValue(accessibility, forKey: "accessibilityEnhancedUserInterface") }
        let client = RoomClient()
        let (pause, release) = AsyncStream<Void>.makeStream()
        client.sendPause = pause
        client.failSendAfterPause = !success
        defer { release.finish() }
        let store = GroupChatStore(defaults: freshDefaults())
        store.bind(to: client)
        await store.refreshRooms()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("group-\(UUID().uuidString).txt")
        try Data("pasted".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let view = GroupChatView(
            store: store, botMode: BotModeModel(), roomID: "r", toolbar: { title, _ in title }, onDisbanded: {}
        ).environment(\.dockHostVisible, false).frame(width: 420, height: 500)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 500),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        func findEditor(_ view: NSView) -> ComposerInputTextView? {
            if let editor = view as? ComposerInputTextView { return editor }
            return view.subviews.lazy.compactMap(findEditor).first
        }
        func elements(_ element: AnyObject) -> [AnyObject] {
            [element] + (element.accessibilityChildren?() ?? []).flatMap { elements($0 as AnyObject) }
        }
        func hasAttachment() -> Bool {
            elements(host).contains { $0.accessibilityLabel?() == "Remove \(url.lastPathComponent)" }
        }
        host.layoutSubtreeIfNeeded()
        let editor = try #require(findEditor(host))
        window.makeFirstResponder(editor)
        editor.insertText("Keep draft", replacementRange: NSRange(location: NSNotFound, length: 0))
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        defer { pasteboard.clearContents() }
        #expect(pasteboard.writeObjects([url as NSURL]))
        editor.paste(nil)
        for _ in 0..<200 {
            host.layoutSubtreeIfNeeded()
            if hasAttachment() { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(hasAttachment())
        editor.onSubmit?()
        for _ in 0..<200 where client.sendCount == 0 { try await Task.sleep(for: .milliseconds(10)) }
        try #require(client.sendCount == 1)
        if success {
            editor.insertText("Keep draft", replacementRange: NSRange(location: 0, length: 10))
        } else {
            editor.insertText(" newer", replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        let otherRoom = GroupChatView(
            store: store, botMode: BotModeModel(), roomID: "other", toolbar: { title, _ in title }, onDisbanded: {}
        ).environment(\.dockHostVisible, false).frame(width: 420, height: 500)
        window.contentView = NSHostingView(rootView: otherRoom)
        release.yield(())
        for _ in 0..<200 where store.composerDrafts["r"]?.submitting == true {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.composerDrafts["r"]?.submitting == false)
        let reopened = NSHostingView(rootView: view)
        window.contentView = reopened
        reopened.layoutSubtreeIfNeeded()
        let reopenedEditor = try #require(findEditor(reopened))
        #expect(reopenedEditor.string == (success ? "Keep draft" : "Keep draft newer"))
        let restoredChip = elements(reopened).contains { $0.accessibilityLabel?() == "Remove \(url.lastPathComponent)" }
        #expect(restoredChip == !success)
        if !success { #expect(store.errorMessage?.contains("Couldn't send:") == true) }
    }

    @Test func imageAttachmentsDownloadOnceAndRefusalsStayNamedRows() async {
        let client = RoomClient()
        let store = GroupChatStore(defaults: freshDefaults())
        store.bind(to: client)
        let image = GroupRoomAttachment(id: "img", kind: "image", name: "shot.png", mime: "image/png", size: 70)
        await store.loadImage(image, event: "e-1", in: "r")
        await store.loadImage(image, event: "e-1", in: "r")
        #expect(store.attachmentImages["img"] != nil)
        #expect(client.downloads == 1)
        let refused = GroupRoomAttachment(id: "gone", kind: "image", name: "x.png", mime: "image/png", size: 1)
        await store.loadImage(refused, event: "other", in: "r")
        await store.loadImage(refused, event: "other", in: "r")
        #expect(store.attachmentImages["gone"] == nil)
        #expect(client.downloads == 2)
        let file = GroupRoomAttachment(id: "doc", kind: "file", name: "a.txt", mime: "text/plain", size: 1)
        await store.loadImage(file, event: "e-1", in: "r")
        #expect(client.downloads == 2)
    }

    @Test func stopRemainsAvailableWhileSendIsPending() async {
        let client = RoomClient()
        let (pause, release) = AsyncStream<Void>.makeStream()
        let (started, didStart) = AsyncStream<Void>.makeStream()
        client.sendPause = pause
        client.sendStarted = didStart
        let store = GroupChatStore(defaults: freshDefaults())
        store.bind(to: client)
        let task = Task { await store.send("hello", to: "r") }
        for await _ in started { break }
        #expect(store.pendingRooms.contains("r"))
        #expect(store.sendingRooms.contains("r"))
        await store.send("duplicate", to: "r")
        await store.stop("r")
        #expect(client.sendCount == 1)
        #expect(client.stopCount == 1)
        #expect(store.pendingRooms.contains("r"))
        release.yield(())
        release.finish()
        await task.value
        #expect(store.pendingRooms.isEmpty)
        #expect(store.sendingRooms.isEmpty)
    }

    @Test func oldRenameCompletionCannotClearNewSendOrRefreshNewBinding() async {
        let old = RoomClient()
        let (pause, release) = AsyncStream<Void>.makeStream()
        let (started, didStart) = AsyncStream<Void>.makeStream()
        old.renamePause = pause
        old.renameStarted = didStart
        let store = GroupChatStore(defaults: freshDefaults())
        store.bind(to: old)
        let rename = Task { await store.rename("r", to: "old") }
        for await _ in started { break }
        let replacement = RoomClient()
        let (newPause, newRelease) = AsyncStream<Void>.makeStream()
        let (newStarted, newDidStart) = AsyncStream<Void>.makeStream()
        replacement.sendPause = newPause
        replacement.sendStarted = newDidStart
        store.bind(to: replacement)
        let send = Task { await store.send("new", to: "r") }
        for await _ in newStarted { break }
        release.yield(())
        release.finish()
        await rename.value
        #expect(store.pendingRooms.contains("r"))
        newRelease.yield(())
        newRelease.finish()
        await send.value
    }

    @Test func oldStateResponseCannotUpdateNewBinding() async {
        let old = RoomClient()
        let (pause, release) = AsyncStream<Void>.makeStream()
        let (started, didStart) = AsyncStream<Void>.makeStream()
        old.statePause = pause
        old.stateStarted = didStart
        let store = GroupChatStore(defaults: freshDefaults())
        store.bind(to: old)
        let polling = Task { await store.poll("r") }
        for await _ in started { break }
        let replacement = RoomClient()
        store.bind(to: replacement)
        await store.refreshRooms()
        release.yield(())
        release.finish()
        await polling.value
        #expect(!store.workingRooms.contains("r"))
        #expect(store.retries["r"] == nil)
    }

    @Test func oldSendCompletionCannotClearNewBindingPendingState() async {
        let old = RoomClient()
        let (oldPause, oldRelease) = AsyncStream<Void>.makeStream()
        let (oldStarted, oldDidStart) = AsyncStream<Void>.makeStream()
        old.sendPause = oldPause
        old.sendStarted = oldDidStart
        let store = GroupChatStore(defaults: freshDefaults())
        store.bind(to: old)
        let oldSend = Task { await store.send("old", to: "r") }
        for await _ in oldStarted { break }
        let replacement = RoomClient()
        let (newPause, newRelease) = AsyncStream<Void>.makeStream()
        let (newStarted, newDidStart) = AsyncStream<Void>.makeStream()
        replacement.sendPause = newPause
        replacement.sendStarted = newDidStart
        store.bind(to: replacement)
        let newSend = Task { await store.send("new", to: "r") }
        for await _ in newStarted { break }
        oldRelease.yield(())
        oldRelease.finish()
        await oldSend.value
        #expect(store.pendingRooms.contains("r"))
        #expect(!store.workingRooms.contains("r"))
        newRelease.yield(())
        newRelease.finish()
        await newSend.value
        #expect(store.pendingRooms.isEmpty)
    }

    @Test func roomListCollectsAllPagesAndKeepsPreviousOnInvalidCursor() async {
        let client = RoomClient()
        client.listPages = [
            0: ["rooms": [["room_id": "r", "members": []]], "next_offset": 1],
            1: ["rooms": [["room_id": "s", "members": []]], "next_offset": NSNull()],
        ]
        let store = GroupChatStore(defaults: freshDefaults())
        store.bind(to: client)
        await store.refreshRooms()
        #expect(store.rooms.map(\.id) == ["r", "s"])
        client.listPages = [0: ["rooms": [], "next_offset": 0]]
        await store.refreshRooms()
        #expect(store.rooms.map(\.id) == ["r", "s"])
    }

    @Test func malformedRoomRowDoesNotReplaceValidList() async {
        let client = RoomClient()
        let store = GroupChatStore(defaults: freshDefaults())
        store.bind(to: client)
        await store.refreshRooms()
        #expect(store.rooms.map(\.id) == ["r"])
        client.listPages = [0: ["rooms": [["name": "missing identity"]]]]
        await store.refreshRooms()
        #expect(store.rooms.map(\.id) == ["r"])
    }

    @Test func remoteMemberNeverLooksUpLocalSession() async {
        let client = RoomClient()
        client.listPages = [
            0: [
                "rooms": [
                    [
                        "room_id": "r",
                        "members": [
                            ["member_id": "peer", "profile": "same-name", "target": ["kind": "peer"]]
                        ],
                    ]
                ]
            ]
        ]
        let store = GroupChatStore(defaults: freshDefaults())
        store.bind(to: client)
        await store.refreshRooms()
        await store.poll("r")
        #expect(client.sessionListCount == 0)
    }

    @Test func oldRoomListResponseCannotReplaceNewBinding() async {
        let old = RoomClient()
        let (pause, release) = AsyncStream<Void>.makeStream()
        let (started, didStart) = AsyncStream<Void>.makeStream()
        old.listPause = pause
        old.listStarted = didStart
        let store = GroupChatStore(defaults: freshDefaults())
        store.bind(to: old)
        for await _ in started { break }
        let replacement = RoomClient()
        replacement.listPages = [0: ["rooms": [["room_id": "new", "members": []]]]]
        store.bind(to: replacement)
        await store.refreshRooms()
        release.yield(())
        release.finish()
        await Task.yield()
        #expect(store.rooms.map(\.id) == ["new"])
    }

    @Test func olderRefreshCannotReplaceNewerSnapshotOnSameBinding() async {
        let client = RoomClient()
        client.listPages = [0: ["rooms": [["room_id": "old", "members": []]]]]
        let (pause, release) = AsyncStream<Void>.makeStream()
        let (started, didStart) = AsyncStream<Void>.makeStream()
        let store = GroupChatStore(defaults: freshDefaults())
        let (initial, initialStarted) = AsyncStream<Void>.makeStream()
        client.listStarted = initialStarted
        store.bind(to: client)
        for await _ in initial { break }
        await store.refreshRooms()
        client.listPause = pause
        client.listStarted = didStart
        let oldRefresh = Task { await store.refreshRooms() }
        for await _ in started { break }
        client.listPages = [0: ["rooms": [["room_id": "new", "members": []]]]]
        await store.refreshRooms()
        release.yield(())
        release.finish()
        _ = await oldRefresh.value
        #expect(store.rooms.map(\.id) == ["new"])
    }

    @Test func roomsStartReadAndTurnUnreadOnLaterActivity() async {
        let client = RoomClient()
        let store = GroupChatStore(defaults: freshDefaults())
        store.bind(to: client)
        await store.refreshRooms()
        #expect(store.rooms.first.map(store.isUnread) == false)
        client.listedSeq = 9
        await store.refreshRooms()
        #expect(store.rooms.first.map(store.isUnread) == true)
        store.markSeen("r", through: 9)
        #expect(store.rooms.first.map(store.isUnread) == false)
    }

    @Test func backgroundPollDoesNotMarkRoomRead() async {
        let client = RoomClient()
        client.listedSeq = 0
        let store = GroupChatStore(defaults: freshDefaults())
        store.bind(to: client)
        await store.refreshRooms()
        client.listedSeq = 2
        await store.refreshRooms()
        #expect(store.rooms.first.map(store.isUnread) == true)
        await store.poll("r")
        #expect(store.rooms.first.map(store.isUnread) == true)
    }

    @Test func rebindingDoesNotReuseUnverifiedRoomReadMarkers() async {
        let defaults = freshDefaults()
        defaults.set(["r": 42], forKey: "groupChat.seenSeq")
        let store = GroupChatStore(defaults: defaults)
        let first = RoomClient()
        store.bind(to: first)
        store.markSeen("r", through: 50)
        store.bind(to: RoomClient())
        #expect(store.seenSeq["r"] == nil)
        #expect((defaults.dictionary(forKey: "groupChat.seenSeq")?["r"] as? Int) == 42)
    }

    @Test func roomLinkInviteRoundTripsIntoAPeerSeatAndRegisters() async throws {
        let client = RoomClient()
        let store = GroupChatStore(defaults: freshDefaults())
        store.bind(to: client)
        let requestCode = RoomLinkCode.encode(
            RemoteMemberRequest(roomID: "r", homeInstallID: "home", memberID: "peer-1", handle: "scout"))
        let request = try #require(RoomLinkCode.decode(RemoteMemberRequest.self, from: " \(requestCode)\n"))
        let bot = BotSummary(
            id: "scout", name: "Scout", title: nil, description: nil, model: nil, isActive: false, chat: nil,
            avatarURL: nil, preview: nil, lastActive: nil, isHidden: false, hasAvatar: false, isDefault: false)
        let inviteCode = try #require(await store.invite(request, bot: bot))
        #expect(client.invited?["authority_epoch"] as? Int == 1)
        let invite = try #require(RoomLinkCode.decode(RemoteMemberInvite.self, from: inviteCode))
        let target = invite.rosterRow["target"] as? [String: Any]
        #expect(target?["kind"] as? String == "peer")
        #expect(target?["capability_digest"] as? String == "abc")
        #expect(target?["installation_id"] as? String == "far")

        let local = BotSummary(
            id: "forge", name: "Forge", title: nil, description: nil, model: nil, isActive: false, chat: nil,
            avatarURL: nil, preview: nil, lastActive: nil, isHidden: false, hasAvatar: false, isDefault: false)
        guard
            case .complete(let roomID) = await store.create(
                name: "Mixed", bots: [local], remote: [invite], roomID: "r")
        else {
            Issue.record("Expected a completed room")
            return
        }
        #expect(roomID == "r")
        #expect(client.registered?["target_url"] as? String == "https://far.example/roomlink")
        #expect((client.registered?["catalog"] as? [String: Any])?["catalog_digest"] as? String == "abc")
    }

    @Test func roomListCarriesTheNewestMessageAsAPreview() async {
        let client = RoomClient()
        let store = GroupChatStore(defaults: freshDefaults())
        store.bind(to: client)
        await store.refreshRooms()
        #expect(store.lastMessages["r"]?.text == "You: m1")
        let calls = client.sinceSeqs.count
        await store.refreshRooms()
        #expect(client.sinceSeqs.count == calls, "unchanged rooms are not re-read")
    }

    @Test func memberRepliesPostABannerOnlyAfterTheFirstSighting() async {
        let client = RoomClient()
        let store = GroupChatStore(defaults: freshDefaults())
        store.bind(to: client)
        var posted: [String] = []
        store.replyNotifier = { _, event in posted.append(event.id) }
        await store.refreshRooms()
        await store.poll("r")
        #expect(posted.isEmpty)
        client.latest = 3
        client.logOverrides[2] = [
            "events": [
                [
                    "seq": 3, "event_id": "e3", "kind": "message.member",
                    "payload": ["member_id": "m", "text": "done"],
                ]
            ],
            "cursor": 3, "latest_seq": 3, "has_more": false,
        ]
        await store.poll("r")
        await store.poll("r")
        #expect(posted == ["e3"])
    }

    @Test func staysHiddenWithoutARoomDriver() async {
        let client = RoomClient()
        client.driver = false
        let store = GroupChatStore(defaults: freshDefaults())
        store.bind(to: client)
        await store.refreshRooms()
        #expect(!store.isAvailable)
        client.driver = true
        await store.refreshRooms()
        #expect(store.isAvailable)
        #expect(store.rooms.map(\.id) == ["r"])
    }
}

@MainActor
private final class RoomClient: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    var supportsAttachments = true
    var failSendAfterPause = false
    var sendPause: AsyncStream<Void>?
    var sendStarted: AsyncStream<Void>.Continuation?
    var renamePause: AsyncStream<Void>?
    var renameStarted: AsyncStream<Void>.Continuation?
    var sendCount = 0
    var stopCount = 0
    var sessionListCount = 0
    var driver = true
    var latest = 2
    var listedSeq = 2
    var failingMethod: String?
    var retryParams: [String: Any]?
    var listPages: [Int: [String: Any]]?
    var listPause: AsyncStream<Void>?
    var listStarted: AsyncStream<Void>.Continuation?
    var statePause: AsyncStream<Void>?
    var stateStarted: AsyncStream<Void>.Continuation?
    var disbandResult: [String: Any] = [:]
    var logOverrides: [Int: [String: Any]] = [:]
    var logPause: AsyncStream<Void>?
    var logStarted: AsyncStream<Void>.Continuation?
    private(set) var sinceSeqs: [Int] = []
    private(set) var sent: [String: Any]?
    private(set) var uploaded: [String: Any]?
    private(set) var invited: [String: Any]?
    private(set) var registered: [String: Any]?
    private(set) var downloads = 0

    func connect() async throws {}
    func close() {}

    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        if method == failingMethod { throw HermesGateway.GatewayError.httpRefused(500, "refused") }
        switch method {
        case "session.list":
            sessionListCount += 1
            return [:]
        case "groups.capabilities":
            let methods = supportsAttachments ? ["groups.send", "groups.attachment.upload"] : ["groups.send"]
            return ["driver": driver, "methods": methods]
        case "groups.attachment.download":
            downloads += 1
            guard params["event_id"] as? String == "e-1" else { throw HermesGateway.GatewayError.httpRefused(404, "") }
            // A 1×1 PNG.
            return [
                "data_base64":
                    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII="
            ]
        case "groups.attachment.upload":
            uploaded = params
            return [
                "attachment_id": "att-1", "kind": params["kind"] ?? "", "name": params["name"] ?? "",
                "mime": params["mime"] ?? "", "size": 5,
            ]
        case "groups.list":
            let result: [String: Any]
            if let listPages {
                result = listPages[params["offset"] as? Int ?? 0] ?? [:]
            } else {
                result = ["rooms": [["room_id": "r", "name": "Audit", "members": [], "latest_seq": listedSeq]]]
            }
            listStarted?.yield(())
            if let listPause {
                self.listPause = nil
                for await _ in listPause { break }
            }
            return result
        case "groups.stop":
            stopCount += 1
            return [:]
        case "groups.rename":
            if let renamePause {
                renameStarted?.yield(())
                for await _ in renamePause { break }
            }
            return [:]
        case "groups.retry":
            retryParams = params
            return [:]
        case "groups.disband":
            return disbandResult
        case "groups.send":
            sendCount += 1
            if let sendPause {
                sendStarted?.yield(())
                for await _ in sendPause { break }
            }
            if failSendAfterPause { throw HermesGateway.GatewayError.httpRefused(500, "refused") }
            sent = params
            return [:]
        case "groups.peer.invite":
            invited = params
            return [
                "grant": "g", "target_profile": "scout",
                "catalog": ["installation_id": "far", "catalog_digest": "abc"],
                "endpoint": ["available": true, "url": "https://far.example/roomlink"],
            ]
        case "groups.peer.register":
            registered = params
            return [:]
        case "groups.log":
            let since = params["since_seq"] as? Int ?? 0
            sinceSeqs.append(since)
            if since == 1, let logPause {
                self.logPause = nil
                logStarted?.yield(())
                for await _ in logPause { break }
            }
            if let override = logOverrides[since] { return override }
            guard since < latest else {
                return ["events": [], "cursor": latest, "latest_seq": latest, "has_more": false]
            }
            let seq = since + 1
            return [
                "events": [
                    ["seq": seq, "event_id": "e\(seq)", "kind": "message.user", "payload": ["text": "m\(seq)"]]
                ],
                "cursor": seq, "latest_seq": latest, "has_more": seq < latest,
            ]
        case "groups.state":
            if let statePause {
                stateStarted?.yield(())
                for await _ in statePause { break }
            }
            return [
                "driver_status": [
                    "working": true, "blocked": true,
                    "pending_actions": [
                        ["kind": "retry", "task_id": "t9", "member_id": "cypher", "execution_generation": 3],
                        [
                            "kind": "approval", "member_id": "cypher", "task_id": "t", "execution_generation": 1,
                            "request_id": "q", "approval": ["command": "rm -rf build"],
                        ],
                    ],
                ]
            ]
        default:
            return [:]
        }
    }
}

private func freshDefaults() -> UserDefaults {
    UserDefaults(suiteName: "GroupChatTests.\(UUID().uuidString)")!
}
