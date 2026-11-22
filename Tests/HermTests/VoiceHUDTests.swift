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
        #expect(ToolStep.describe(name: "browser_exec", args: ["code": "secret"]).detail == nil)
        #expect(ToolStep.describe(name: "browser_cdp", args: ["command": "secret"]).detail == nil)
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

    @Test func toolLabelsMatchExistingFormattingForRawAndEncodedArguments() throws {
        let args: [String: Any] = [
            "path": "/tmp/example.md", "command": String(repeating: "echo ", count: 200),
            "urls": ["https://example.com/search"], "unrelated": ["bytes": Array(repeating: 42, count: 500)],
        ]
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self)
        for name in ["browser_exec", "terminal", "web_extract", "read_file"] {
            let expected = ToolStep.describe(name: name, args: DockModel.textArgs(args) ?? [:])
            for source: Any in [args, encoded] {
                let actual = ToolStep.describe(name: name, rawArgs: source)
                #expect(actual.icon == expected.icon)
                #expect(actual.title == expected.title)
                #expect(actual.detail == expected.detail)
            }
        }
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
        let mono = try #require(MicBufferNormalizer(firstChannelOnly: true).normalize(buffer))
        #expect(mono.format.channelCount == 1)
        #expect((0..<64).allSatisfy { mono.floatChannelData![0][$0] == 0.25 })
        // Without voice processing the existing deinterleaved Float32 buffer passes through untouched.
        #expect(MicBufferNormalizer(firstChannelOnly: false).normalize(buffer) === buffer)
    }

    /// USB mics (#209) can deliver interleaved or integer samples; they must reach recognition, not be dropped.
    @Test func interleavedAndIntegerMicsBecomeMonoFloat() throws {
        let stereoFloat = try #require(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true))
        let floats = try #require(AVAudioPCMBuffer(pcmFormat: stereoFloat, frameCapacity: 64))
        floats.frameLength = 64
        let floatSamples = floats.mutableAudioBufferList.pointee.mBuffers.mData!.assumingMemoryBound(to: Float.self)
        for frame in 0..<64 {
            floatSamples[frame * 2] = 0.25
            floatSamples[frame * 2 + 1] = -0.9
        }

        let stereoInt = try #require(
            AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 2, interleaved: true))
        let ints = try #require(AVAudioPCMBuffer(pcmFormat: stereoInt, frameCapacity: 64))
        ints.frameLength = 64
        for frame in 0..<64 {
            ints.int16ChannelData![0][frame * 2] = Int16.max / 4
            ints.int16ChannelData![0][frame * 2 + 1] = Int16.min
        }

        let monoInt = try #require(
            AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false))
        let mono = try #require(AVAudioPCMBuffer(pcmFormat: monoInt, frameCapacity: 64))
        mono.frameLength = 64
        for frame in 0..<64 { mono.int16ChannelData![0][frame] = Int16.max / 4 }

        for (buffer, firstChannelOnly) in [(floats, true), (ints, true), (ints, false), (mono, false)] {
            let out = try #require(MicBufferNormalizer(firstChannelOnly: firstChannelOnly).normalize(buffer))
            #expect(out.format.commonFormat == .pcmFormatFloat32)
            #expect(!out.format.isInterleaved)
            #expect(out.format.channelCount == 1)
            #expect(out.format.sampleRate == buffer.format.sampleRate)
            #expect(out.frameLength == 64)
            // Channel 0 only, never mixed with the other channel.
            #expect((0..<64).allSatisfy { abs(out.floatChannelData![0][$0] - 0.25) < 0.001 })
            #expect(SpeechInput.normalizedAudioLevel(out) > 0)
        }
    }

    @Test func stageLayoutKeepsActivityCardsOutOfTheCenterColumn() {
        // Wide pane: cards fit beside the 360pt column without crossing it.
        let wide = VoiceStageLayout(size: CGSize(width: 1000, height: 700), immersive: false, hasPanel: false)
        #expect(!wide.isCompact)
        #expect(wide.cardWidth >= VoiceStageLayout.minCardWidth)
        #expect(wide.columnWidth + 2 * (wide.cardWidth + 12 + 12) <= 1000)
        #expect(wide.compactCardSlot == 0)

        // Narrow pane (the reported clash): cards move below the controls.
        let narrow = VoiceStageLayout(size: CGSize(width: 640, height: 640), immersive: false, hasPanel: false)
        #expect(narrow.isCompact)
        #expect(narrow.cardWidth <= 640 - 24)
        #expect(narrow.compactCardSlot > 0)

        let hidden = VoiceStageLayout(
            size: CGSize(width: 640, height: 640), immersive: false, hasPanel: false, cardsEnabled: false)
        #expect(hidden.compactCardSlot == 0)
    }

    @Test func stageLayoutShrinksTheOrbAndStacksThePanelWhenSmall() {
        let roomy = VoiceStageLayout(size: CGSize(width: 1200, height: 900), immersive: true, hasPanel: true)
        #expect(roomy.showsPanelBeside)
        #expect(roomy.orbSide == 320 * 0.85)

        let small = VoiceStageLayout(size: CGSize(width: 600, height: 480), immersive: false, hasPanel: true)
        #expect(!small.showsPanelBeside)
        #expect(small.orbSide < 320 * 0.65)
        #expect(small.orbSide >= 120)
        #expect(small.columnWidth <= 600 - 32)
    }
}
