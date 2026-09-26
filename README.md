# Herm

[![CI](https://github.com/chryzxc/hermes-agent-dock/actions/workflows/ci.yml/badge.svg)](https://github.com/chryzxc/hermes-agent-dock/actions/workflows/ci.yml)
[![platform: macOS 14+](https://img.shields.io/badge/platform-macOS%2014%2B-1f6feb)](#requirements)
[![Swift 6](https://img.shields.io/badge/Swift-6-F05138)](#development)
[![local-first](https://img.shields.io/badge/local-first-f0883e)](#how-it-works)
[![License: MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)

**A quick-access notch for [Hermes Agent](https://github.com/NousResearch/hermes-agent) on macOS.**

*Named after the herms, the markers of Hermes that stood at doorways and crossroads, always in view and always within reach.*

Glance at the notch to see what your agents are doing. Hover to see which tasks are running, which need you, and which just finished. Click to open a full workspace for chat, voice, pull requests, issues, Kanban boards, bots, automations, and provider quota.

Herm is a **frontend for Hermes**. It doesn't run models, keep its own copy of your sessions, or replace the Hermes CLI. It connects to the Hermes runtime already installed on your Mac and gives it a native interface. It's an unofficial community project, separate from the official Hermes Agent Desktop app ([more](#disclaimer)).

```sh
git clone https://github.com/chryzxc/hermes-agent-dock.git
cd hermes-agent-dock
swift run
```

---

> [!IMPORTANT]
> **Herm doesn't yet do everything Hermes Agent can.** It includes a subset of Hermes features, and each one only turns on when the installed Hermes version supports it. Hermes Agent moves fast, so Herm will keep adding features over time. If something works in the Hermes CLI but doesn't appear here yet, it probably hasn't been added. See [Current limitations](#current-limitations) for the full list, and feel free to open an issue.

---

## Table of contents

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

## The notch

The notch is the main way to use Herm. It sits against the left or right edge of your screen, stays out of the way while nothing is happening, and shows you when Hermes needs attention.

### What the notch shows

The notch changes to reflect what Hermes is doing, so you don't have to keep a terminal open:

| State | What you see |
|---|---|
| **Idle** | A thin, quiet rail on the screen edge. |
| **Working** | A live indicator while Hermes is running a turn, a tool, or a background task. |
| **Needs you** | An attention state when Hermes is waiting for an approval (for example, a dangerous command) or has asked you a clarifying question. |
| **Finished** | A short announcement when a task completes, which stays marked until you open the result. |
| **Offline** | A clear indicator when the local Hermes runtime isn't reachable. |

The status colors match the rest of the app: blue means active, green means healthy or done, amber means a warning or that Hermes needs you, and red means a failure.

### How to use it

| Action | Result |
|---|---|
| **Hover** | Opens a preview with two tabs. |
| **Tasks tab** | Lists every session that's in progress, with the ones that need you first, plus finished results you haven't opened yet. Click one to go straight to it. |
| **Quota tab** | Shows provider usage and reset times, so you know how much allowance is left before starting a long task. |
| **Click** | Expands the notch into the full workspace in the same window. |
| **Double-tap ⌘** | Opens or closes the workspace from anywhere. |
| **Double-tap ⌥** | Opens or closes the hover preview from the keyboard. |
| **Drag** | Moves the notch along either screen edge. Its position is saved. |
| **Right-click** | Moves the notch to the left or right edge, or quits the app. |

A typical workflow: start a long task in chat, collapse the workspace, and keep working. When the notch turns amber, hover over it to see which session needs approval, click that session, approve, and collapse again. When the task finishes, the notch tells you.

All notch animations respect **Reduce Motion**.

## Features

### 💬 Conversations

- **Streaming chat** with Markdown, images, tool output, and inline clarification requests.
- **Steering during a turn**: guidance you type while Hermes is working is added to the running turn at the next tool boundary.
- **Attachments**: files, pasted images, URLs, prompt snippets, several images at once, or a single PDF up to 25 MB.
- **Message actions**: branch from a message, copy it, have it read aloud, or refresh it from Hermes.
- **Pinned conversations** use Hermes' own pin, so pins are shared with Hermes Agent Desktop and `hermes sessions pin`.
- **Model picker** grouped by provider, with search.
- **Context guardrails**: context usage is labelled normal, warning (80%), or critical (90%), with actions to branch, compress, or hand off.
- **Dangerous-command approvals**: *Deny*, *Allow once*, or *Always allow*. *Always allow* is saved to the Hermes allowlist.

### 🎙️ Voice

- Uses the Hermes continuous voice loop, with voice activity detection, streaming text-to-speech, and the ability to interrupt by speaking.
- If Hermes voice dependencies aren't installed, Herm falls back to macOS speech and labels it clearly.

### 🔀 Pull requests

- Open pull requests for the session's repository, with check status, review state, blockers, and deep links.
- Create draft pull requests and edit a pull request's title or body, with a confirmation step.
- **Not supported:** merging, commenting, force-pushing, and dispatching workflows.

### 🐛 GitHub issues

- A separate **Issues** destination in the navigation rail for browsing the repository's GitHub issues without leaving Herm.

### 🛠️ Developer tools

- **Explorer**: a repository browser with blame information.
- **Source Control / Changes**: staged, unstaged, and untracked files with diffs, plus a local check on added lines that flags conflict markers, likely credentials, and debug statements. Credential values are never shown.
- **Terminal**: a native terminal in the session's project folder, with history, Tab completion, and optional repository checks.
- **Repository review**: reviews the whole repository locally and tells you what it didn't cover. Optional repository watching never starts Hermes work on its own.
- **Verification Center**: the project's manifests, package managers, verification commands, and the latest results from Hermes.
- **⌘K command palette** for app actions and Inbox filters.

### 🤖 Bots

- A **Bots page** showing each Hermes profile's model, avatar, latest message, and live presence.
- Create, clone, edit, duplicate, and hide bots. Editable fields include avatar, title, model, `SOUL.md`, skills, toolsets, and MCP servers.
- **Routines** for each bot, backed by Hermes cron jobs.
- Choosing a bot in the navigation header limits conversations, projects, and new chats to that bot.

### 📋 Kanban

- Reads and edits the **real Hermes board**: create, complete, block or unblock, archive, comment on, schedule, assign, promote, and reclaim tasks.
- Filters for status, assignee, "mine", and session are passed to Hermes.

### 🏢 Office Preview

- A 3D office where each bot has its own character. Bots with running work sit at computers, bots in review go to Mission Control, and bots that are planning use the Kanban room. Idle bots take coffee breaks and walk around the garden.
- Task ownership and status come live from Hermes. The movement and gestures are only visual.
- Includes camera presets, keyboard camera navigation, and Reduce Motion support.

### 🧭 Control center

- **Today**: your current focus, approvals, failures, due Apple Reminders, active work, and scheduled jobs.
- **Inbox**: approvals, clarifications, failures, and completed work. You can dismiss or snooze items.
- **Activity**: delegated agents that are running, an animated map of handoffs between agents, and background tasks.
- **Artifacts**: images, files, and links produced in recent sessions.
- **Core**: token usage, context breakdown, rollback checkpoints, skills, MCP servers, plugins, and Hermes health.

### ⏱️ Automations and quota

- **Automations**: view, create, run, and remove Hermes cron jobs, and see their run history.
- **Quota**: remaining allowance for Codex, OpenCode Go, GLM Coding Plan, Claude, and Antigravity.
- **Hermes updates**: runs `hermes update` with streamed progress, only after you confirm. It never updates automatically.

## Requirements

- macOS 14 or later (built and tested on Apple Silicon)
- Swift 6 toolchain (Xcode 16 or later)
- [Hermes Agent](https://github.com/NousResearch/hermes-agent) installed, with the `hermes` executable on your `PATH`
- Optional: the [GitHub CLI](https://cli.github.com/), signed in, for pull requests and issues

## Getting started

1. **Install Hermes Agent** by following the [Hermes setup guide](https://github.com/NousResearch/hermes-agent), then check that `hermes` runs in your terminal.
2. **Clone Herm and run it:**

   ```sh
   git clone https://github.com/chryzxc/hermes-agent-dock.git
   cd hermes-agent-dock
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

- **Local connection.** When Herm starts, it launches a Hermes backend that only listens on your machine and connects to it over an authenticated WebSocket using the Hermes gateway JSON-RPC protocol.
- **Hermes stays in charge.** Sessions, models, skills, profiles, MCP servers, and cron jobs are owned by Hermes. Herm stores only references, display state, and UI preferences.
- **Features turn off safely.** Herm checks each optional feature against the installed Hermes version when it runs. If a check fails, that feature stays unavailable. Herm never guesses support from a version number.

For more detail, see [ARCHITECTURE.md](ARCHITECTURE.md).

## Privacy

- The Hermes gateway only accepts connections from your machine and requires authentication.
- Herm doesn't store credentials, memory, or tool payloads.
- **No telemetry.**
- Provider keys for OpenCode Go and GLM are saved in a local config file that only your user account can read. Antigravity quota is read from its local language server without credentials.

## Current limitations

Herm doesn't yet support everything Hermes can do. These features are unavailable until Hermes provides a stable interface Herm can use:

- Creating, activating, archiving, or deleting projects (you can browse Kanban boards today)
- Discovering and calling third-party MCP tools (you can view the MCP inventory and test connections today)
- Structured cron reports and more detailed diagnostics
- Realtime audio that works across providers
- Calendar, email, and iMessage integrations
- Deleting bot profiles, group chats, connecting to Hermes on another machine, and @mention autocomplete for bots
- Merging and commenting on pull requests, force-pushing, and dispatching workflows (left out on purpose for now)

These will be added as Hermes supports them. See [HERMES_COMMAND_CENTER_CONTRACTS.md](HERMES_COMMAND_CENTER_CONTRACTS.md) for what each one requires.

## Development

```sh
swift build   # build
swift test    # run the test suite
make check    # everything CI runs
```

CI runs on every pull request and on every push to `main`.

| Document | Purpose |
|---|---|
| [DESIGN.md](DESIGN.md) | The reference for UI behavior and styling |
| [ARCHITECTURE.md](ARCHITECTURE.md) | How the code is structured |
| [STANDARDS.md](STANDARDS.md) | Coding standards |
| [AGENTS.md](AGENTS.md) | Guidance for AI-assisted contributions |
| [HERMES_COMMAND_CENTER_CONTRACTS.md](HERMES_COMMAND_CENTER_CONTRACTS.md) | Hermes support required before each remaining feature can be added |

## Contributing

Issues and pull requests are welcome. Start with [CONTRIBUTING.md](CONTRIBUTING.md). Two rules matter most:

1. **Herm is only a frontend.** Build on the RPCs, events, and CLI commands Hermes already provides. Don't add a second source of truth.
2. **Keep this README accurate.** Any change that users will notice should update the matching section here. Label unfinished work as planned, and never describe mock data as a working feature.

## FAQ

**How is this different from Hermes Agent Desktop?**
Hermes Agent Desktop is the official, full desktop app. Herm is an unofficial companion that lives in a notch, so you can check status, handle approvals, and jump into a session without switching windows. You can use both at the same time.

**Does it run AI models itself?**
No. It's an interface for the Hermes runtime you already have. Models and providers are configured in Hermes.

**Which AI providers work?**
Any provider Hermes supports. The quota view also tracks Codex, OpenCode Go, GLM Coding Plan, Claude, and Antigravity.

**Why doesn't it have feature X from Hermes?**
Herm doesn't have every Hermes feature yet, and each feature is added only once Hermes provides a stable interface for it. Please open an issue if there's something you'd like to see.

**Is my data sent anywhere?**
No. Everything runs locally, and there's no telemetry.

**Does it cost anything?**
Herm is free. You use your own Hermes install and provider accounts.

## Acknowledgements

- [Hermes Agent](https://github.com/NousResearch/hermes-agent) by Nous Research, which does all the agent work
- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm), used for the embedded terminal

## Disclaimer

Herm is an unofficial, community-built app. It is not affiliated with or endorsed by Nous Research. "Hermes" and "Hermes Agent" are the names of their project.

## License

[MIT](LICENSE) © 2026 Christian Rey Villablanca
