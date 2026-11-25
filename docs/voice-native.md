# Voice on Apple's native speech stack

Herm's Talk mode uses only Apple frameworks on the Mac for listening,
understanding short commands, and speaking locally. Hermes Agent answers general
requests; Herm can also answer commands from existing Mac data.

## How this relates to Siri

Siri has no public API, and apps can't call Siri's recognizer. On macOS 26, Apple
exposes the same family of on-device speech models through the `Speech`
framework's `SpeechAnalyzer`. Herm uses those models.

| Stage | Framework | Where it runs | Code |
|---|---|---|---|
| Talk-mode transcription | `SpeechAnalyzer` + `SpeechTranscriber` (macOS 26) | On device. The model downloads once through `AssetInventory`. | `Sources/Herm/Voice/VoiceTranscriber.swift` |
| Fallback transcription | `SFSpeechRecognizer` with `requiresOnDeviceRecognition`, `taskHint = .dictation` | On device | `Sources/Herm/Voice/SpeechInput.swift` |
| Wake phrase ("Hey …") | `SpeechTranscriber` or on-device `SFSpeechRecognizer` | On device. Off unless the ear toggle or the Settings option is on. | `SpeechInput.swift` (`canDetectWakePhrase`) |
| Echo cancellation | `AVAudioInputNode.setVoiceProcessingEnabled` | On device | `SpeechInput.swift` |
| Short local commands ("get rid of that") | Apple Intelligence `FoundationModels` | On device. Optional, with a 1.2 s timeout. | `Sources/Herm/Intelligence/OnDeviceAssist.swift` |
| Spoken replies (optional) | `AVSpeechSynthesizer`: Premium voices, Personal Voice | On device | `Sources/Herm/Voice/MacVoicePlayback.swift` |
| Composer dictation | `SFSpeechRecognizer` (system dictation) | Uses the system's dictation settings | `SpeechInput.swift` |

## Accuracy

The on-device model is good at ordinary speech. Herm's own names are the weak
spot, because they aren't dictionary words. Herm handles that in three layers:

1. **Contextual strings.** Each session primes `AnalysisContext.contextualStrings`
   with the names of your Bots and helpers, the wake name, and "Herm".
2. **Wake-only alternatives.** The wake listener accepts quieter speech and checks
   the likeliest alternatives for the full configured address, not just a name. An alternative can correct the address,
   but the command only carries forward when it matches the primary transcript.
   Otherwise, the call opens and listens for the request.
3. **Sound-alike matching for commands.** "Switch to <Bot>" matches names by a
   phonetic key (`VoicePrompts.soundKey`), so a misheard spelling still finds
   the Bot.

Settings → Voice → On-device speech input shows the recognizer and effective
language last used by the notch. Change the speech language or choose Classic
Apple Speech to compare it with Automatic. Automatic prefers SpeechTranscriber
when ready, which may resolve the Mac’s region to the closest supported variant.
Herm prepares the newer Apple model in the background, without turning the mic
on. Settings and the sidebar’s quick Voice menu show the same readiness and
retry state. These preferences do not change Hermes Agent’s transcription provider.

Herm keeps the recognizer’s corrections and withdrawals, separates consecutive
segments, and waits for the final result before sending. If recognition fails
or times out after showing a partial caption, Herm asks for a repeat without
sending the guess. A pause is measured from the most recent words or audible
speech, whichever stopped last. An attempt with no recognizable words stays listening. Brief recognition errors retry with short
delays, and another local recognizer can take over while the newer one recovers.
A temporary model download failure retries rather than disabling the newer recognizer
until restart. The microphone rebuilds its capture path after sleep or an input-device
change only if the same listener is still enabled.

## Assistant layer

These features make the notch feel like an assistant rather than a dictation
box. Each one reads real state, and Hermes Agent still does the work.

| Feature | Framework or source | Default | Code |
|---|---|---|---|
| Spoken acknowledgment | Apple Intelligence wording when available; same voice route as the reply | On, with **Acknowledge right away** | `Sources/Herm/Voice/VoiceAssistant.swift` |
| What's on screen | Accessibility (`AXUIElement`: window title, `AXDocument`, selected or visible text). `ScreenCaptureKit` window capture only for explicit screenshot requests with Screen Recording permission | Off (**Let voice see the front app**) | `App/DesktopCaptureService.swift` |
| Reminders and timers | Hermes cron (`cronjob` one-shot schedules, `cron.changed`). `UserNotifications` banner when one comes due | On whenever the agent creates one | `Voice/VoiceTimers.swift` |
| Morning briefing | `EventKit` (today's events, only if Calendar access is already granted), Apple Reminders, Hermes cron and Kanban, open approvals | On for "good morning" and "brief me" | `Voice/VoiceBriefing.swift` |
| Spoken notices with no call open | Selected local voice | Off (**Announce aloud**, needs the wake word) | `DockModel+VoiceAssistant.swift` |

- Saying just the wake phrase gets “I’m listening” when acknowledgments are enabled.
  Say a request in the same breath to go straight to the answer.
- Approval and clarification prompts can be answered aloud. The notch uses its
  voice caption for the prompt and reserves the preview for generative results.
  Say a clarification option name or “option two.” Use “choose” plus the option
  name to cut in, and join choices with “and” for multi-select questions.
  Use the conversation for approval controls or secure input.
- Ask "show a map of Tacloban City" or "show my calendar tomorrow" to see a map
  or agenda in the voice preview. Ask what finished today or what needs approval
  for a read-only work summary. Generated charts, tables, diagrams, and other
  visuals appear without the reply’s interactive parts. Say "close the preview"
  to dismiss it. A place lookup sends the requested
  name to Apple Maps, not the voice recording.
- A screen or selection request such as "summarize this page" or "reply to the
  selected email" can share front-app text. Text capture skips secure fields and
  known password managers. Say "attach a screenshot of this window" to share an
  image when Screen Recording is already allowed. A chip shows what was shared.
- Hermes doesn't deliver a job created from a TUI session back to that session.
  Herm schedules a macOS notification once it sees a confirmed deadline.
  The system can deliver the banner while Herm is closed. Herm reconciles the
  countdown when the Mac wakes and can speak the reminder with **Announce aloud**.
  Cancel deletes the Hermes job.
- A briefing source Herm can't read is reported as "not connected" or "not
  loaded", never as "nothing today".
- Spoken notices follow Herm's Quiet mode, not macOS Focus, because Herm
  doesn't have the Focus status entitlement. They stay silent while the screen
  is locked.

## What Herm deliberately doesn't do

- It doesn't send audio to a server for Talk mode, and it doesn't fall back to
  server recognition when on-device recognition is unavailable. The notch shows
  why voice paused and offers **Try again**.
- It doesn't use Apple Intelligence to rewrite what you said before sending.
  That would add a model round-trip to every turn, and it could change your
  meaning. Apple Intelligence only decides whether a short phrase is a local
  panel command.

## Choose a voice

In **Settings → Voice**, choose **Apple Speech** for on-device chat replies and
local answers. Choose an installed **Apple voice** or leave it on **Automatic**.
macOS offers additional voices through **System Settings → Accessibility**.
Use **Preview** to hear a sample and **Speaking speed** to adjust its pacing.

Choose **Kokoro** on Apple silicon for another set of offline English voices.
Install [uv](https://docs.astral.sh/uv/getting-started/installation/) if Herm
shows **Get uv**, then select **Install Kokoro**. Herm sets up a private Python
environment and downloads a quantized model and voice presets. The model files
total about 120 MB. The [Kokoro model](https://huggingface.co/hexgrad/Kokoro-82M)
and [ONNX runtime wrapper](https://github.com/thewh1teagle/kokoro-onnx) are published
under Apache 2.0 and MIT respectively. After setup, **Kokoro voice** lets you
audition and select a preset. Herm uses Apple Speech while Kokoro is unavailable
or when it detects another language. After an interruption, Kokoro has a short window
to finish its current clip. If it stalls, Herm restarts the worker for queued audio.

If **Conversation voice** is **Hermes Agent**, the backend speaks chat replies
and your Apple voice speaks local answers, confirmations, and notices.

## Configure Mail and Messages shortcuts

Create a shortcut in macOS Shortcuts for each channel you want to enable. Its
file input is UTF-8 JSON. Add **Get Text from Input** followed by **Get
Dictionary from Input**, then read these fields.

| Key | Value |
|---|---|
| version | Integer 1 |
| channel | mail or messages |
| recipient | One resolved email address or phone number |
| subject | Optional Mail subject |
| body | The message Herm read back |

Use the recipient and body from that dictionary in **Send Email** or **Send
Message**. Set the sender or account in Shortcuts. After the send action
returns, use **Stop and Output** to return the text **submitted**. That output
tells Herm the shortcut reported submission. If a shortcut times out or
returns a different result, check Mail or Messages before trying again.

In Herm, open **Settings → Voice**, select **Refresh Shortcuts**, and choose
each sending shortcut. If you prefer to speak names, select **Connect
Contacts**. A draft stays in the current voice call. Herm invokes the
selected shortcut after it finishes reading the recipient, subject, and message
as entered and hears “send it”. If the readback is interrupted or muted, turn on
voice replies and ask to send the message again.
