# Herm

[![CI](https://github.com/chryzxc/herm/actions/workflows/ci.yml/badge.svg)](https://github.com/chryzxc/herm/actions/workflows/ci.yml)
[![platform: macOS 14+](https://img.shields.io/badge/platform-macOS%2014%2B-1f6feb)](#requirements)
[![Swift 6](https://img.shields.io/badge/Swift-6-F05138)](#development)
[![local-first](https://img.shields.io/badge/local-first-f0883e)](#how-it-works)
[![License: MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)

**A native macOS companion for [Hermes Agent](https://github.com/NousResearch/hermes-agent), always within reach.**

*Named after the herms, the markers of Hermes that stood at doorways and crossroads, always in view and always within reach.*

Glance at the notch to see what your agents are doing and how much provider allowance remains. Send a quick message without opening the workspace, reply to a specific session when it is idle, or talk with your agent through continuous **Voice mode**. Expand into the full workspace when you want to inspect files, review changes, answer an approval, or manage your bots and tasks.

> **Ask from anywhere → keep working → notice when needed → respond quickly → inspect the result.**

Herm is a **frontend for Hermes**. It doesn't run models, keep its own copy of your sessions, or replace the Hermes CLI. It connects to the Hermes runtime already installed on your Mac and gives it a native interface. It's an unofficial community project, separate from the official Hermes Agent Desktop app ([more](#disclaimer)).

```sh
git clone https://github.com/chryzxc/herm.git
cd herm
swift run
```

---

> [!IMPORTANT]
> **Herm doesn't yet do everything Hermes Agent can.** It includes a subset of Hermes features, and each one only turns on when the installed Hermes version supports it. Hermes Agent moves fast, so Herm will keep adding features over time. If something works in the Hermes CLI but doesn't appear here yet, it probably hasn't been added. See [Current limitations](#current-limitations) for the full list, and feel free to open an issue.

---

## Table of contents

- [Why Herm](#why-herm)
- [The notch](#the-notch)
- [Features](#features)
- [Requirements](#requirements)
- [Getting started](#getting-started)
- [How it works](#how-it-works)
- [Privacy](#privacy)
- [Current limitations](#current-limitations)
- [Development](#development)
- [Contributing](#contributing)
- [FAQ](#faq)
- [License](#license)

## Why Herm

Herm is built around a simple idea: **keep your agents within reach without making their workspace your workspace.** Start work, return to your editor or another app, and use the notch to check progress, quota, and requests for your attention. Open the full workspace when the work needs a closer look—not just to watch a conversation scroll.

It is not intended to reproduce every page or feature in Hermes Agent Desktop. Herm selectively brings useful Hermes capabilities into a **SwiftUI and AppKit interface designed for macOS**, with the notch as its everyday entry point.

### What makes the Herm experience different

| Experience | What Herm offers today |
|---|---|
| **Ambient agent awareness** | An edge notch with session activity, Kanban updates, requests for your attention, and finished results you haven't opened. |
| **Quota at a glance** | A notch preview for supported providers' allowance and reset times, without opening a dashboard. |
| **Quick interaction** | Start a new chat or reply to a specific session from the notch without changing the conversation selected in the workspace. |
| **Real-time spoken conversation** | Continuous Voice mode with spoken replies, interruptions and steering, captions, and a native voice stage with live activity. |
| **Inspect and give feedback** | Preview files in-app, annotate selected text, send revision notes back to the originating session, and inspect local Git diffs. |
| **A view of your agent team** | Profile-based bots, real Hermes Kanban boards, a map of agent handoffs, and a 3D Office Preview driven by task status. |
| **Review alongside the work** | Repository checks and coverage information, changed-file diffs. These are aids for inspection, not a guarantee that the agent's work is correct. |
| **Act without opening the app** | Approve, deny, or reply from notification banners (optionally behind Touch ID), send selected text from any app via the Services menu, and trigger Ask Herm from Shortcuts. |
| **A native Mac companion** | Global keyboard access, system appearance and popover materials, Reduce Motion support, and an optional Hermes pet that can roam from the notch. |

These are highlights of Herm's experience, not a list of features exclusive to Herm. Hermes Agent Desktop shares many underlying capabilities, including voice mode. The distinction is how Herm brings them together around ambient awareness, quick interaction, spoken conversation, and local inspection.

The design priorities are **useful attention rather than constant activity**, **clear status rather than assumed success**, and **keeping quick actions tied to the right session**. Future improvements should strengthen those qualities rather than add features for parity alone.

Actions use visible buttons, including compact buttons in dense panes. Inline
navigation and Show more links stay underlined before hover, and linked GitHub
metadata carries a navigation arrow so it is distinct from static metadata.
Workspace pages share Calendar’s top titlebar treatment, with sidebar toggles aligned
beside the traffic lights. Chat uses three full-height panes: the session list,
conversation, and inspector. The session title and Chat/Talk controls stay inside
the conversation pane; the inspector's tabs extend to the top of its own pane.
Navigation distinguishes Chats (speech bubbles), Messaging (paper plane), and
Artifacts (stacked files), while keeping the Bots ghost icon. Chats shows a small
spinner for running sessions and a count of completed chats with unread updates
for the selected bot. Both appear together when work is running and results await
review; opening a completed chat clears its unread badge. Badge calculations are
cached independently of transcript updates; status polling pauses while the
workspace is hidden or Hermes is disconnected.
Contributors should follow the shared treatments in [DESIGN.md](DESIGN.md).

Chat keeps unsent text, attachments, context, and reply quotes with each session
while Herm is open. Switch sessions, pages, or bots and return to continue your
draft. Drafts are separate for each bot/profile and are cleared when Herm quits.
Drafts are saved during navigation; typing continues to update only the composer.

## The notch

The notch is the main way to use Herm. It sits against the left or right edge of your screen, stays out of the way while nothing is happening, and shows you when Hermes needs attention.

### Hermes companion

Herm displays the selected profile's enabled Hermes pet just below the notch, outside its contour. Its
poses follow task activity: hover over it for a greeting or
click to pet it, without opening the notch. It stays below the expanded preview,
with an occasional celebration after successful work. Hover the notch itself
for status and Quick Message. The pet uses the same assets and selection as Hermes
Desktop and the TUI. All pet surfaces use the same renderer, with Hermes' row
order mapped to native image coordinates so animation does not cycle through
another row's blank padding.

In **Settings → Appearance → Hermes companion**, choose a pet from
the always-visible **Select a pet** gallery, enable or disable it, and adjust its Hermes size.
**Apply to Hermes** confirms the shared change; Hermes handles any download.
After **Apply to Hermes**, the floating pet uses the saved size (100% is the
sprite's native frame size). Its window and roaming bounds resize with it;
the Settings thumbnail remains compact. Oversized pets fit within the display.
Notch announcements, including quota changes, share a centralized pet-reaction
mapping; hovering and petting remain short-lived interactions.
This requires Hermes' `pet.*` gateway methods. Older runtimes keep the ordinary
notch and show companion availability guidance in Settings. Reduced Motion
displays a static sprite.

Enable **Roam from the notch** in the companion settings for walks across
the current display's bottom edge with directional animation, pauses, and periodic
returns home. Task activity and hovering pause movement; drag repositions it.
Right-click the notch or pet and choose **Call pet home** to return it. Roaming
is local to Herm, defaults off, and is disabled by Reduce Motion.

### What the notch shows

The notch changes to reflect what Hermes is doing, so you don't have to keep a terminal open:

| State | What you see |
|---|---|
| **Idle** | A thin, quiet rail on the screen edge. |
| **Working** | A live indicator while Hermes is running a turn, a tool, or a background task. |
| **Needs you** | An attention state when Hermes is waiting for an approval (for example, a dangerous command) or has asked you a clarifying question. |
| **Finished** | A short announcement when a task completes, which stays marked until you open the result. |
| **Offline** | A clear indicator when the local Hermes runtime isn't reachable. |

The Tasks preview opens on **Activity** by default. Its list/grid toggle switches between session activity and **Kanban** cards, using the same controls as Quota. Both views use Herm’s compact status cards. Kanban shows running, blocked, and review cards across boards. Confirmed card moves and edits automatically expand the Kanban preview without changing your selected view; click a card to open its board and inspector. Kanban refreshes every five seconds while the workspace is closed. The initial load stays quiet, and unchanged or failed refreshes do not announce. Up to 30 recent card updates remain until opened; active cards stay visible.

The Activity preview separates **Needs your attention**, **In progress**, and **Finished, not opened**. Approval requests and clarification questions show their own status and a short summary, including requests from other sessions. New requests open the preview; select the row to review and respond in the workspace.

Activity rows in the side notch and top island have no background fill at rest, including the current session.

Conversation approvals, clarification choices, and secret/login requests share a compact neutral card with explicit status, labeled inputs, and grouped actions that stack in narrow panes. Multi-select answers show their selected state; submitting keeps an in-place progress indicator and disables duplicate responses.

Choose **Quick message** in either Tasks view to start a new session without opening the workspace. Hover a session row to slide **Reply** into view and compose directly beneath it; hidden buttons leave no empty slot. Reply stays visible while composing or navigating with the keyboard, and the reveal respects Reduce Motion. Replies stay tied to that session, and neither action changes the workspace’s selected chat. The compact composer keeps its own draft, preserves workspace attachments, and stays open while typing; **Back** or Escape leaves it. Failed sends keep the text for retry. Kanban rows show the assigned bot’s stored avatar or its existing fallback identity.

Choose a finished session row to peek at its **Latest completed reply** inside the notch. Copy an excerpt, open or reveal generated files, reply to that session, or open it in the workspace. Reading leaves the selected workspace chat alone. A deliberate selection marks the matching completion reviewed after its content loads; hovering does not. New results offer **Update** while the displayed excerpt remains stable.

The notch shortcut opens keyboard interaction: arrows select a session and Return inspects it;
Escape backs out and then dismisses. **More → Saved actions** prepares editable starter or custom
instructions without sending. **Working sets → Checkpoint** saves a note and exact quick-draft
reference for later resumption. **Watch activity** focuses ordinary session activity on one set;
blocking decisions and failures remain visible globally. Result Peek's **Compare with previous
read** compares two deliberately loaded snapshots, including changed output references.

The quick composer accepts dropped files and links, pasted text and images, and an explicitly chosen project for a new session. Its **To** picker captures the profile and session before sending. **Drafts** restores unsent content after a restart; missing or changed files remain visible. Images, one PDF up to 25 MB, and generic files use Hermes' attachment methods when supported. Interrupted or uncertain submissions require reviewing the destination session before resending.

Choose **Quiet** in the Tasks header for 30 minutes, 60 minutes, or until you end it. Completions, ordinary quota changes, and informational updates enter a digest. Approvals, questions, and failures that stop work can still interrupt. The same policy controls notch announcements, pet announcement reactions, and opted-in system notifications. **Review digest** returns to the recorded sources; it stores references rather than response bodies.

Quick approval and clarification answers stay tied to their original request, session, and profile. A pending answer blocks repeated clicks. A confirmed refusal offers **Retry**; an uncertain acknowledgment offers **Check request**, which enables another answer only after Hermes confirms that request is still pending. These answers preserve the workspace draft and attachments.


The composer’s **@** picker shows each bot’s description beside its handle when available. Hover or click the context gauge to see usage, the estimated category breakdown, and the runtime’s compaction threshold with remaining tokens in a popover, without a separate hover tooltip. Older runtimes show when the threshold is unavailable.

Centered bot dispatch pills have vertical spacing above and below to separate them from conversation activity rows.

Session list spinners follow Hermes’ live execution state and refresh every ten seconds while the sidebar is visible, including unopened sessions for the selected bot. Recent writes alone do not indicate running work; the next live refresh clears missed completion events.

The status colors match the rest of the app: blue means active, green means healthy or done, amber means a warning or that Hermes needs you, and red means a failure.

Global hover tooltips show one floating, fully opaque, theme-aware panel beside the hovered control and above workspace content and scroll containers. Long help wraps, stays within the display, and never takes keyboard focus.

Chat message timestamps appear on hover, with no separator after the assistant message actions.

### How to use it

Session and group-chat lists, project pickers, inspector tabs, approval details,
usage labels, shared inputs, and the chat composer follow the window text scale. Markdown headings
and fenced code resize with reply prose.

Standard UI and conversation font sizes live in `DockTypography`; SwiftUI views
and native Markdown/composer text share these definitions.

Window mode uses standard 100% sizing for fonts, icons, and action
controls: 12pt body text, 13pt navigation labels, and 14pt conversation text. Text renders at its final size, with normal pointer and selection
coordinates on Retina and standard-resolution screens.

| Action | Result |
|---|---|
| **Hover** | Opens a preview with two tabs. |
| **Tasks tab** | Lists every session that's in progress, with the ones that need you first, plus finished results you haven't opened yet. Click one to go straight to it. |
| **Quota tab** | Shows provider usage and reset times, so you know how much allowance is left before starting a long task. A compact **Open Quota** button opens the full quota workspace. |
| **Click** | Expands the notch into the full workspace in the same window. |
| **Double-tap ⌘** | Opens or closes the workspace from anywhere. |
| **Double-tap ⌥** | Opens or closes the hover preview from the keyboard. |
| **⌥ Space** | Quick capture: opens a new message in the notch from any app. Change it to ⌃ Space or turn it off in Settings → Notifications → Keyboard shortcuts. If nothing happens, another app is using the chord. |
| **Drag** | Moves the notch along either screen edge. Its position is saved. |
| **Right-click** | Moves the notch to the left or right edge, or quits the app. |

A typical workflow: start a long task in chat, collapse the workspace, and keep working. When the notch turns amber, hover over it to see which session needs approval, click that session, approve, and collapse again. When the task finishes, the notch tells you.

Choose **Dots**, **Vertical line**, or **Ring** in **Settings → Appearance → Notch**. The selection applies immediately and is saved across launches. The vertical line sweeps while work runs; the ring rotates. All notch animations respect **Reduce Motion**.

## Features

Expandable detail sections toggle when you click anywhere in their header row, including the label and empty space beside it.

### Generated replies

**Settings → Appearance → Generative UI** is on by default and applies immediately.
Hermes can return native tables, charts, sources, galleries, and forms when they help;
simple replies remain Markdown. Turning the setting off shows readable text and stops
requesting visual formatting. Interactive HTML requires **Open interactive view** and
runs in a separate offline sandbox with no tools, credentials, files, or network access.

See [visual reply formats and isolation](docs/generative-ui.md).

Workspace page headers use consistent text titles and subtitles, with refresh
and other actions on the right. Buttons share 12pt themed labels, hover and
pressed feedback, and disabled states. Primary actions use a quiet accent tint;
secondary actions use the shared outlined or compact treatment. The pull request
Merge action uses matching icon and label ink on every skin, including filled
Storm and Glass controls. PR toolbar actions use compact sizing for a tighter row.
Merge uses a shared split button in the toolbar and merge panel: choose an available
merge commit, squash, or rebase method, then confirm the selected action. The dropdown
also opens merge requirements; repository rules and expected-head checks still apply.
Workspace pages, including Settings, use a flat theme canvas without a corner glow.

The default **Glass** appearance follows macOS Light/Dark with frosted panels
and cool crystal surfaces, with a single native glass background to keep broad
reflections off the chat reading surface. **macOS** keeps native popover blur and graphite
chrome; **Clean** uses quiet porcelain surfaces. System-following skins update
automatically when macOS switches between Light and Dark, including while the
workspace is open. Skin changes also apply to the side notch and its open preview.

Choose from the skin gallery in **Settings → Appearance**. Every tile previews
its own typography, material, geometry, and selection treatment. Switching skins
keeps the Appearance page selected while the new skin applies immediately. The gallery
reflows into fewer columns in narrow windows, keeping previews inside their cards. The 21 skins
range from Hermes' desktop look (Nous blue with the etched backdrop from Hermes
desktop) and Ares' oxblood panels to folded
Origami, ruled Notebook, molded Clay, and silver-beveled Retro. Terminal has
phosphor scanlines, Pixel has stepped arcade outlines, HUD has cyan
crosshairs, and Storm has Tokyo Night indigo with neon rain. Navigation and composers follow the selected skin while keeping
the workspace layout and controls in place. Each skin also moves in its own
way: Hermes snaps like its desktop app, instrument skins move crisply, Cartoon
and Clay spring, and Glass, Dusk, Storm, and Island settle softly. E-Ink,
Pixel, and Retro remain motion-free; other skins respect Reduce Motion.

### Conversations

The header shows compact labelled Chat, Talk, and repository PRs tabs. The selected tab has a themed fill or marker, semibold label, and persistent underline. Opening the inspector in the floating desktop panel keeps the conversation visible beside it. The three panes default to roughly 25% list, 40% conversation, and 35% inspector, with adjustable dividers and minimum readable widths.

Discord sessions show a compact tinted pill with the Discord icon beside the preview. Other session sources omit the origin pill.

- **Streaming chat** with Markdown (including tables with optional outer pipes and table text sized to match reply prose), images, tool output, and inline clarification requests. Response text reflows at the current pane width, keeping its action rail beneath the content when resizing.
- **Website links** show an inline favicon beside their underlined label. GitHub links use a bundled, theme-aware mark; bare PR and issue URLs display as `PR #123` or `Issue #123`. Other public sites load `/favicon.ico` over HTTPS with a globe fallback.
- **Working bot**: a larger, borderless 40pt avatar reacts to activity with reaches, tilts, and hops, including a soft landing and the current activity icon. Rapid updates blend smoothly, and new activity rows appear immediately. Reduce Motion and motion-free themes keep it still.
- **Running activity** keeps duration text free of shimmer while elapsed time continues updating, with a separate live-work sweep that pauses when Herm loses focus and stays still under Reduce Motion or motion-free themes. Running and completed tool durations align at the right end of each chat activity row.
- **Transcript scrolling** follows new output only while you are at the bottom. Scrolling up keeps your reading position through streamed replies, new questions, and transcript refreshes; return to the bottom or choose Jump to latest to resume following. Completed assistant replies of every length create nearby text sections as needed while preserving their full height and selected text. History paging reveals eight messages at a time and preserves ongoing scroll movement instead of restoring an earlier offset. Replies with tool activity and hidden entries also continue loading older pages. A session-scoped coordinator owns paging and navigation; unrelated workspace refreshes leave transcript snapshots unchanged. Activity in other sessions and streaming activity outside the mounted history window also leave the visible transcript unchanged; returning to the live reply shows its current activity. Nearby completed Markdown is parsed ahead of paging, and bounded in-memory height measurements survive row remounts. Long streaming replies reuse stable Markdown sections and prepare only changed chunks. Navigator history is reused across activity updates, and ordinary Markdown streaming avoids restarting visual-reply parsing tasks. Activity updates reach only the message owning the relevant bot dispatch. During manual scrolling, live replies defer text reflow and show the latest received text when scrolling settles. Jump to latest respects Reduce Motion.
- **Steering during a turn**: guidance you type while Hermes is working is added to the running turn at the next tool boundary.
- **Queued messages**: when the current conversation has queued messages, every subsequent send joins the end of that queue, including plain text during a running turn. New submissions also wait behind a redirect still awaiting Hermes' reply. During a turn, text and attachments queue together. Submitting clears the composer immediately while preserving images, PDFs, context, and reply quotes with the message.
- **Attachments**: files, pasted images, URLs, prompt snippets, several images at once, or a single PDF up to 25 MB. Drop Markdown, text, source, and other files into the composer as removable attachments (up to 8 MB each); uploads require Hermes protected file attachment support. **Files** and **Images** open a native attachment picker; **Folder** opens a directory picker and inserts its path into the draft.
- **Message actions**: branch from a message, copy it, have it read aloud, or refresh it from Hermes.
- **Bot replies** expand beneath their activity pill into padded cards with vertical breathing room and fully selectable text.
- **Pinned conversations** use Hermes' own pin, so pins are shared with Hermes Agent Desktop and `hermes sessions pin`.
- **Pinned messages**: pin or unpin saved user and assistant messages, then use the header's pin button to jump to them. Pins live in Hermes, survive compression, and stay separate for each profile and branch. Requires the message-pins backend patch in [docs/message-pins.md](docs/message-pins.md); stock runtimes show an unavailable notice.
- **Model picker** grouped by provider, with search. **Edit available models… → Unselect All** hides every model except the active one; selections are saved locally.
- **Mixture of Agents**: Settings → Runtime edits Hermes' MoA presets (reference models, aggregator, enabled). Enabled presets appear in model pickers as `MoA · <preset>`; while a MoA turn runs, advisor output, fan-out progress and the aggregating phase stream into the thinking block. Settings → Runtime also sets the default thinking level for new sessions.
- **Context guardrails**: the composer shows context progress without a session token total. Its percentage measures the full context window; Hermes can compact earlier based on its configured token limit or other runtime triggers. During compaction, the composer shows **Compacting**, including during streaming turns, and refreshes usage afterward. Context usage is labelled normal, warning (80%), or critical (90%), with actions to branch, compress, or hand off.
- **Dangerous-command approvals**: *Deny*, *Allow once*, or *Always allow*. *Always allow* is saved to the Hermes allowlist.

### Voice mode: continuous spoken conversation

Voice mode is more than a microphone button for dictating a prompt. Speak with your agent, hear its replies, and continue the conversation without typing each turn.

- **Continuous conversation** with local speech recognition, voice activity detection, and Hermes-configured speech synthesis. Local recognition starts without waiting for backend recorder checks; Hermes' session recorder is used when local transcription is unavailable. Recognized requests submit after speech stops, including in a noisy room.
- Voice belongs only to the session where you activate it. Switching conversations or leaving Voice mode stops capture and playback, including delayed audio that finishes synthesizing afterward. Spoken requests and reply voices stay with that conversation's Bot profile. Playback returns to listening when its audio finishes; failed requests or playback pause Voice mode and show the error in chat.
- **Spoken interruption and steering**: speak over a reply to interrupt it, or give additional guidance while Hermes is working. The orb also lets you send an utterance immediately, interrupt, or resume listening.
- **A native voice stage** with an audio-reactive orb (Bots wearing a Herm face appear live at its core only when Hermes reports the `hermes-bots` plugin enabled; uploaded or generated avatars keep the plain orb), listening/thinking/speaking states, centered spoken-reply captions, tool activity cards, and subagent indicators. Immersive mode gives the conversation the workspace while keeping live work visible. Activity chips stay in separate, spaced columns and make room for tool cards.
- **Spoken approvals and clarifications** when on-device recognition is available. Requests remain visible, and spoken answers go to the pending request rather than becoming a new prompt. Permanent **Always allow** approvals still require the on-screen control.
- **Follow-up and wake behavior**: with on-device recognition, a quiet follow-up window can pause into wake-phrase listening. Say `Hey <agent name>` to resume; this applies while Voice mode is active, not as a system-wide wake listener.
- **Separate microphone and spoken-reply controls**, so you can mute input or turn off spoken replies.
- **Playback-aligned captions** show the same short segment sent to speech synthesis when its audio starts. Captions stay centered and wait during synthesis, rather than advancing on a reading-speed timer.
- **Live dictation** updates the composer as words are recognized, including corrections, without sending the draft. Recognition warnings offer Retry and Dismiss, clear on a new capture or session change, and keep any successfully recognized words.
- **Clearly labeled fallback** to macOS speech when Hermes voice support or dependencies are unavailable. The fallback is not a promise of the same continuous experience.

Voice mode requires microphone access; on-device recognition also requires macOS speech-recognition permission. Transcription and speech output depend on the installed Hermes runtime and its configured voice services. “Real-time” here describes the interactive spoken experience, not a claim of a provider-independent, full-duplex speech-to-speech transport.

Hermes Agent Desktop [also documents voice mode](https://hermes-agent.nousresearch.com/docs/user-guide/desktop). Herm's emphasis is its native voice stage and its integration with the rest of the agent workspace, not an exclusive claim to voice support.

The notch also offers **Recall** for profile-scoped conversation search, **saved working sets**
for explicit destinations, and **session capacity actions** with acknowledged model changes.
Result Peek includes explicitly pinned sources, quoted corrections, Markdown export, and coding
review. Clean turn baselines enable scoped diffs; **New task in worktree** creates an isolated
Git directory and verifies Hermes' session directory before you send the recovered draft.

Failed or pinned routines open a compact recovery view with execution and delivery shown
separately. Supported Pause, Resume and Run now actions retain the owning profile. Skills & MCP
repair uses Hermes' own installation, credential and OAuth paths. Targeted subagent steering
labels queued corrections honestly; fingerprinted memory entries can be inspected and corrected.
Each operation remains unavailable when its installed-runtime contract cannot be verified.

Quick message uses a shared composer surface, a destination picker beside its title,
and a compact quota advisory above the fixed send footer. Inline quick reply keeps
the task title once, groups Attach, Paste, More, and Send inside the editor, and
places a short quota notice beneath it. Replies stay tied to the task's session.
More offers window capture, saved drafts when available, and discard; review and
retry appear for interrupted sends. Project choices appear only for new sessions.
Hover Send for the keyboard shortcut or the quota notice for its update time.

### Pull requests

- The pull request detail uses a ChatGPT-inspired open reading layout: Summary, Changes with line totals, and Reviews tabs; description and activity in the main column; and changes, reviewers, checks, readiness, and metadata on the right. Narrow panes stack the columns. The header first compacts into one row, then uses left-aligned tabs above compact actions at phone-like widths, keeping every action available. Compact tabs omit line totals, which remain in the summary. Expand Changes for file categories and partial-coverage notices. The Merge dropdown opens protected landing controls from the toolbar.
- A floating bottom-right **Chat** panel asks Hermes about the current PR, includes its context, and shows replies without switching the selected workspace conversation. Each PR has its own conversation using the default bot profile. Minimize the chat to a compact composer with centered controls; open its full conversation for approvals or clarification. Failed messages keep their draft, and uncertain deliveries require review before retrying.
- Pull request rows separate repository, title, branch, and status, with a visible selection marker. Blue open states, amber drafts/blockers, violet merges, and teal reviewer context adapt to the active theme; Monochrome and E-Ink retain neutral ink. Summary status controls include state icons, and description text keeps a readable line width.

- PR summaries use a violet branch-route icon and baseline-aligned reviewer and conflict-warning icons.
- Open pull requests for the session's repository, with check status, review state, blockers, and deep links. The **Merged** filter includes the repository's merged PRs from the last 14 days, including PRs by other contributors; unavailable merged history is reported without hiding open PRs.
- The session header shows Pull Requests only when the session is connected to a project or repository.
- Pull request filters adapt to narrow panes with a compact selection menu; session search stays in the full-width first row, matching the Issues layout.
- Pull request and issue headers provide one GitHub open button; the actions menu keeps editing and Copy link.
- Summary, Changes, and Reviews tabs keep their full clickable area when the detail header shares the window title row.
- Reviews groups thread filters and feedback in clear sections, with an editor prompt, Markdown preview, and character limit.
- Newly opened diff files start at the left edge, with source visible beside the line-number gutter.
- GitHub Details matches the shared content-section title style used by Description, Checks, and Activity.
- Diff toolbars use a grouped layout switch and compact icon actions, with a visible wrap state and loading spinner for additional context.
- Every expanded page (Timeline, file diffs, local and observed reviews, pull request code review) shares one header that stays clear of the window controls, with Close and Esc to return. The pull request inspector’s Changes tab has an Expand button for full-window review.
- Expanded reviews show explicit Unified/Split choices, and use the full width for added or deleted files.
- Review-option menus align labels to the left and show checked or unchecked boxes on the right.
- The Code toolbar uses an ellipsis menu for review actions, including watching a pull request and generating a review guide.
- The Pull requests page loads its list first, then fetches branch, check, and review details as rows come into view.
- Create draft pull requests and edit a pull request's title or body, with a confirmation step.
- Shared metadata uses wrapping pills for assigned labels, assignees, projects, milestones, and Development links. Labels, Projects V2 membership/Status, Milestone, assignees, and Development editors prepare changes locally and confirm before saving. Restricted Projects do not hide other details.
- Readiness keeps state, check, review, and merge facts in the summary side column. The Merge toolbar dropdown opens requirements and landing controls; narrow panes stack the sections. Freshness stays in the header and conflict-recovery actions wrap below the facts. It keeps checks, reviews, drafts, and conflicts separate. PR status and metadata pills use regular-weight text consistently. Network actions show compact pending feedback, prevent duplicate submissions, and apply confirmed lifecycle changes immediately. Successful merges update shared PR state from GitHub’s write response and offer confirmed remote branch cleanup without changing local branches. **Analyze conflict files** appears only for open PRs with confirmed conflicts and known revisions, and uses an isolated temporary repository; **Prepare resolution in Hermes** fills chat context without submitting it.
- Activity and discussion entries show the author’s GitHub avatar when available.
- Discussion, review bodies, inline threads, replies, thread resolution, approval, and request-changes use the common Markdown renderer. Changed lines have line numbers and a context-menu comment action.
- GitHub recovery links in readiness and landing use compact themed buttons with an external-link icon.
- GitHub detail metadata uses compact label/value rows, with wrapping pills and section-specific recovery actions. Merge method and landing actions share a wrapping control row.
- Landing controls show merge blockers inline, including missing reviews, failing/pending checks, conflicts, permissions, and branch updates. They use repository-supported methods, current permissions, confirmation, and expected-head protection. Auto-merge and queue requests display waiting/queued states separately from merged.
- **Not supported:** force-pushing, dispatching workflows, or a native conflict editor.

### GitHub issues

- PR and Issues headers share compact action spacing and keep window dragging clear of controls. The Issues repository filter uses the themed menu.
- Header icon actions share a 28pt footprint; section refresh/edit actions use 24pt with no extra button-style padding.
- PRs and Issues use compact New, refresh, recovery, landing, and inline discussion actions.
- Switching Open, Closed, or History shows an in-place loading spinner; Issues shows loading rows while a new scope loads, retaining prior results if it fails.
- PRs and Issues share a compact view-options menu with checked sort choices and separate save/restore actions.
- A separate **Issues** module with My work and explicit repository scopes, open/closed/history views, metadata filters, sorting, and saved presentation preferences. Authored and assigned lists load in parallel; pagination reports incomplete coverage.
- Create or edit issues, manage assignment and metadata, comment, close as completed/not planned, and reopen with confirmation. Descriptions, comments, and editor previews use the same native Markdown pipeline as chat.
- Development links navigate between Issues and Pull requests. Descriptions and selected discussion entries can be attached to Hermes chats.
- Lists and selected details refresh every 60 seconds while the page is active; errors pause automatic retry. Last successful content and per-item comment drafts are retained.

Issues uses the same themed overview and selection markers as Pull requests.
Open issues use blue, closed issues violet, and assignments teal. List status icons
are unfilled, with neutral state text; the detail header keeps one tinted state badge. Description
comes before Details, with readable line lengths and a collapsible section.
Conversation events share one divided group, and the comment editor includes
Write/Preview tabs, an empty-preview message, a visible prompt, and a separate
submit row. Repository filters wrap below issue tabs in narrow lists.

See [GitHub workspace behavior and validation](docs/github-workspace.md) and the [pull request page audit](docs/pull-request-page-audit.md).

### Developer tools

- **Task plan above the composer**: a compact progress ring and count expand into readable steps, with an emphasized current step and completion marks. The current step spins while the turn is working, including after reopening the task details. Progress, step changes, and disclosure animate briefly; Reduce Motion and motion-free themes keep them still.
- **Explorer**: a repository browser with blame information. Project chats use their assigned folder immediately, even before the project list refreshes.
- **Source Control** stays available in the inspector and its + menu while Git state loads or refreshes.
- **Source Control / Changes**: compact Staged Changes and Changes lists with icon-led section titles and a 12pt left inset for section contents (including Graph), hover-revealed per-file stage/unstage toggles, group stage/unstage actions, VS Code–style right-click menus (Open Changes, Open File, Stage/Unstage, Discard Changes with confirmation — untracked files go to the Trash, staged content is kept — Add to .gitignore, Copy Path, Reveal in Finder; group headers offer Stage/Unstage/Discard All), read-only diffs, and a commit message field (⌘Return commits staged changes only). A collapsible **Stash** section saves staged and working-tree changes with an optional message and untracked files, previews saved diffs, and offers Apply, Pop, and confirmed Delete. Apply and Pop restore staged state; failed restoration keeps the stash. Stashes are shared across repository worktrees. A collapsible **Graph** section draws the latest 50 commits of the branch and its upstream as colored lanes with branch, remote, and tag pills; expanding a commit shows its full message, author email, parents, and changed files with line counts, plus Copy hash and Open on GitHub. Graph header actions fetch all remotes, pull (fast-forward only), and push to the upstream; Git credential prompts fail fast instead of hanging. Local review also checks added lines for conflict markers, likely credentials, and debug statements; credential values are never shown.
- **Terminal**: a native terminal in the session's project folder, with history, Tab completion, and optional repository checks.
- **Repository review**: reviews the whole repository locally and tells you what it didn't cover. Optional repository watching never starts Hermes work on its own.
- **⌘K command palette** for app actions and Inbox filters.

### File previews and revision notes

- Chat file rows keep the filename and status on the left, with Download, Open preview, and available Open diff actions on the right.
- Preview **Markdown, text/code, and images** inside Herm. Unsupported file types open in their default app.
- Select text in a document to add a quoted review note, or add a general note. Notes are saved locally and remain highlighted in the preview.
- Send draft notes as one **revision request to the session the preview came from**, rather than manually copying excerpts into a different conversation.
- Inspect changes against the file contents saved when notes were sent. A removed quote can be marked addressed; that is a matching heuristic, not proof that the requested revision is correct.
- Use **Open diff** on chat file attachments with local Git changes to open a dedicated **Diff** tab in the third panel. It shows current staged and working-tree changes separately, or the added contents of a new file, from the attachment's own worktree. **Open preview** remains available for the file itself. These are current Git changes, which may include edits beyond the AI response. Source Control keeps its inline file previews. Both use the shared diff viewer, which wraps long lines by default without horizontal scrolling.

### Built-in browser

The session inspector's **Browser** tab is a real Chromium browser that you and Hermes share, so you can watch it work.

- **Hermes browses here.** Herm starts a background Chrome (or Brave, Edge or Chromium) and connects Hermes' browser tools to it. When Hermes uses the browser, the tab comes forward and a status pill shows its current step.
- **Take over and hand back.** **Take over** pauses Hermes so you can handle a login or captcha yourself. **Hand back to Hermes** then tells it to continue from that page. While Hermes is working, your clicks and typing are ignored so they can't interfere with it.
- **Page dialogs** (alerts, confirmations, prompts, "Leave this page?") appear as a card in the panel, so a page can't stay frozen waiting for an answer. If Hermes answers a dialog itself, the card closes.
- **Annotate** (cursor icon): click any element, describe the change, and Herm sends the element's selector, styles, HTML and a screenshot to the chat. The popup uses your Herm theme.
- **Session browsers stay open.** Switching sessions or closing the inspector keeps each session's live pages, history, and form state without reloading. Each session and bot profile has its own browser data; extra browser tabs share only that session's data.
- **Links in chat** open their exact destination in that session's Browser tab, including while the browser is starting.
- **Navigation feedback.** A spinner and slim loading track appear while pages load; Reload becomes Stop. Failed navigation offers Retry without shifting the page. Back and Forward reflect the active page’s history.
- **Responsive browser controls.** The toolbar keeps navigation and the address on one row when space permits; phone-width panels give the address its own full-width row. **Auto** follows the panel’s live width without reloading the page. Phone, Tablet, and Desktop keep a fixed preview width. Annotation is also available in More; Local Previews is removed from Browser. Use ⌘L for the address and ⌘R to reload. Local addresses such as `localhost:5173` open directly; the actions menu includes Copy Address and Open in Default Browser.
- **Offline notice.** If the agent browser can't start or keeps closing, a notice says Hermes can't browse, and the tab falls back to a regular web view. Use **Retry**, reopen the tab, or reconnect Hermes to try again.
- **Sharing the browser with other tools.** Each session's agent browser listens for remote debugging on `127.0.0.1:9333`, or on a random port if 9333 is busy. Hermes follows the selected session's endpoint. A Chrome DevTools MCP configured with `--browserUrl=http://127.0.0.1:9333` stays attached to the session that acquired that port.

### Projects and session continuity

- Skill and command highlights include the full namespaced token, such as `/cpipe:run`, in the composer and sent message bubbles.
- Browse projects and their conversations within the selected bot's scope.
- Create a project, set it active, archive it, or delete it when the installed Hermes runtime exposes the corresponding project methods.
- Keep queued messages and attachments with their session when switching conversations or starting a new chat. Reopening a session restores its queue, including when Hermes assigns a new runtime session ID.
- Edit a queued message to move it, attachments included, back into the composer; sending it again adds it to the end of the queue.
- Queued messages advance automatically when the active turn settles. Voice mode sends the next message after reply audio drains; an explicit Stop keeps the remaining queue for you to resume.
- Share conversation pins with the Hermes CLI and Desktop rather than maintaining a separate pin list.

### Bots

Leading bot mentions render an avatar-and-name pill inline with the text inside your message bubble. The pill and message text appear together as soon as you send. A single resolved bot mention anywhere in a message, without attachments or queued input, is submitted to that profile’s canonical Bot Chat. Herm verifies the recipient’s profile and session before sending, and shows its reply in the current conversation. A busy or unconfirmed recipient shows an error. Other mentions pass the resolved profile identity to the current agent for `message_agent`; Hermes reports when that tool is unavailable.

The forward-message composer keeps the insertion point with newly typed text when a delayed completion update arrives.

- A **Bots page** showing each Hermes profile's model, avatar, latest message, and live presence.
- Create, clone, edit, duplicate, hide, and permanently delete bots. **Delete Bot…** in More or the context menu confirms removal of the profile and its data; the default bot is protected. Deletion requires Hermes CLI support. Editable fields include avatar, title, model, `SOUL.md`, skills, toolsets, and MCP servers.
- **Routines** for each bot, backed by Hermes cron jobs.
- The welcome screen shares the voice orb’s animated Herm face and pointer reactions for the selected Bot, only when Hermes reports the `hermes-bots` plugin enabled. Disabled or unconfirmed plugin status keeps the plain orb.
- **Herm Faces**: Bots without uploaded art get a client-side face seeded from their profile ID (body shape, colors, eyes, lean). The face shows what Hermes reports: thinking, running a tool, replying, done, failed, stopped, waiting on you, needs your approval, needs your answer, compressing context, queued, and voice listening. Existing faces update immediately when you switch skins. It follows your skin: hued on most skins, gray on E-Ink and Monochrome, accent-tinted on Terminal and HUD, with ink outlines on Cartoon, Brutalist and E-Ink. Older glossy faces and pre-Herm Faces blobs saved to Hermes are recognized and drawn live; Regenerate All re-saves every Bot's face.
- Choosing a bot in the navigation header limits conversations, projects, and new chats to that bot.

### Kanban

- Reads and edits the **real Hermes board**: create, complete, block or unblock, archive, comment on, schedule, assign, promote, and reclaim tasks.
- Drag cards between Triage, Todo, and Ready, or use **Move to** in the always-visible three-dot menu. Done and Blocked drops require their supported action and confirmation; Running, Review, and Scheduled are managed by Hermes. Details remains available from the loaded card summary.
- Filters for status, assignee, "mine", and session are passed to Hermes.
- While open, the board refreshes every five seconds with live work and every fifteen seconds otherwise. Board and filter changes made during a refresh load the latest selection automatically.
- Large boards format card descriptions as cards become visible; refreshes update changed cards without rebuilding unchanged card content.

### Activity

- **Work** shows what shipped each day: sessions, finished tasks, commits, automation runs, and cost. A month summary sits above the calendar; teal marks shipped work, blue sessions, violet automation, and amber failed runs.
- Today stays visible in every skin with a filled date badge, a stronger cell outline, and a light skin-accent tint, including when another date or range is selected.
- The daily **Pull requests merged** section shows merged PR counts per repository, busiest first, above the individual PR links.
- Day, Week, and Month share the same PR, task, commit, session, automation, and usage details. Week and Month show records and repository counts for their selected range, with dates on each row and Show more for longer lists; usage-only periods remain visible.
- **Spend** shows token usage and cost by model and day, plus a yearly activity heatmap with Tokens, Cost, and API calls. The yearly heatmap appears first, followed by cost, tokens, cache reads, sessions, and the daily chart for the past 30 days. Tools and skills share the available width and stack in compact windows. There is no date-range picker; hover a heatmap day for details.
- Spend loads the 30-day report before the yearly heatmap, shares ongoing requests across tab changes, and reuses successful reports for one minute. Refresh reloads both; failed refreshes retain the previous figures with a stale indicator.

### Calendar

- Shows your Mac Calendar events and dated Reminders alongside upcoming Hermes automation runs and Kanban tasks in progress, in Week or Month view. The calendar uses blue event, amber reminder, violet agent-run, and teal Kanban accents, with source colors for connected Mac calendars. A quiet month/week grid shows timed entries above their titles, with a source legend below. The daily agenda aligns times in a separate column and expands rows for actions; controls wrap in compact windows.
- Read-only: Herm asks for Calendar and Reminders access only when you click **Connect** on the Calendar page, and never changes your calendars. If access was refused earlier, Connect resets Herm's own decision so macOS asks again in place; a Privacy Settings link appears only if macOS still refuses.
- Turn Mac data on or off with **Calendars → Show Calendar & Reminders**; when off, Herm does not read EventKit at all. The same menu hides individual calendars and reminder lists.
- For any item: **Attach to chat**, **Create Kanban task**, or open it in Calendar or Reminders. **Plan this day in chat** starts a chat with the day's agenda. For timed events, **Schedule prep…** creates a one-shot Hermes automation 15, 30, or 60 minutes before the event starts.

### Office Preview

- A 3D office where each bot has its own character. Bots with running work sit at computers, bots in review go to Mission Control, and bots that are planning use the Kanban room. Idle bots take coffee breaks and walk around the garden.
- Idle bots start at randomly chosen, unoccupied activities around the office. Positions are saved locally every ten seconds and when leaving Office, and restored after app relaunch. Active work still determines working bots’ destinations.
- Task ownership and status come live from Hermes. The movement and gestures are only visual.
- Includes camera presets, keyboard camera navigation, and Reduce Motion support.

### Control center

- **Today**: your current focus, approvals, failures, due Apple Reminders, active work, and scheduled jobs.
- **Inbox**: approvals, clarifications, failures, and completed work. You can dismiss or snooze items.
- **Activity**: delegated agents that are running, an animated map of handoffs between agents, and background tasks. Session Kanban activity spans all active boards and refreshes every five seconds while visible, with immediate refresh requests when session tools reference a card.
- **Artifacts**: images, files, and links across Hermes profiles and saved, unarchived sessions, including terminal outputs and pre-compaction history. The index pages through complete transcripts rather than stopping at the sidebar or message limit. Parsing runs off the UI thread; refresh reuses unchanged sessions and caches only artifact records.
- **Core**: token usage, context breakdown, rollback checkpoints, skills, MCP servers, plugins, and Hermes health.

The session inspector’s **Timeline** tab replaces the former Activity Overview/History
with a live execution waterfall. It opens on **All activity**, which stacks every loaded
request with idle time between them collapsed; the menu narrows it to one request or
follows the current turn. A metrics strip shows duration, model calls, tool calls,
delegates, reported tokens, and errors. Steps use the chat’s activity icons and a
color per tool type; the slowest step is badged. Subagents and Steps sit in separate cards with 14pt headings and collapse independently, and the
Steps header holds the step controls. Search (⌘F) preserves the step
hierarchy; Fit and Live help navigate longer runs. Live is on by default and keeps
the last row of the waterfall and the playhead in view; scrolling the timeline turns it off.
In the inspector the step list is capped in height with the selected step's details
below it; Expand opens the full timeline over the workspace (Close or Esc returns). Finished requests can be
replayed at 0.5–4× with a playhead. Select a step for a card with timing metrics and
its input, result, and diff rendered with the chat’s Markdown renderer. Restored
history takes timing from Hermes message timestamps; restored tool steps are placed at
the time Hermes recorded their result and labelled Finished, since Hermes keeps no start time; local receipt is labelled
observed, and missing timing stays unavailable. Model calls are derived from gaps
between tool batches and labelled as such; the final reply’s model call and cost
are not reported. Delegated subagents appear as their own rows, named by their task when Hermes
gives no name, live bars, nested tool calls, and a link to their conversation. A collapsible Subagents section above the steps lists delegates as Agent 1, Agent 2, … (or shows
an empty state when the request delegated nothing) with each one's task, status, duration, and what it is doing now (or its summary once finished).
Saved Activity and Trace tabs reopen as Timeline. Long timelines prepare nearby labels and bars instead of every loaded step; live activity reuses completed history, and hidden timelines stop their update work.

Capabilities loads each tab on first use and keeps its inventory in memory until Refresh or a profile change. Plugins entry and Refresh read only the plugin inventory; its profile picker reads only profile names, and plugin changes refresh only Plugins while invalidating other tabs for their next visit. Plugin catalogs become browsable before optional GitHub star counts finish. Catalog sorting and search text are prepared when source data changes; selection and filtering reuse that index. Empty catalogs are remembered, overlapping catalog reads are coalesced, and Refresh explicitly retries the catalog. Quick-view inspectors show runtime-provided plugin versions, source and pinned revision, toolset setup and tool counts, connector policy and account state, and MCP transport and required key names. Skills show their profile and SKILL.md preview; versions are shown only where Hermes supplies them.

Settings groups navigation into **App**, **Agent**, **Tools & access**, and **Activity & maintenance**. Find startup and keyboard shortcuts in **General**; backend connections in **Gateway**; themes, sidebar visibility, notch display, and the companion in **Appearance**; alerts in **Notifications**; and app/agent updates in **Updates**. **Files & terminal** brings the working directory, execution backend, and shell settings together. Each page includes a short description, and compact windows use the same grouped category menu.

Settings shows each configured MCP server once, with its connection details and status when Hermes provides them. Dropdown settings align with the right edge of their preference rows.
Agent updates share one service across the panel and window. Installation progress and failure appear in the notch and companion without creating session tasks or session completion announcements; recovery remains in Settings → Updates.

**Settings → General → Hermes gateway** shows whether the default-profile messaging gateway is running. Status refreshes every 15 seconds while visible, with a manual refresh button. **Restart gateway** runs Hermes' restart command after confirmation and checks status again. This requires a Hermes launchd service; manually launched gateways remain managed in Terminal. Restarting may briefly interrupt messaging channels and scheduled work.

**Settings → Gateway** offers Local, Remote URL/token or sign-in, SSH, and Hermes Cloud connections. Remote URLs support path prefixes and require HTTPS, except for localhost, 127.0.0.1, and [::1]. Scheme-less remote addresses default to HTTPS; loopback addresses default to HTTP. Use SSH for remote gateways without HTTPS. Native OAuth uses your browser with PKCE when supported, and password or legacy sign-in uses the gateway's page. Cloud sign-in discovers your organizations and agents. SSH launches and tunnels an owned Hermes backend on Linux, macOS, or Windows; it requires working key-based SSH, a current remote Hermes install, and Node.js 20+ on this Mac (Hermes' bundled Node is detected automatically). **Test connection** checks HTTP and WebSocket access. Save for the next restart, or confirm **Save and restart Herm**. Saved connections can be selected, renamed, or removed. Session tokens and native OAuth credentials stay in Keychain; browser sessions use Herm's separate WebKit store. `HERMES_DESKTOP_REMOTE_URL` and `HERMES_DESKTOP_REMOTE_TOKEN` override saved settings at launch. Repository tools, local terminals, agent updates, and the messaging gateway controls in General continue to operate on this Mac.

The SSH helper is bundled from Hermes Desktop's MIT-licensed, Electron-free lifecycle. To update it from an installed Hermes checkout, run `node Scripts/build-hermes-ssh-bridge.mjs /path/to/hermes-agent` with that checkout's existing build dependencies installed. Herm ships the generated helper and its license in its SwiftPM resource bundle.

### Native macOS integration

- **Answer from the banner.** Approval notifications have **Approve once** and **Deny** buttons. Clarification notifications have an inline **Reply** field (single-question clarifications only). Stale requests are ignored. Clicking the banner body opens Herm.
- **Touch ID for broad approvals** (Settings → Notifications, off by default). Requires Touch ID or your password before "always" or "session" approvals, from the banner or in the app. If authentication is unavailable, the approval is not sent.
- **Explain approvals with Apple Intelligence** (Settings → Notifications, off by default). See [Apple Intelligence](#apple-intelligence).
- **Send to Herm service.** Select text in any app, then choose **Services → Send to Herm**. The text is added to the composer as a draft and is never sent automatically.
- **Shortcuts and Siri.** The **Ask Herm** App Intent (and an **Open Herm** phrase) stages text in the composer from Shortcuts or Spotlight. It never sends on its own.
- **Summarize replies with Apple Intelligence** (Settings → Notifications, off by default). See [Apple Intelligence](#apple-intelligence).
- **Name new sessions with Apple Intelligence** (Settings → Notifications, on by default). See [Apple Intelligence](#apple-intelligence).
- **Translate a reply.** In the notch reply view, **More → Translate reply** opens Apple's Translation sheet. Translation runs on your Mac once a language is downloaded. Needs macOS 15 or later.
- **Writing Tools.** A sparkle button in the composer opens Apple's Writing Tools to rewrite or proofread a draft. It inserts plain text only, and appears only when Apple Intelligence is available.
- **Spotlight search of sessions** (Settings → Notifications, off by default). Session titles and short previews go into Spotlight's index on this Mac, and choosing a result opens that session. Turning it off removes them.
- **Dock badge and ring.** While the workspace window is open, the Dock icon badges the number of requests waiting on you and shows a ring while an agent works.
- **Text from images.** Right-click an attached image and choose **Add Text from Image to Message** to read its text into the draft. This uses Apple's Vision text recognition on your Mac, not Apple Intelligence. The image stays attached.
- **Hide from screen sharing** (Settings → Notifications). Excludes the notch and Herm windows from screen sharing and screenshots.
- **Keep Mac awake while working.** Prevents idle system sleep only while an agent session is running.

App Intents metadata is generated by `Scripts/appintents.sh` during `package-app.sh` and `run-debug-app.sh`, so no Xcode project is needed. Shortcuts discovery depends on macOS indexing the bundle, so run the packaged or debug app bundle rather than `swift run`.

### Apple Intelligence

Herm uses Apple's on-device language model (the Foundation Models framework) for two optional, off-by-default features. Everything else in Herm, including the agent itself, works without it.

| Feature | What the model receives | What you see |
|---|---|---|
| **Explain approvals** | The approval's title and its first 800 characters of detail, when an approval notification is posted. | The banner appears immediately with Hermes' original text, then is replaced in place with one extra line, "Apple Intelligence · …", saying what will happen and whether it changes or deletes anything. |
| **Summarize replies** | The first 3,000 characters of a finished reply longer than 200 characters, for the notch's "Latest update". | A one-line summary, titled "Latest update · Apple Intelligence summary". The full reply is unchanged in the chat. |
| **Name new sessions** | The first message and first reply of a session Hermes left untitled (about 600 characters each). | A title of up to 6 words, saved to Hermes through its session title, so other Hermes apps show it too. Hermes' own title is never replaced. |

- **Requirements.** macOS 26 or later, a Mac that supports Apple Intelligence, and Apple Intelligence turned on in System Settings. Settings shows whether it is available on your Mac, and the toggles say so when it isn't.
- **Privacy.** The model runs locally. Herm sends nothing to Apple or to Hermes for these features, and the generated text is not saved or fed back to the agent.
- **Labeled.** Model-written text always carries the "Apple Intelligence" label, so you can tell it apart from the agent's own words.
- **Safe fallback.** If the model is unavailable or takes too long (4 seconds for approvals, 6 for summaries), Herm shows the original text and nothing breaks.
- **Treat it as a hint.** The model can be wrong. Read the original approval before allowing anything, and note that it is instructed to ignore any instructions inside the request.
- **Not Apple Intelligence.** "Add Text from Image to Message" uses Apple's Vision text recognition, also on-device, and Touch ID uses the system authentication prompt.

### Automations and quota

- **Automations**: view, create, edit, pause, resume, run, and remove Hermes cron jobs. A searchable schedule sidebar, compact summary band, and outcome-labelled history keep recurring work easy to scan. Violet schedule accents complement green successes, amber warnings, and red failures, with theme-aware neutral colors in Monochrome and E-Ink. Creation and editing include delivery, working directory, and model/provider overrides. Run history uses Hermes-recorded session identities; agent reports and script-only output previews stay attached to their owning job and profile. Failed reads and rejected changes remain visible.
- The Quota page, chat composer, quick-message advisory, and notch share one quota inventory, including provider names, readings, reset times, and the tightest remaining window. Session model responses do not supply a separate quota reading.
- **Quota**: remaining allowance for Codex, OpenCode Go, GLM Coding Plan, Claude, and Antigravity. Its toolbar highlights Add account, groups automatic refresh and peak-hour sync, and keeps the last update time above the controls. Controls stack in narrow windows. The Add account dialog keeps provider names readable, shows readable sign-in instructions in a stable layout, and offers Done after Hermes confirms success.
- **Hermes updates**: runs `hermes update` only after you confirm. Settings shows the current activity and elapsed time; expand Output to inspect the streamed log. It never updates automatically.

## Requirements

- macOS 14 or later (built and tested on Apple Silicon)
- Swift 6 toolchain (Xcode 16 or later)
- [Hermes Agent](https://github.com/NousResearch/hermes-agent) installed, with the `hermes` executable on your `PATH`
- Optional: Google Chrome, Brave, Edge or Chromium, for the built-in agent browser
- Optional: the [GitHub CLI](https://cli.github.com/), signed in, for pull requests and issues

## Getting started

1. **Install Hermes Agent** by following the [Hermes setup guide](https://github.com/NousResearch/hermes-agent), then check that `hermes` runs in your terminal.
2. **Clone Herm and run it:**

   ```sh
   git clone https://github.com/chryzxc/herm.git
   cd herm
   swift run
   ```

3. **Find the notch** on the edge of your screen. Hover over it, click it, or double-tap ⌘ to open the workspace.

To build and open the signed debug app bundle with its icon, run:

```sh
Scripts/run-debug-app.sh
```

> [!NOTE]
> Any DMGs in `dist/` are local developer builds. They're ad-hoc signed and not notarized, so macOS Gatekeeper will warn you about them.

## How it works

```text
 notch / workspace ─SwiftUI─► Herm services ─WebSocket /api/ws─► local Hermes gateway
                                    │                             (loopback-only, authenticated)
                                    └── Hermes CLI (kanban, cron, update), when supported
```

- **Backend connection.** Local mode launches Hermes on loopback and connects over an authenticated WebSocket. Gateway settings can instead select a remote or Cloud backend, or an SSH tunnel. HTTP and WebSocket requests use the same chosen backend and authentication.
- **Hermes stays in charge.** Sessions, models, skills, profiles, MCP servers, and cron jobs are owned by Hermes. Herm keeps local UI state such as preferences, queued drafts, and file-review notes; it does not maintain a second agent session database.
- **Features turn off safely.** Herm checks each optional feature against the installed Hermes version when it runs. If a check fails, that feature stays unavailable. Herm never guesses support from a version number.

For more detail, see [ARCHITECTURE.md](ARCHITECTURE.md).

## Privacy

- The private Local gateway only accepts connections from your machine and requires authentication. Remote and Cloud modes send agent requests to the configured backend; SSH forwards them through the selected host.
- Hermes owns agent configuration and memory. Herm keeps local UI state, including queued drafts and file-review notes.
- Optional on-device approval explanations use Apple's system model locally; no extra network request is made.
- **No telemetry.**
- Provider keys for OpenCode Go and GLM are saved in a local config file that only your user account can read. Antigravity quota is read from its local language server without credentials.
- **Local-first does not mean every request stays offline.** Hermes may send prompts, attachments, or audio to the model and voice providers you configure; supported quota checks also contact provider services. The local gateway connection is separate from those provider requests.

## Current limitations

Herm doesn't yet support everything Hermes can do. Some features require additional frontend work or stable runtime support; others are deliberately left out for now:

- Generated replies require supported `herm-ui` content. Generative UI ships enabled by default and can be disabled in Appearance. Live workflow cards, full A2UI/MCP Apps compatibility, and connected HTML apps are not included.
- Directly invoking arbitrary third-party MCP tools from Herm (catalog/setup, credentials, authorization, connection tests and removal are available through supported Hermes lifecycle methods)
- Structured cron report contracts and more detailed diagnostics (recorded chat-backed run output can already be read)
- A provider-independent, full-duplex realtime audio transport (continuous Voice mode is available through Hermes' transcription and speech pipeline)
- Email and iMessage integrations, and writing to Calendar or Reminders (the Calendar page is read-only)
- Connecting to Hermes on another machine (group chats are already available when supported by Hermes)
- Force-pushing and dispatching GitHub workflows; native conflict editing and arbitrary Projects custom-field editing

Project management and bot **@mention autocomplete** are already implemented; runtime-dependent features remain unavailable on installations that do not expose their required methods. The remaining limitations are not a promise of future feature parity. The feature descriptions above reflect the current frontend.

### Native review and workflow tools

- Source Control's **Review comparisons** opens staged, working-tree, branch, and
  commit comparisons from local Git, without fetching. Search covers loaded files;
  incomplete coverage and changed sources remain visible.
- Shared native diffs support syntax colors, split/unified layouts, wrapping, Find,
  expanded review, private line-range revision notes, and validated local context expansion.
- Revision notes stage context in the source conversation. Use **+** beside a PR
  diff line to compose an inline review in the file, including expanded file views.
  Line comments stay private and can be edited beside the file or in **Reviews**;
  **Submit review** publishes them together with the summary after confirmation.
  The Reviews panel explains unavailable submission actions and links directly to Code.
- Private revision-note editors show numbered captured source above the note field.
  The tray keeps **Send revision** in its header and explains when an owning
  conversation is required.
- **Generate review guide** requests analysis in a separate Hermes conversation. It
  preserves the original task and draft and does not claim an execution sandbox.
  **Generate review guide** is the single AI-review entry point; the PR toolbar
  keeps **Attach to chat** for general questions.
  Choose a reviewer when Bots is enabled, or use the default bot. The guide opens
  immediately, shows a waiting state, and refreshes saved replies automatically
  while open. Open its conversation to follow tool activity or answer the reviewer.
- Terminals survive inspector and session navigation, support splits, and attach
  selected output to chat. Closing the app or a Terminal tab ends its shells (Herm
  asks first if a command is running); reopening starts fresh ones. Closing the
  Browser tab quits the agent's browser and unloads its page until you reopen it.
- **Actions** stores manually launched project commands. **Previews** finds loopback
  servers in Herm's terminal process trees. Its themed panel lists process names and
  addresses, supports Refresh, and labels stale results. Nothing runs or opens automatically.
- Composer attachments include window capture, saved prompts, and selected conversation
  excerpts. Large pastes become text-file context; Command-Shift-V keeps text editable.
  Pasting copied files attaches their contents as compact file chips, even when
  the clipboard also includes a file icon preview.
  Optional app text is configured in **Settings → General → Window capture**.
  **Settings → Appearance → Replies → Generative UI** controls visual replies.
- PR watching is opt-in and passive while Herm runs. It never starts agent work.
- Local model comparisons create separate worktrees and Hermes sessions, retaining
  successful launches and failed-worktree recovery independently.

## Development

```sh
swift build   # build
swift test    # run the test suite
make guard    # fast strict lint, color, and conflict/whitespace checks
make check    # everything CI runs
```

CI runs on every pull request and on every push to `main`.
Run `make guard` before review and `make format` to fix mechanical Swift
formatting. The shared formatter uses four-space indentation; lint findings
fail CI. See [Contributing](CONTRIBUTING.md) for the focused development loop.

Local attachment previews decode off the UI thread and reuse bounded thumbnails;
attachment uploads also prepare file data in the background. Explorer syntax
scanning, review diffs and saves, and notch delivery-file polling also run in the
background; terminal output renders directly without rebuilding SwiftUI chrome
for every chunk.
Tool activity from concurrent sessions updates the edge dock independently of
the open workspace, so background tool bursts do not rebuild the conversation.

| Document | Purpose |
|---|---|
| [DESIGN.md](DESIGN.md) | The reference for UI behavior and styling |
| [ARCHITECTURE.md](ARCHITECTURE.md) | How the code is structured |
| [STANDARDS.md](STANDARDS.md) | Coding standards |
| [Chat scroll verification](docs/chat-performance.md) | Production-path regressions and opt-in Release benchmarks |
| [AGENTS.md](AGENTS.md) | Guidance for AI-assisted contributions |
| [Interactive controls](docs/interactive-controls.md) | Clickable-text audit, shared treatments, and verification scope |

## Contributing

Issues and pull requests are welcome. Start with [CONTRIBUTING.md](CONTRIBUTING.md). Two rules matter most:

1. **Herm is only a frontend.** Build on the RPCs, events, and CLI commands Hermes already provides. Don't add a second source of truth.
2. **Keep this README accurate.** Any change that users will notice should update the matching section here. Label unfinished work as planned, and never describe mock data as a working feature.

## FAQ

**How is this different from Hermes Agent Desktop?**
Hermes Agent Desktop is the official, cross-platform desktop app. Herm is an unofficial, native macOS companion centered on the notch: monitor work and quota, send a quick message, speak with an agent, and inspect results when needed. Many underlying capabilities overlap; Herm's difference is its interaction model and Mac-specific presentation, not a claim that every feature is exclusive. You can use both at the same time. See [Why Herm](#why-herm).

**Does it run AI models itself?**
No. It's an interface for the Hermes runtime you already have. Models and providers are configured in Hermes.

**Which AI providers work?**
Any provider Hermes supports. The quota view also tracks Codex, OpenCode Go, GLM Coding Plan, Claude, and Antigravity.

**Why doesn't it have feature X from Hermes?**
Herm doesn't have every Hermes feature yet, and each feature is added only once Hermes provides a stable interface for it. Please open an issue if there's something you'd like to see.

**Is my data sent anywhere?**
Herm has no telemetry. It connects to a local Hermes gateway by default; Gateway settings can select a remote, SSH, or Cloud backend. Hermes can send your prompts, attachments, and audio to configured providers, and quota checks can contact provider services. See [Privacy](#privacy).

**Does it cost anything?**
Herm is free. You use your own Hermes install and provider accounts.

## Acknowledgements

- [Hermes Agent](https://github.com/NousResearch/hermes-agent) by Nous Research, which does all the agent work
- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm), used for the embedded terminal

## Disclaimer

Herm is an unofficial, community-built app. It is not affiliated with or endorsed by Nous Research. "Hermes" and "Hermes Agent" are the names of their project.

## License

[MIT](LICENSE) © 2026 Christian Rey Villablanca

Bot availability follows the Hermes roster API and honors an explicit `hermes-bots` disabled status from `plugins.manage`. Missing bot APIs fall back to the ordinary chat activity indicator. Custom avatars remain uploaded images and are never replaced by Populate avatars. Hermes Desktop currently stores its own Bots toggle in local storage; that desktop-only preference is not exposed to Herm by the gateway.

Herm uses one centralized solid accent palette throughout the app: teal, amber,
violet, coral, blue, orange, pink, green, cyan, indigo, and tangerine. Neutral skins use gray actions and selection;
character skins use their own hue. Status, charts, agent identities, and file icons reuse the
same approved solid color families. The [color-system audit](docs/color-system.md)
records the mapping for each app area; `make color-contract` guards future features.
Solid fills stay the same in Light/Dark; text ink adapts for readable contrast on each
theme, including Light/Dark and Glass; Monochrome and E-Ink stay neutral.

Automation uses consistent compact actions, quieter two-line schedule titles,
and a flat run summary. A labelled Run output control sits beside History and Details.
The inspector shows readable, selectable script output with Copy and Close actions;
agent reports retain Markdown formatting and technical run details are expandable. Create and edit sheets share schedule explanations
and delivery/execution settings.

PR lists use green for open work; Issues uses blue status icons with neutral state text.
Ordinary IDs, branches, and drafts keep neutral ink. PR readiness is colored separately from lifecycle.
Category colors distinguish calendar sources, automation, and file changes;
orange is reserved for attention rather than normal draft or modified state.

The expanded floating workspace fills the panel vertically without extra top or bottom shell padding.

PR Summary sections share a padded leading edge for headings and content, with stronger section titles.

Review actions group pull-request watching and guide actions in a compact menu. Raw submission diagnostics stay in the guide; startup shows a loading indicator. New review sessions wait briefly for project-directory confirmation, and active first turns wait for saved history.

Markdown GitHub pull request and issue overview links open the shared PR or issue detail view in chat’s Pull Request or Issue inspector tab
when that page is enabled in Settings and GitHub resolves the item. Each chat keeps
its own GitHub selection; opening a link leaves the conversation visible. Disabled pages,
unavailable items, and links to anchors or subpages retain the browser fallback.

Chat’s Pull Request and Issue tabs use the standard 12pt inspector side gutters.

Open pull requests offer Edit beside Reviewers to select people with repository write access.
Changes require confirmation, preserve team requests, and refresh from GitHub.

Async actions show local progress while requests are pending. Markdown PR and issue
links show an “Opening…” indicator while GitHub resolves their inspector tab;
settings, connection, memory, review, and group-chat actions expose pending feedback
and suppress repeat submission. See [the loading-state audit](docs/loading-states.md).

Merge stays disabled for draft pull requests and unmet GitHub merge requirements.
Hover over the main button for the blocker; the dropdown retains View merge
requirements for refresh, queue, and auto-merge actions.
