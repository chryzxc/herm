import AVFoundation
import Foundation
import Testing

@testable import Herm

struct VoiceHUDTests {
    private func json(_ object: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), encoding: .utf8)!
    }

    private func call(_ name: String, _ args: [String: String], result: [String: Any]? = nil, at offset: TimeInterval)
        -> ActiveToolCall
    {
        let start = Date(timeIntervalSince1970: 1000 + offset)
        return ActiveToolCall(
            id: "\(name)-\(offset)", name: name, input: "", context: "", startedAt: start,
            result: result.map(json), isComplete: result != nil,
            completedAt: result == nil ? nil : start.addingTimeInterval(1), args: args)
    }

    @Test func browserTrailNamesElementsFromTheSnapshot() throws {
        let calls = [
            call(
                "browser_navigate", ["url": "https://www.booking.com"],
                result: [
                    "success": true, "title": "Booking.com", "url": "https://www.booking.com/",
                    "snapshot": "- link \"Sign in\" [ref=e2]\n- textbox \"Password\" [ref=e7]",
                ], at: 0),
            call("browser_click", ["ref": "@e2"], result: ["clicked": "@e2"], at: 2),
            call("browser_type", ["ref": "@e7", "text": "hunter2"], result: ["typed": "hunter2"], at: 4),
            call("browser_scroll", ["direction": "down"], at: 6),
        ]
        let browser = try #require(BrowserSession(calls: calls))
        #expect(browser.title == "Booking.com")
        #expect(browser.url == "https://www.booking.com/")
        #expect(browser.hosts == ["booking.com"])
        #expect(
            browser.trail == [
                "Opened booking.com", "Clicked “Sign in” link", "Typed •••• into “Password” textbox", "Scrolled down",
            ])
        #expect(browser.isBusy)
    }

    @Test func searchAndTerminalReadStoredResults() throws {
        let search = try #require(
            SearchFan(calls: [
                call(
                    "web_search", ["query": "swift 6"],
                    result: [
                        "success": true,
                        "data": [
                            "web": [
                                ["title": "Swift.org", "url": "https://swift.org/", "description": "x", "position": 1]
                            ]
                        ],
                    ], at: 0)
            ]))
        #expect(search.hits == [SearchFan.Hit(title: "Swift.org", url: "https://swift.org/")])

        let terminal = try #require(
            TerminalTicker(calls: [
                call(
                    "terminal", ["command": "pytest"],
                    result: [
                        "output": "collected 12\n==== 2 failed, 10 passed in 1.2s ====\n", "exit_code": 1,
                        "error": NSNull(),
                    ], at: 0)
            ]))
        #expect(terminal.exitCode == 1)
        #expect(terminal.lastLine == "==== 2 failed, 10 passed in 1.2s ====")
        #expect(terminal.tests == TestSummary(passed: 10, failed: 2))
    }

    @Test func testSummariesAcrossRunners() {
        #expect(TestSummary("Executed 14 tests, with 3 failures (0 unexpected)") == TestSummary(passed: 11, failed: 3))
        #expect(
            TestSummary("✔ Test run with 28 tests in 4 suites passed after 0.5 seconds.")
                == TestSummary(passed: 28, failed: 0))
        #expect(
            TestSummary("✘ Test run with 28 tests in 4 suites failed after 0.5 seconds with 2 issues.")
                == TestSummary(passed: 26, failed: 2))
        #expect(TestSummary("Tests:       1 failed, 41 passed, 42 total") == TestSummary(passed: 41, failed: 1))
        #expect(TestSummary("Compiling…\nBuild complete!") == nil)
    }

    @Test func toolStepsReadLikeSentences() {
        #expect(
            ToolStep.describe(name: "browser_navigate", args: ["url": "https://www.booking.com/x"]).title
                == "Browsing booking.com")
        #expect(ToolStep.describe(name: "patch", args: ["path": "/a/b/Views.swift"]).title == "Editing Views.swift")
        #expect(
            ToolStep.describe(name: "memory", args: ["action": "add", "content": "likes tea"], isComplete: true).title
                == "Remembered")
        #expect(
            ToolStep.describe(name: "yb_send_dm", args: ["to": "sam", "message": "hi"], isComplete: true).detail
                == "sam · “hi”")
    }

    /// Voice processing's channel 0 is the echo-cancelled voice; the others would mix the reply back in.
    @Test func echoCancelledMicKeepsOnlyTheCleanedChannel() throws {
        let layout = try #require(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 3))
        let buffer = try #require(
            AVAudioPCMBuffer(
                pcmFormat: AVAudioFormat(standardFormatWithSampleRate: 48_000, channelLayout: layout), frameCapacity: 64
            ))
        buffer.frameLength = 64
        for (channel, value) in [Float(0.25), 0.9, -0.9].enumerated() {
            for frame in 0..<64 { buffer.floatChannelData![channel][frame] = value }
        }
        let mono = try #require(MicLevelMeter.firstChannel(of: buffer))
        #expect(mono.format.channelCount == 1)
        #expect((0..<64).allSatisfy { mono.floatChannelData![0][$0] == 0.25 })
    }
}
