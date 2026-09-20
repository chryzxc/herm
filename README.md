# Hermes Agent Dock

A native macOS menu-bar control surface for a local [Hermes Agent](https://github.com/NousResearch/hermes-agent) session.

The Dock lives in your menu bar as a unified popover: conversations, voice, sessions, and quick capture on the left; Today, Inbox, Activity, and Core controls on the right. It is a projection and control surface for the Hermes runtime you already have installed — never a second runtime.

```
swift run
```

## Table of contents

- [Requirements](#requirements)
- [Features](#features)
- [How it works](#how-it-works)
- [Getting started](#getting-started)
- [Development](#development)
- [Current limitations](#current-limitations)
- [Maintaining this document](#maintaining-this-document)

## Requirements

- macOS with SwiftUI (built and tested on Apple Silicon)
- Swift toolchain (`swift build` / `swift test`)
- The `hermes` executable on your `PATH` (installed via the Hermes Agent setup)

## Features

### Conversations

- **Streaming chat** with bottom-anchored transcript, bounded history paging, native Markdown links, and in-turn steering — typed guidance is submitted to the running turn at its next tool boundary.
- Long transcripts expose stable, session-scoped message navigation metadata with bounded previews and search-safe matching across Markdown, image-only, tool, and clarification messages; stale viewport targets are ignored after a session switch.
- **Attachments**: the composer’s accessible **Attach** popover supports native file/image selection, pasted images, validated http(s) URLs, and prompt snippets while preserving the draft and focus. Multiple images and one PDF remain reviewable and removable before sending; folder attachments are shown as unavailable until Hermes exposes a folder contract, and the 25 MB PDF limit is enforced again before upload. Automated coverage verifies the action/model callback contract and failure states; the native macOS manual path (open Attach with keyboard, traverse actions, cancel/fail native pickers, paste an image, and confirm focus restoration) remains to be exercised in a live app session.
- **Explicit session lifecycle**: selecting or restoring a session never creates a replacement implicitly; new chats are created only on request, guarded against races. Session data stays isolated to its owning session and fails closed on identity mismatch.
- **Pinned conversations**: use the labelled pin/unpin control on any conversation row to keep it in the Pinned section. Pins preserve their order across refreshes, relaunches, and bot-profile switches; unavailable sessions are removed only when their own profile index confirms they are gone. The native menu-bar path is Dock → Conversations → Pinned → conversation row → labelled pin/unpin button. The package target covers the row action, profile identity, selection, and UserDefaults handoff; live macOS VoiceOver and keyboard traversal on that native path remain unexercised.
- **Clarification requests** render as action-needed states with editable responses submitted through `clarify.respond`.
- **Session surfaces**: the session header switches the conversation column between **Chat**, **Talk**, **Explorer**, **Source Control**, and **Pull Requests** — Explorer browses the session repository with a blame-aware editor, Source Control shows staged/unstaged/untracked files with bounded diffs, and Pull Requests lists open PRs scoped to the session's repository. Pull Requests also contains a read-only GitHub-authoritative Issues workspace with Authored, Assigned, and All filters, repository/search scope, issue details, GitHub deep links, and an explicit issue-scoped Chat handoff. GitHub account or search failures remain unavailable/stale rather than appearing as empty results; no issue mutations are performed.
- **Context guardrails**: Hermes-reported context use is labelled normal/warning/critical (80% / 90% thresholds) with explicit branch, confirmed compression, and no-edit background handoff actions.
- **Approval choices with persistence**: dangerous-command approvals render Deny / Allow once / Always allow. "Always allow" persists the command pattern into Hermes' allowlist for future sessions (content-level findings are session-only by design); Core shows the current allowlist read-only with copy-only management guidance.
- **Model picker**: composer model selection is grouped by provider, searchable, refreshable, and scrollable through native menus. The editor supports stable-ID enable/disable preferences that persist locally; Hermes remains authoritative for the available catalog and active model.

### Voice

- Prefers Hermes' native continuous voice loop (server VAD, Hermes transcription, streaming TTS, spoken barge-in) with an explicitly labelled macOS speech fallback when voice dependencies are unavailable.
- Native voice reports time to first streamed text and end-to-end turn duration.

### Bots

- A full **Bots page** built on the verified Hermes `profiles.*` contract: roster with titles, models, latest-message previews, active-now strip, and avatars (stored asset, upload, AI generation, or deterministic fallback).
- Open a Bot's canonical **Bot Chat**; create new agents (quick path or advanced clone/empty), edit profiles (avatar, title, description, guarded model pin, full SOUL.md, per-skill/toolset/MCP-server enablement), duplicate, and hide/unhide.
- **Routines** per bot via namespaced `[bot:<name>]` cron jobs.
- **Bot-scoped navigation**: the nav header becomes a profile selector scoping conversations, projects, and new chats to the selected bot.
- **Session Bot Activity** projects session-attributed Kanban tasks owned by visible bot profiles.

### Control center

- **Today**: current focus, approvals, failures, due Apple Reminders, active Hermes work, scheduled jobs, and setup cards for unavailable providers (with copy-only recovery commands).
- **Inbox**: actionable approvals, clarifications, failures, and completed work — dismissed items persist, snoozed items return after an hour, due Reminders project into the same stream.
- **Activity**: live delegated agents by name with event history, an animated agent-to-agent handoff map, background task tracking, and a per-session Now view synced to live execution.
- **Artifacts**: indexes generated outputs from recent Hermes sessions and presents images in a preview grid plus files and links in a searchable list. Filters show live counts; each item retains its source session and supports copying or opening the original URL/path.
- **Core**: session cockpit (token usage, context breakdown, prompt budget, steering, session-scoped rollback checkpoints with confirmed restore and honest pending/failure states), runtime inventories (skills, MCP servers, plugins), session/runtime controls (rename, branch, compress, undo, delegation pause, interrupt), read-only Hermes health, and opt-in completion notifications.

### Developer command center

- **Changes**: bounded read-only Git working-tree and diff projection (including untracked files) with a local added-line pre-commit signal pass (conflict markers, likely credentials, debug statements, unfinished-work markers, bare exception clauses — credential values are never repeated in the UI).
- **GitHub context**: open pull requests, check status, review state, actionable blockers, and deep links for the session repository; confirmed draft creation and title/body updates. Merge, commenting, force-push, and workflow dispatch are intentionally unsupported.
- **Repository review and watch**: bounded repository-wide local review with explicit partial-coverage accounting and fingerprint-stale invalidation; passive opt-in repository watching with in-app notices that never start Hermes work automatically; read-only worktree fleet (bounded to eight at a time).
- **Verification Center**: manifests, package managers, exact verification commands, and best-known evidence from Hermes `project.facts` / `verification.status`; targeted evidence is never upgraded to repository-wide claims.
- **Session Terminal**: runs only repository-fact-derived, allow-listed recipes through a bounded local PTY — no free-form shell input.
- **Command-K palette** for Dock actions and Inbox filters; it cannot execute arbitrary shell or Hermes commands.

### Kanban

- Reads the authoritative Hermes board and supports confirmed task creation plus complete, block/unblock, archive, comment, schedule, assign/reassign, promote, and reclaim — each individually capability-gated against the installed Hermes CLI contract.
- Native status/assignee/mine/sort/session filters are forwarded to Hermes; board selection is local view state scoped per call with `--board <slug>` and never moves Hermes' shared current-board pointer. Read-only diagnostics and attachments use Hermes JSON output.

### Automations and quota

- **Automations**: review, create, and remove Hermes cron jobs through `cron.manage` when the scheduler capability is verified; confirmed Run Now when supported; live run history through `cron runs`.
- **Global Quota**: always lists every supported subscription provider (Codex, OpenCode Go, GLM Coding Plan, Claude, Antigravity). Connected providers show remaining-allowance windows; others render disabled with a safe diagnostic and a provider-specific Connect action. The Dock never stores CLI OAuth credentials; OpenCode Go and GLM keys live in owner-only local provider config; Antigravity quota is read credential-free from its local language server.
- **Hermes updates**: explicit, confirmed `hermes update` with streamed progress — never automatic.

### Office Preview

- The private Main Agent office behind Mission Control replaces the northeast four-desk pod. A cool gray floor contrasts with its charcoal desk, laptop computer, two synchronized external monitors and high-back chair. Reference-inspired accessories include a detailed keyboard, camera, drawing tablet, speakers, microphone boom, copier and articulated task lamp. The current main session owns its reserved desk (otherwise the first visible main session by ID); bots use shared desks. The office has 22 shared desks plus this private desk, with existing standing overflow behavior for larger rosters.
- The office renders every non-default Bot profile, including profiles hidden from normal selectors, so the physical roster remains complete. The outdoor footprint is fixed around the building and a short two-chair patio with one table. The lower entrance garden adds deterministic varied trees, shrubs, stones, planters, lighting, and a bike rack so the exterior feels populated without blocking indoor navigation. Taskless bots begin at one of four indoor activities—coffee, reading, strolling, or socializing—and continue to rotate among those reachable locations. The patio remains a small optional lounge destination rather than the default idle area.

- Control → More → Office Preview renders a furnished 3D office and garden built locally from original RealityKit geometry (no purchased assets). Every visible bot gets one stable chibi character matched to Kanban tasks by profile ID: running work goes to the computers, review to the boardroom, planning to the Kanban room; idle bots take patio breaks, coffee, and walks. Task ownership and status are live; office actions are simulated.
- Specialist interiors replace the small meeting rooms with a Design Studio and QA / Verification lab, and the quiet-room/phone-booth area with Server / Operations. The former boardroom is Mission Control, retaining review seating. The east-side Bot Workshop uses open modular desks. Room identity comes from physical models (drafting tools, material samples, test devices, racks, cooling and consoles); these accessories do not report runtime telemetry or automatically assign bots by specialty. The corkboard lives in the studio and the shared planning sofa provides the reading spot.
- Live Nexus avatars render for working or attention-needed conversations. Status icons, hover details, a task board, workspace/whole-office camera presets, and full keyboard camera navigation (WASD/arrows, Q/E, R/F, +/−, Shift; Home resets). Reduce Motion disables travel, pulses, and decorative animation.

### Presentation

- Native macOS menu-bar presentation: appearance-aware navy surface, system typography, native controls, restrained selection, divider-led sections, and a deliberate compact type scale.
- Optional right-edge Dock notch: a separate hover/click launcher expands into the Dock without replacing the menu-bar icon; click pins it open and Escape/close collapses it.
- Status colors are reserved for meaning (blue active, green healthy, amber warning, red failure).
- Menu-bar unread badge for hidden completed/attention work; narrow-screen mode swaps Ask/Control as a single pane; adaptive composer grows to six lines then scrolls.

## How it works

```text
menu-bar popover ─SwiftUI─► Dock services ─WebSocket /api/ws─► local Hermes gateway
                                   │                            (loopback-only, authenticated)
                                   └── capability-gated Hermes CLI (shell.exec) for kanban, cron, update
```

- **Local connection.** On launch the Dock starts a loopback-only Hermes backend, establishes an authenticated WebSocket session, and speaks the TUI Gateway JSON-RPC protocol (`session.create`, `prompt.submit`, `session.interrupt`, `approval.respond`, streamed messages, approval requests).
- **Hermes is authoritative.** Sessions, agents, prompts, models, skills, profiles, MCP, and cron belong to Hermes; Apple Reminders owns reminder content; local Git/GitHub own repository data. The Dock stores references, display state, UI preferences, and cached metadata — never a second copy of those systems. Credentials, memory, profile paths, and tool payloads never enter Dock state.
- **Capability-gated, fail-closed controls.** Every optional control is classified at runtime (verified gateway RPC, stable read-only CLI projection, confirmed CLI mutation, unsupported, or external setup). Mutation probes require the documented help terms the Dock will actually send. A missing or failed probe fails closed: the control stays unavailable (or stale-with-last-good-projection), and support is never inferred from a version string.
- **Control authority.** Model/reasoning changes are explicit Hermes mutations applied to the next turn. Skills and plugin management stay with Hermes. MCP inventory is read-only with a confirmed session-scoped reload. Recovery guidance is copy-only; the Dock never runs recovery commands or `hermes update` automatically.
- **Architecture in the codebase.** Transport and process-launch concerns live in gateway/runtime services, persistent workspace state in `WorkspaceStore`, presentation state in `DockModel`; new parsing/state-transition behavior is extracted into testable helpers instead of expanding view types.

## Getting started

```sh
git clone <this repository>
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

## Current limitations

Features below stay intentionally unavailable until Hermes exposes a stable, capability-advertised contract:

- **Project mutation** (creation/activation/archive/deletion) — Kanban board enumeration is available today.
- **Third-party MCP discovery/invocation** (scoped authorization, tool schemas, redacted results) — read-only MCP inventory and connection tests are available today.
- **Structured cron reports** and richer diagnostics beyond the live CLI projections.
- **Provider-neutral realtime audio** (voice-session lifecycle RPCs and model audio-capability metadata).
- **Calendar access** (provider capability, authorization state, stable event operations).
- **Durable activity feeds, fleet session usage, authoritative project repository enumeration.**
- Bot profile deletion (no gateway RPC yet), group chats, cross-machine connections, bot-to-bot @mention autocomplete.

Voice today uses Hermes' native continuous loop when available, with the labelled local fallback otherwise; true provider-native realtime audio (bidirectional voice sessions, streamed PCM, provider VAD metadata) remains gated on a Hermes voice-session gateway protocol and is not yet implemented.

## Maintaining this document

Every user-facing feature or behavior change must update the relevant section of this README in the same change set. Mark incomplete work as planned, and never describe mock data or provider capabilities as live functionality. Calendar, email, iMessage, automation fields Hermes does not return, and third-party MCP browsing remain planned follow-on integrations.
