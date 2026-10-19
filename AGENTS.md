# Herm — agent guide

Herm is a native macOS (14+) menu-bar app, written as a Swift package in
SwiftUI, that acts as the desktop front end for a local Hermes agent runtime.
Hermes owns all agent and runtime state; Herm projects and drives it.

This file is the single source of truth for every coding agent. `CLAUDE.md`
and `GEMINI.md` are symlinks to it. Shared skills live in `.agents/skills/`;
`.claude/skills` points there.

## Read first

| Doc | When |
|---|---|
| `ARCHITECTURE.md` | Repo map, module ownership, data flow, contracts |
| `STANDARDS.md` | Naming, errors, testing, Definition of Done, commits |
| `DESIGN.md` | Before touching any user-facing view (UI source of truth) |
| `CONTRIBUTING.md` | Full local loop and PR checklist |
| `docs/adr/` | Recorded exceptions and decisions |

If `graphify-out/` or `.codegraph/` exists locally, query it before grepping.

## Commands

```sh
make build                     # debug build
swift test --disable-automatic-resolution --filter <SuiteName>   # iterate
make lint                      # swift-format check (pre-existing debt is reported, not fatal)
make check                     # full gate: lint + tests + smoke + release build (CI runs this)
```

- Run the relevant filtered suite locally. Do not run the full suite or
  `make package` (DMG) locally unless asked; CI runs `make check`.
- Never run `make run` / `Scripts/run-debug-app.sh` unless asked. Relaunching
  kills the user's live Herm agents.

## Boundaries

- Herm is the front end only. Build features from existing Hermes RPCs, events
  and CLI commands. Never patch or propose changes to the Hermes engine
  (`~/.hermes/hermes-agent` is read-only).
- Transport and process launch live in `HermesRuntime/`. Hermes CLI commands
  are built as quoted words in `HermesCLIAdapter` and are capability-gated.
- `WorkspaceStore` holds local preferences only. Never add a second durable
  store for Hermes-owned data (sessions, agents, Kanban, terminal output).
- Views render state; they do not parse RPC, build CLI words, or persist.
- The app is named **Herm** everywhere. `HermesAgentDock` survives only in the
  settings migration.

## Code and tests

- Swift 6 (tools 6.0), 4-space indent, subsystem prefixes (`Dock*`, `Hermes*`).
  Put files in the module that owns the concern.
- New parsing and state-transition logic ships with tests in `Tests/HermTests/`.
  Extract pure helpers rather than testing views.
- Every failure gets an honest unavailable/stale state. Never invent data.
  External errors go through `HermesDiagnosticsService.safeSummary`.
- No secrets in Herm state, logs, tests or commits.

## Commits and PRs

Conventional Commits (`feat: …`, `fix: …`), lowercase, imperative, one
reviewable behavior per commit. Update `README.md` (and `DESIGN.md`) for
user-visible changes. Do not commit or push unless asked.

## UI consistency

- Match the closest existing component before introducing a new visual
  treatment. Reuse shared `Dock*` components and color tokens.
- Clickable text must be recognizable before hover: use `.dockCompact` for
  small actions, `.dockSecondary` for standard actions, `.dockPrimary` for the
  local primary action, and `.dockLink` for inline navigation or Show more.
  Never style a standalone text action as `.plain`, `.borderless`, or
  `.dockHover`. Reserve `.dockHover` for rows, tabs, icons, and disclosures
  whose label already supplies a visible interaction cue. Linked metadata
  pills must include a navigation icon and underline; static pills must not.
  Check resting, disabled, keyboard-focus, and pending states in light, dark,
  Glass, and monochrome themes. Hover feedback alone is insufficient.
- Use 16pt semibold only for page headers. Use 12pt semibold titles and 12pt
  detail text for compact empty states, matching existing repository and
  session empty-state components. Dense metadata may use 11pt where an
  adjacent established component already does.
- Do not add decorative dashboards, speculative controls, or placeholder
  content. Every control and status must reflect a real capability or state.
- Do not add passive lifecycle labels (for example, `IDLE` or `READY`) unless
  they change a user decision or accompany an actionable recovery path. Do
  not add controls, labels, or secondary functions merely to fill space.
- An interactive surface must make its primary interaction work immediately.
  For example, a terminal must open in a valid directory and accept typed
  commands; it must not render a disabled shell or explanatory chrome instead.

## Layout stability

- Do not insert or remove transient loading, retry, or projection rows above a
  page header or primary content. Put short status in an existing fixed slot
  (such as a header subtitle or control spinner) so refreshes do not make the
  page jump.
- Keep loading, empty, unavailable, and loaded states within the same stable
  container and maintain the surrounding layout whenever practical.
