import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Herm

@MainActor
struct SessionFailureWarningTests {
    private let seen = Date(timeIntervalSince1970: 100)

    private func row(_ timestamp: Double, kind: String? = "failed_turn") -> [String: Any] {
        var row: [String: Any] = ["role": "system", "text": "Failed turn", "timestamp": timestamp]
        row["display_kind"] = kind
        return row
    }

    @Test func leadingSlotUsesUnreadCountOnlyWithoutAnotherStatus() {
        for status in [SidebarSessionStatus.needsApproval, .needsClarification, .failed, .working] {
            #expect(!status.allowsUnreadCount)
        }
        #expect(SidebarSessionStatus.none.allowsUnreadCount)
        #expect(SidebarSessionStatus.unreadComplete.allowsUnreadCount)
        #expect(!SessionUnreadReplyBadge.Layout.leadingSlot.showsCount(hasFailure: true))
        #expect(SessionUnreadReplyBadge.Layout.leadingSlot.showsCount(hasFailure: false))
    }

    @Test func failureSeenBoundaryAndCutoff() {
        let cutoff = Date(timeIntervalSince1970: 102)
        let cases: [(Double, Bool)] = [(100, false), (101, true), (102, true), (103, false)]
        for (timestamp, expected) in cases {
            #expect(
                SessionFailureWarningPolicy.hasUnseenFailure(
                    in: [row(timestamp)], after: seen, through: cutoff) == expected)
        }
        #expect(
            !SessionFailureWarningPolicy.hasUnseenFailure(
                in: [row(101)], after: Date(timeIntervalSince1970: 101), through: nil))
        #expect(
            SessionFailureWarningPolicy.hasUnseenFailure(
                in: [row(102)], after: Date(timeIntervalSince1970: 101), through: nil))
    }

    @Test func onlyTypedFailuresAreWarnings() {
        for kind in ["hidden", "warning", "model_switch", "tool"] {
            #expect(
                !SessionFailureWarningPolicy.hasUnseenFailure(
                    in: [row(101, kind: kind)], after: seen, through: nil))
        }
        #expect(
            !SessionFailureWarningPolicy.hasUnseenFailure(
                in: [row(101, kind: nil)], after: seen, through: nil))
        #expect(SessionFailureWarningPolicy.hasUnseenFailure(in: [row(101)], after: seen, through: nil))
    }

    private final class Client: HermesRPCClientProtocol {
        var onEvent: ((String, [String: Any]) -> Void)?
        var paths: [String] = []
        func connect() async throws {}
        func close() {}
        func request(_ method: String, params: [String: Any]) async throws -> [String: Any] { [:] }
        func fetchHTTP(_ path: String) async throws -> [String: Any] {
            paths.append(path)
            let profile = URLComponents(string: path)?.queryItems?.first { $0.name == "profile" }?.value
            let rows: [[String: Any]] =
                profile == "warning-test-a"
                ? [
                    ["id": 1, "role": "assistant", "content": "Reply", "timestamp": 101],
                    [
                        "id": 2, "role": "system", "content": "Failure", "timestamp": 102,
                        "display_kind": "failed_turn",
                    ],
                ] : []
            return ["messages": rows, "pagination": ["returned": rows.count]]
        }
    }

    private final class SuspendedClient: HermesRPCClientProtocol {
        var onEvent: ((String, [String: Any]) -> Void)?
        var pending: CheckedContinuation<[String: Any], Never>?
        var released = false
        func connect() async throws {}
        func close() {}
        func request(_ method: String, params: [String: Any]) async throws -> [String: Any] { [:] }
        func fetchHTTP(_ path: String) async throws -> [String: Any] {
            let profile = URLComponents(string: path)?.queryItems?.first { $0.name == "profile" }?.value
            if profile == "warning-test-a" {
                let response = await withCheckedContinuation { pending = $0 }
                released = true
                return response
            }
            let rows: [[String: Any]] = [
                ["id": 1, "role": "assistant", "content": "First", "timestamp": 101],
                ["id": 2, "role": "assistant", "content": "Second", "timestamp": 102],
            ]
            return ["messages": rows, "pagination": ["returned": rows.count]]
        }

        func release() {
            let rows: [[String: Any]] = [
                ["id": 1, "role": "assistant", "content": "Old reply", "timestamp": 101],
                [
                    "id": 2, "role": "system", "content": "Failure", "timestamp": 102,
                    "display_kind": "failed_turn",
                ],
            ]
            pending?.resume(returning: ["messages": rows, "pagination": ["returned": rows.count]])
            pending = nil
        }
    }

    #if DEBUG
        @Test func latePreviousProfileCannotReplaceNewProfileBadge() async throws {
            let client = SuspendedClient()
            let replies = SessionUnreadReplies(client: client)
            let suite = "SessionFailureWarningTests.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = SidebarSessionSeenStore(defaults: defaults)
            let sessionID = "failure-warning-race-test"
            for profile in ["warning-test-a", "warning-test-b"] {
                store.markSeen(profileID: profile, sessionID: sessionID, at: seen)
            }
            var labels: [String] = []
            func root(_ profile: String) -> some View {
                let session = HermesSession(
                    id: sessionID, profileID: profile, title: "Chat", preview: "", startedAt: nil,
                    messageCount: 0, source: "test")
                return SessionRowActivityIndicators(session: session, attention: nil, seenStore: store)
                    .environment(\.sessionUnreadReplies, SessionUnreadReplyContext(replies: replies, profileID: nil))
                    .onPreferenceChange(SessionStatusLabels.self) { labels = $0 }
            }
            let host = NSHostingView(rootView: root("warning-test-a"))
            host.frame = NSRect(x: 0, y: 0, width: 200, height: 40)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderFrontRegardless()
            defer {
                client.release()
                window.close()
            }
            for _ in 0..<1_000 {
                host.layoutSubtreeIfNeeded()
                if client.pending != nil { break }
                await Task.yield()
            }
            #expect(client.pending != nil)
            host.rootView = root("warning-test-b")
            for _ in 0..<1_000 {
                host.layoutSubtreeIfNeeded()
                if labels.contains("2 unread AI responses") { break }
                await Task.yield()
            }
            #expect(labels.contains("2 unread AI responses"))
            client.release()
            for _ in 0..<1_000 {
                host.layoutSubtreeIfNeeded()
                if client.released { break }
                await Task.yield()
            }
            #expect(client.released)
            for _ in 0..<100 {
                host.layoutSubtreeIfNeeded()
                await Task.yield()
            }
            let current = labels
            #expect(current.contains("2 unread AI responses"))
            #expect(!current.contains("1 unread AI response"))
            #expect(!current.contains("Failed turn. Open conversation for details."))
        }

        @Test func idleAttentionKeepsUnreadAndWarningAcrossProfileReplacement() async throws {
            let client = Client()
            let replies = SessionUnreadReplies(client: client)
            let sessionID = "failure-warning-render-test"
            let suite = "SessionFailureWarningTests.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = SidebarSessionSeenStore(defaults: defaults)
            for profile in ["warning-test-a", "warning-test-b"] {
                store.markSeen(profileID: profile, sessionID: sessionID, at: seen)
            }
            func session(_ profile: String) -> HermesSession {
                HermesSession(
                    id: sessionID, profileID: profile, title: "Chat", preview: "", startedAt: nil,
                    messageCount: 0, source: "test")
            }
            var labels: [String] = []
            func root(_ profile: String, _ attention: SessionAttentionDot) -> some View {
                SessionRowActivityIndicators(session: session(profile), attention: attention, seenStore: store)
                    .environment(\.sessionUnreadReplies, SessionUnreadReplyContext(replies: replies, profileID: nil))
                    .onPreferenceChange(SessionStatusLabels.self) { labels = $0 }
            }
            let host = NSHostingView(rootView: root("warning-test-a", .warning))
            host.frame = NSRect(x: 0, y: 0, width: 200, height: 40)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderFrontRegardless()
            defer { window.close() }
            for attention in [SessionAttentionDot.warning, .clarification, .activity] {
                host.rootView = root("warning-test-a", attention)
                for _ in 0..<1_000 {
                    host.layoutSubtreeIfNeeded()
                    if labels.contains("1 unread AI response") { break }
                    await Task.yield()
                }
                let current = labels
                #expect(current.contains("1 unread AI response"))
                #expect(current.contains("Failed turn. Open conversation for details."))
                if let state = attention.activityState {
                    #expect(current.contains(state.label))
                }
            }
            host.rootView = root("warning-test-b", .warning)
            for _ in 0..<1_000 {
                host.layoutSubtreeIfNeeded()
                if client.paths.contains(where: { $0.contains("profile=warning-test-b") }) { break }
                await Task.yield()
            }
            for _ in 0..<50 { await Task.yield() }
            #expect(client.paths.contains { $0.contains("profile=warning-test-a") })
            #expect(client.paths.contains { $0.contains("profile=warning-test-b") })
            #expect(!labels.contains("Failed turn. Open conversation for details."))
            #expect(!labels.contains("1 unread AI response"))
        }
    #endif
}
