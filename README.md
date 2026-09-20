# Hermes Agent Dock

[![CI](https://github.com/chryzxc/hermes-agent-dock/actions/workflows/ci.yml/badge.svg)](https://github.com/chryzxc/hermes-agent-dock/actions/workflows/ci.yml)
[![platform: macOS 14+](https://img.shields.io/badge/platform-macOS%2014%2B-1f6feb)](#requirements)
[![Swift 6](https://img.shields.io/badge/Swift-6-F05138)](#development)
[![local-first](https://img.shields.io/badge/local-first-f0883e)](#how-it-works)

**A native macOS menu-bar control center for a local [Hermes Agent](https://github.com/NousResearch/hermes-agent) runtime — chat, voice, Kanban boards, bot rosters, automations, and developer tooling for your AI agent team, in one popover.**

The Dock lives in your menu bar as a unified popover: conversations, voice, sessions, and quick capture on the left; Today, Inbox, Activity, and Core controls on the right. It is a projection and control surface for the Hermes runtime you already have installed — never a second runtime, never a second copy of your data. Everything runs locally on your Mac; the Dock never stores credentials, memory, or tool payloads.

```sh
git clone https://github.com/chryzxc/hermes-agent-dock.git
cd hermes-agent-dock
swift run
```

## Why

Running an AI agent team from a terminal means juggling sessions, task boards, cron jobs, approvals, and provider quotas in separate places. Hermes Agent Dock brings all of it into one native, keyboard-first macOS surface:

| You get | How |
|---|---|
| Your agent team, at a glance | Bots page with roster, models, avatars, routines, and live activity — plus a 3D office visualization where bots physically move between working, review, and planning |
| Task boards that stay authoritative | Kanban reads and mutates the real Hermes board — create, assign, block, promote, reclaim — with filters the engine forwards natively |
| Conversations with real control | Streaming chat, in-turn steering, context guardrails, approval choices with persistent allowlists, and a searchable multi-provider model picker |
| Developer command center | Working-tree changes, pull requests, repository review, verification evidence, and a recipe-gated session terminal |
| Automations and quota in one place | Cron job management plus live allowance windows across Codex, OpenCode Go, GLM Coding Plan, Claude, and Antigravity |
| Local-first by construction | Loopback-only authenticated gateway, capability-gated fail-closed controls, zero telemetry |

## Table of contents

- [Requirements](#requirements)
- [Features](#features)
- [How it works](#how-it-works)
- [Getting started](#getting-started)
- [Development](#development)
- [FAQ](#faq)
- [Current limitations](#current-limitations)
- [Maintaining this document](#maintaining-this-document)

## Requirements

- macOS 14+ with SwiftUI (built and tested on Apple Silicon)
- Swift 6 toolchain (`swift build` / `swift test`)
- The `hermes` executable on your `PATH` (installed via the [Hermes Agent](https://github.com/NousResearch/hermes-agent) setup)

## Features

### Conversations

- **Streaming chat** — bottom-anchored transcript, bounded history paging, native Markdown links, and in-turn steering: typed guidance is submitted to the running turn at its next tool boundary.
- **Message navigator** — session-scoped jump navigation with bounded previews across Markdown, image, tool, and clarification messages.
- **Completed-message actions** — accessible, message-scoped actions can branch from the source message, copy readable text, read aloud with a stop toggle, or refresh from Hermes' authoritative transcript. Branch and refresh remain unavailable while message/session identity or response context is incomplete; malformed runtime responses fail closed without replacing the source conversation.
- **Attachments** — accessible Attach popover with native file/image pickers, pasted images, validated http(s) URLs, and prompt snippets; multi-image and single-PDF review before sending (25 MB PDF cap).
- **Explicit session lifecycle** — selecting or restoring a session never creates a replacement implicitly; new chats are created only on request. Session data stays isolated and fails closed on identity mismatch.
- **Pinned conversations** — labelled pin/unpin keeps important chats in a Pinned section that survives refreshes, relaunches, and bot-profile switches.
- **Clarification requests** render as action-needed states with editable responses submitted through `clarify.respond`.
- **Session surfaces** — the session header switches between **Chat**, **Talk**, **Explorer** (blame-aware repository browser), **Source Control** (staged/unstaged/untracked with bounded diffs), and **Pull Requests** scoped to the session repository.
- **Context guardrails** — Hermes-reported context use labelled normal/warning/critical (80% / 90%) with explicit branch, confirmed compression, and no-edit background handoff actions.
- **Dangerous-command approvals** — Deny / Allow once / Always allow; "Always allow" persists the command pattern into Hermes' allowlist, shown read-only in Core.
- **Model picker** — composer model selection grouped by provider, searchable, refreshable; stable-ID enable/disable preferences persist locally while Hermes stays authoritative for the catalog.

### Voice

- Prefers Hermes' native continuous voice loop (server VAD, streaming TTS, spoken barge-in) with an explicitly labelled macOS speech fallback when voice dependencies are unavailable.
- Native voice reports time to first streamed text and end-to-end turn duration.

### Bots

- **Bots page** on the verified Hermes `profiles.*` contract: roster with titles, models, latest-message previews, active-now strip, and avatars (stored asset, upload, AI generation, or deterministic fallback).
- Open a Bot's canonical **Bot Chat**; create agents (quick path or advanced clone/empty), edit profiles (avatar, title, description, guarded model pin, full SOUL.md, per-skill/toolset/MCP-server enablement), duplicate, and hide/unhide.
- **Routines** per bot via namespaced `[bot:<name>]` cron jobs.
- **Bot-scoped navigation** — the nav header becomes a profile selector scoping conversations, projects, and new chats to the selected bot.
- **Session Bot Activity** — session-attributed Kanban tasks owned by visible bot profiles.

### Control center

- **Today** — current focus, approvals, failures, due Apple Reminders, active Hermes work, scheduled jobs, and setup cards for unavailable providers.
- **Inbox** — actionable approvals, clarifications, failures, and completed work; dismissals persist, snoozed items return after an hour.
- **Activity** — live delegated agents with event history, an animated agent-to-agent handoff map, background task tracking, and a per-session Now view synced to live execution.
- **Artifacts** — generated outputs from recent sessions as an image preview grid plus searchable files and links, each retaining its source session.
- **Core** — session cockpit (token usage, context breakdown, prompt budget, steering, rollback checkpoints with confirmed restore), runtime inventories (skills, MCP servers, plugins), session controls (rename, branch, compress, undo, delegation pause, interrupt), read-only Hermes health, and opt-in completion notifications.

### Developer command center

- **Changes** — bounded read-only Git working-tree and diff projection (including untracked files) with a local added-line pre-commit signal pass (conflict markers, likely credentials, debug statements — credential values never repeated in the UI).
- **GitHub context** — open pull requests, check status, review state, actionable blockers, and deep links for the session repository; confirmed draft creation and title/body updates. Merge, commenting, force-push, and workflow dispatch are intentionally unsupported.
- **Repository review and watch** — bounded repository-wide local review with explicit partial-coverage accounting and fingerprint-stale invalidation; passive opt-in repository watching that never starts Hermes work automatically; read-only worktree fleet (bounded to eight).
- **Verification Center** — manifests, package managers, exact verification commands, and best-known evidence from Hermes `project.facts` / `verification.status`.
- **Session Terminal** — runs only repository-fact-derived, allow-listed recipes through a bounded local PTY; no free-form shell input.
- **Command-K palette** for Dock actions and Inbox filters; it cannot execute arbitrary shell or Hermes commands.

### Kanban

- Reads the authoritative Hermes board and supports confirmed task creation plus complete, block/unblock, archive, comment, schedule, assign/reassign, promote, and reclaim — each individually capability-gated against the installed Hermes CLI contract.
- Native status/assignee/mine/sort/session filters are forwarded to Hermes; board selection is local view state scoped per call and never moves Hermes' shared current-board pointer.

### Automations and quota

- **Automations** — review, create, and remove Hermes cron jobs through `cron.manage` when the scheduler capability is verified; confirmed Run Now; live run history through `cron runs`.
- **Global Quota** — every supported subscription provider (Codex, OpenCode Go, GLM Coding Plan, Claude, Antigravity) with remaining-allowance windows when connected; the Dock never stores CLI OAuth credentials. OpenCode Go and GLM keys live in owner-only local provider config; Antigravity quota is read credential-free from its local language server.
- **Hermes updates** — explicit, confirmed `hermes update` with streamed progress; never automatic.

### Office Preview

- A furnished 3D office and garden built locally from original RealityKit geometry (no purchased assets). Every bot gets one stable chibi character matched to Kanban tasks by profile ID: running work goes to the computers, review to Mission Control, planning to the Kanban room; idle bots take patio breaks, coffee, and walks. Task ownership and status are live; office actions are simulated.
- Specialist interiors (Design Studio, QA / Verification lab, Server / Operations, Bot Workshop), a private Main Agent office, live Nexus avatars, a task board, camera presets, full keyboard camera navigation, and Reduce Motion support.

### Presentation

- Native macOS menu-bar presentation: appearance-aware navy surface, system typography, native controls, restrained selection, and a deliberate compact type scale.
- Optional right-edge Dock notch — a hover/click launcher that expands into the Dock without replacing the menu-bar icon.
- Status colors reserved for meaning (blue active, green healthy, amber warning, red failure); menu-bar unread badge; narrow-screen single-pane mode; adaptive composer.

## How it works

```text
menu-bar popover ─SwiftUI─► Dock services ─WebSocket /api/ws─► local Hermes gateway
                                   │                            (loopback-only, authenticated)
                                   └── capability-gated Hermes CLI (shell.exec) for kanban, cron, update
```

- **Local connection.** On launch the Dock starts a loopback-only Hermes backend, establishes an authenticated WebSocket session, and speaks the TUI Gateway JSON-RPC protocol (`session.create`, `prompt.submit`, `session.interrupt`, `approval.respond`, streamed messages, approval requests).
- **Hermes is authoritative.** Sessions, agents, prompts, models, skills, profiles, MCP, and cron belong to Hermes; Apple Reminders owns reminder content; local Git/GitHub own repository data. The Dock stores references, display state, UI preferences, and cached metadata — never a second copy of those systems.
- **Capability-gated, fail-closed controls.** Every optional control is classified at runtime (verified gateway RPC, stable read-only CLI projection, confirmed CLI mutation, unsupported, or external setup). A missing or failed probe fails closed: the control stays unavailable, and support is never inferred from a version string.
- **Control authority.** Model/reasoning changes are explicit Hermes mutations applied to the next turn. Recovery guidance is copy-only; the Dock never runs recovery commands or updates automatically.
- **Architecture in the codebase.** Transport and process-launch concerns live in gateway/runtime services, persistent workspace state in `WorkspaceStore`, presentation state in `DockModel`; parsing and state transitions are extracted into testable helpers instead of expanding view types.

## Getting started

```sh
git clone https://github.com/chryzxc/hermes-agent-dock.git
cd hermes-agent-dock
swift run
```

The app launches quietly into the menu bar. Double-tap the Command key (or click the status item) to open the popover; `--show-panel` forces it visible immediately for development runs.

Packaged DMGs under `dist/` are local developer artifacts — ad-hoc signed, not notarized.

## Development

```sh
swift build   # baseline build
swift test    # full test suite
```

Both run on every pull request and on pushes to the default branch. Test counts are intentionally not hard-coded here because they change as coverage evolves.

- `DESIGN.md` — source of truth for Dock UI behavior and styling.
- `AGENTS.md` — contributor guidance for agent-driven work.
- `HERMES_COMMAND_CENTER_CONTRACTS.md` — fail-closed contracts required for remaining integrations.
- `CONTRIBUTING.md` — how to contribute.

## FAQ

**What is Hermes Agent Dock?** A native macOS menu-bar app that gives a local [Hermes Agent](https://github.com/NousResearch/hermes-agent) runtime a full control center: chat, voice, sessions, bot rosters, Kanban task boards, cron automations, GitHub and repository tooling, and provider quota dashboards.

**Does it run AI models itself?** No. The Dock is a projection and control surface for the Hermes runtime you already have installed — never a second runtime. Hermes stays authoritative for sessions, models, skills, profiles, MCP, and cron.

**Is my data sent anywhere?** No. The gateway is loopback-only and authenticated; the Dock never stores credentials, memory, or tool payloads, and ships zero telemetry.

**Can I manage multiple bots / an agent team?** Yes — the Bots page manages the full profile roster (models, SOUL.md, skills, toolsets, MCP servers, avatars, routines), conversations scope to the selected bot, and Kanban + the 3D Office Preview show which bot is working on what.

**Which AI providers are supported?** Anything Hermes supports. The quota dashboard additionally tracks Codex, OpenCode Go, GLM Coding Plan, Claude, and Antigravity subscription allowances.

**Does it cost anything?** The Dock is free and open source; you bring your own Hermes install and provider accounts.

## Current limitations

Features below stay intentionally unavailable until Hermes exposes a stable, capability-advertised contract:

- **Project mutation** (creation/activation/archive/deletion) — Kanban board enumeration is available today.
- **Third-party MCP discovery/invocation** (scoped authorization, tool schemas, redacted results) — read-only MCP inventory and connection tests are available today.
- **Structured cron reports** and richer diagnostics beyond the live CLI projections.
- **Provider-neutral realtime audio** (voice-session lifecycle RPCs and model audio-capability metadata).
- **Calendar access** (provider capability, authorization state, stable event operations).
- **Durable activity feeds, fleet session usage, authoritative project repository enumeration.**
- Bot profile deletion (no gateway RPC yet), group chats, cross-machine connections, bot-to-bot @mention autocomplete.

Voice today uses Hermes' native continuous loop when available, with the labelled local fallback otherwise; true provider-native realtime audio remains gated on a Hermes voice-session gateway protocol and is not yet implemented.

## Maintaining this document

Every user-facing feature or behavior change must update the relevant section of this README in the same change set. Mark incomplete work as planned, and never describe mock data or provider capabilities as live functionality. Calendar, email, iMessage, automation fields Hermes does not return, and third-party MCP browsing remain planned follow-on integrations.
