import Foundation
import Testing

@testable import Herm

struct VoiceStagePresentationTests {
    private func stage(_ state: HermesVoiceState, status: HermesStatus = .idle) -> VoiceStagePresentation {
        VoiceStagePresentation(voiceState: state, status: status)
    }

    @Test func orbFollowsNativeVoiceState() {
        #expect(stage(.listening).orbMode == .listening)
        #expect(stage(.interrupted).orbMode == .transcribing)
        #expect(stage(.preparing).orbMode == .thinking)
        // A reply with no caption yet is still being prepared.
        #expect(stage(.speaking).orbMode == .thinking)
        var speaking = stage(.speaking)
        speaking.hasSpokenCaption = true
        #expect(speaking.orbMode == .speaking)
        #expect(stage(.paused, status: .working).orbMode == .thinking)
        #expect(stage(.inactive).orbMode == .idle)
    }

    @Test func localFallbackCaptureOverridesNativeState() {
        var local = stage(.inactive)
        local.isRecording = true
        #expect(local.orbMode == .listening)
        #expect(local.orbHelp == "Send now")
        local.isRecording = false
        local.isFallbackSpeaking = true
        #expect(local.orbMode == .speaking)
        #expect(local.orbHelp == "Interrupt")
    }

    @Test func statusNamesTheWakePhraseOnlyWhenItCanWake() {
        var paused = stage(.paused)
        #expect(paused.statusText == "PAUSED — TAP TO RESUME")
        paused.wakesByVoice = true
        #expect(paused.statusText == "SAY “HEY HERM” OR TAP")
        paused.wakeName = "Atlas"
        #expect(paused.statusText == "SAY “HEY ATLAS” OR TAP")
        paused.isMicMuted = true
        #expect(paused.statusText == "MIC MUTED — TAP TO RESUME")
        #expect(paused.interactionHint == "Your microphone is off.")
    }

    @Test func hintSaysWhatTheAgentIsDoingWhileItWorks() {
        var working = stage(.thinking, status: .working)
        #expect(working.interactionHint == "You can keep talking to add to your request.")
        working.stepTitle = "Looking through your Projects folder"
        #expect(working.interactionHint == "Looking through your Projects folder")
        working.voiceState = .listening
        #expect(working.interactionHint == "Speak naturally. Your request sends after a short pause.")
    }

    @Test func activityNamesTheRunningTool() {
        var working = stage(.thinking, status: .working)
        #expect(working.activityText == "HERM IS THINKING")
        working.runningToolName = "web_search"
        #expect(working.activityText == "RUNNING WEB_SEARCH")
        working.isReasoning = true
        #expect(working.activityText == "HERM IS REASONING")
    }
}

struct VoiceStagePreviewTests {
    private let step = ActiveToolCall(
        id: "1", name: "read_file", input: "", context: "", startedAt: .now, result: "{}", isComplete: true,
        completedAt: .now, args: ["path": "/tmp/a"])

    private func preview(
        _ surface: VoiceSurface, tab: SessionInspector.Section? = nil, visual: Bool = false,
        dismissed: Bool = false, working: Bool = true, calls: [ActiveToolCall]? = nil
    ) -> VoicePreview? {
        VoiceStagePresentation.preview(
            on: surface, tab: tab, hasVisual: visual, dismissed: dismissed, working: working, calls: calls ?? [step])
    }

    @Test func maximizedTalkShowsTabsThenVisualsThenTheAgentsScreen() {
        #expect(preview(.maximized, tab: .browser, visual: true) == .tab(.browser))
        #expect(preview(.maximized, visual: true) == .visual)
        #expect(preview(.maximized) == .agentScreen)
        #expect(preview(.maximized, working: false) == .agentScreen)
        #expect(preview(.maximized, calls: []) == nil)
        #expect(preview(.maximized, tab: .browser, dismissed: true) == nil)
        // A title-only step shows while it runs, not after the turn.
        let skill = ActiveToolCall(
            id: "2", name: "skill_view", input: "", context: "", startedAt: .now, result: "{}", isComplete: true,
            completedAt: .now, args: [:])
        #expect(preview(.maximized, calls: [skill]) == .agentScreen)
        #expect(preview(.maximized, working: false, calls: [skill]) == nil)
    }

    @Test func theNotchAndTalkTabShowOnlyGenerativeUI() {
        for surface in [VoiceSurface.floating, .talkTab] {
            #expect(preview(surface, tab: .browser) == nil)
            #expect(preview(surface) == nil)
            #expect(preview(surface, tab: .terminal, visual: true) == .visual)
            #expect(preview(surface, visual: true, dismissed: true) == nil)
        }
    }
}

struct VoiceWidgetCopyTests {
    @Test func statusIsOneSentenceCaseWordForWhatIsHappening() {
        var stage = VoiceStagePresentation(voiceState: .listening, status: .idle)
        #expect(stage.widgetStatus == "Listening")
        stage.voiceState = .thinking
        #expect(stage.widgetStatus == "Thinking")
        stage.status = .working
        stage.stepTitle = "Searching the web"
        #expect(stage.widgetStatus == "Searching the web")
        stage.voiceState = .speaking
        stage.hasSpokenCaption = true
        #expect(stage.widgetStatus == "Speaking")
        stage.isMicMuted = true
        #expect(stage.widgetStatus == "Mic off")
    }

    @Test func busyCaptionReplacesThePrivateUtteranceWhileHermesWorks() {
        let stage = VoiceStagePresentation(voiceState: .thinking, status: .working)
        let caption = VoiceAssistantSession.busyMessage
        #expect(
            stage.widgetCaption(heard: "Send a text to Robin", said: "General request", caption: caption)?.text
                == caption)
    }

    @Test func pendingPromptCaptionReplacesThePrivateUtteranceWhileListening() {
        let stage = VoiceStagePresentation(voiceState: .listening, status: .needsClarification)
        let caption = VoiceAssistantSession.pendingPromptMessage
        #expect(stage.widgetCaption(heard: "Send a text to Robin", said: nil, caption: caption)?.text == caption)
    }

    @Test func compactionNamesTheWorkWithoutHidingLiveSpeechOrPendingApproval() {
        var stage = VoiceStagePresentation(voiceState: .thinking, status: .working, isCompacting: true)
        #expect(stage.widgetStatus == "Compacting conversation")
        #expect(
            stage.widgetCaption(heard: "", said: "Open Chrome", caption: nil)?.text
                == "Summarizing earlier messages before continuing.")
        #expect(stage.widgetCaption(heard: "Use Firefox", said: "Open Chrome", caption: nil)?.text == "Use Firefox")
        stage.hasApproval = true
        #expect(stage.widgetStatus == "Approval needed")
        #expect(stage.widgetCaption(heard: "", said: "Run command", caption: nil)?.text == "Run command")
    }

    @Test func liveWordsKeepTheirIdentityUntilTheCaptionHandsOff() throws {
        var stage = VoiceStagePresentation(voiceState: .listening, status: .idle)
        let first = try #require(stage.widgetCaption(heard: "Show", said: nil, caption: nil))
        let revision = try #require(stage.widgetCaption(heard: "Show tomorrow", said: nil, caption: nil))
        #expect(first.handoff == revision.handoff)
        #expect(first.text != revision.text)

        stage.voiceState = .transcribing
        #expect(stage.widgetCaption(heard: "Show tomorrow", said: nil, caption: nil)?.handoff == first.handoff)
        stage.voiceState = .thinking
        let sent = try #require(stage.widgetCaption(heard: "", said: "Show tomorrow", caption: nil))
        #expect(sent.handoff != first.handoff)
    }

    @Test func spokenCaptionHoldsDuringSynthesisAndClearsWhenListeningResumes() throws {
        var stage = VoiceStagePresentation(voiceState: .speaking, status: .working)
        let previous = try #require(
            stage.widgetCaption(heard: "", said: "Old request", caption: nil, heldSpeech: "First sentence."))
        #expect(previous.text == "First sentence.")
        let next = try #require(
            stage.widgetCaption(
                heard: "", said: "Old request", caption: "Second sentence.", heldSpeech: "First sentence."))
        #expect(next.text == "Second sentence.")
        #expect(next.handoff != previous.handoff)

        stage.voiceState = .listening
        #expect(
            stage.widgetCaption(heard: "", said: "Old request", caption: nil, heldSpeech: "First sentence.") == nil)
    }

    @Test func lineFollowsYourWordsThenTheRequestThenTheReply() {
        var stage = VoiceStagePresentation(voiceState: .listening, status: .idle)
        #expect(stage.widgetCaption(heard: "  ", said: "old", caption: nil) == nil)
        #expect(stage.widgetCaption(heard: "what's on", said: "old", caption: nil)?.text == "what's on")
        stage.voiceState = .preparing
        #expect(
            stage.widgetCaption(heard: "", said: "what's on my calendar", caption: nil)?.text == "what's on my calendar"
        )
        stage.voiceState = .speaking
        stage.hasSpokenCaption = true
        #expect(stage.widgetCaption(heard: "", said: "q", caption: "Two meetings.")?.text == "Two meetings.")
        stage.voiceState = .paused
        #expect(stage.widgetCaption(heard: "", said: "q", caption: nil) == nil)
    }
}

struct EdgeVoiceStagePlacementTests {
    @Test func widgetShowsWheneverVoiceRunsOutsideTalk() {
        #expect(EdgeVoiceStagePlacement.resolve(voiceActive: true, talkTabShowing: false) == .island)
    }

    @Test func talkTabOrNoVoiceHidesTheStage() {
        #expect(EdgeVoiceStagePlacement.resolve(voiceActive: false, talkTabShowing: false) == .hidden)
        #expect(EdgeVoiceStagePlacement.resolve(voiceActive: true, talkTabShowing: true) == .hidden)
    }
}

struct VoiceStagePromptAndRoleTests {
    @Test func promptCardShowsApprovalsAlwaysAndQuestionsOnlyWhenNotSpoken() {
        var stage = VoiceStagePresentation(voiceState: .thinking, status: .needsClarification)
        stage.hasQuestion = true
        #expect(!stage.showsPromptCard(clarificationCard: false))
        #expect(stage.showsPromptCard(clarificationCard: true))
        stage.hasQuestion = false
        stage.hasApproval = true
        #expect(stage.showsPromptCard(clarificationCard: false))
    }

    @Test func notchStatusNamesPendingPromptsWithoutChangingTheVoiceMode() {
        var stage = VoiceStagePresentation(voiceState: .listening, status: .needsApproval)
        stage.hasApproval = true
        #expect(stage.widgetStatus == "Approval needed")
        stage.hasApproval = false
        stage.hasQuestion = true
        #expect(stage.widgetStatus == "Clarification needed")
        stage.hasQuestion = false
        stage.hasValuePrompt = true
        #expect(stage.widgetStatus == "Input needed in chat")
        #expect(stage.orbMode == .listening)
    }

    @Test func botOrbShowsRoleUnlessItRepeatsTheName() {
        var agent = HermesSubagent(id: "a", name: "Scout", goal: "Find docs", role: "Researcher", status: "running")
        #expect(VoiceSubagentOrbs.roleLabel(agent) == "Researcher")
        agent.role = "scout"
        #expect(VoiceSubagentOrbs.roleLabel(agent) == nil)
        agent.role = "  "
        #expect(VoiceSubagentOrbs.roleLabel(agent) == nil)
    }
}
