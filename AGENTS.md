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
| `DESIGN.md` | Before touching any user-facing view (UI source of truth; see below) |
| `CONTRIBUTING.md` | Full local loop and PR checklist |
| `docs/adr/` | Recorded exceptions and decisions |

If `graphify-out/` or `.codegraph/` exists locally, query it before grepping.

`DESIGN.md` is about 4,000 lines; do not skim it whole. Before a UI change, run
`grep -n '^##' DESIGN.md`, read the Design system and Layout and interaction
rules entries for the components you use, then the `###` section of the surface
you touch. Put new specs inside that surface section, never at the top or end
of the file (`make guard` rejects both).

A rule that is only written down is advisory. When a review catches the same
mistake twice, add it to a `Scripts/check-*.py` contract instead of more prose.

## Commands

```sh
make build                     # debug build
swift test --disable-automatic-resolution --filter <SuiteName>   # iterate
make guard                     # fast deterministic gate: strict lint + colors + diff checks
make format                    # fix mechanical Swift formatting
make check                     # full gate: guard + tests + smoke + release build (CI runs this)
```

- Run the relevant filtered suite locally. Do not run the full suite or
  `make package` (DMG) locally unless asked; CI runs `make check`.
- Run `make guard` before review. Fix its file/line diagnostics first; use AI
  review for behavior, ownership, concurrency, and UI decisions. Do not weaken
  lint rules or expand color exceptions just to make a check pass.
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
- The app is named **Herm** everywhere; its bundle ID is `io.github.chryzxc.Herm`.

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

## Product naming

- **Herm** is the client app. Use it for app chrome, navigation, local companion
  headings, default assistant labels, and actions that open Herm chats or reviews.
- **Hermes Agent** is the backend. Keep Hermes in backend connection/setup,
  runtime diagnostics, profiles, shared configuration, provider credentials,
  updates, and references to the official Hermes Desktop client.
- Never rename Hermes commands, executable names, API/RPC methods, wire values,
  environment variables, storage paths, error domains, or source identifiers as
  part of a copy change. Preserve user-configured bot and agent names.
- Run `make naming-contract`. It catches bare Hermes default labels and common
  client-branding regressions; review other copy using the distinction above.

## UI consistency

- Color changes start in `Sources/Herm/DesignSystem/DockAccentPalette.swift`
  (solid reference colors) or `DockTheme.swift` (skin surfaces/interaction).
  New features use `Color.dock*` roles or `DockAccentColor`: `.fill` for solid
  artwork/data marks, `.color` for readable ink. Do not invent feature palettes.
  Neutral skins use gray interaction/selection; character skins keep their own
  hue. Status/identity colors never become a global blue interaction override.
  Run `make color-contract`; CI rejects new feature-local literals. Existing
  counted source/legacy exceptions must not be expanded to bypass the check.
  See `docs/color-system.md` for examples and source-color exceptions.

- Full-window or expanded presentations use `DockExpandedPage` (see
  `docs/expanded-pages.md`). Never hand-roll a header for an expanded layer;
  it draws under the window controls.
- Boxed surfaces use `.dockCard` (`isActive:` for hover/selected); never hand-build a
  fill+stroke box. Insets use `.dockWell`, label capsules `.dockPill(tint:)`, meters
  `DockProgressBar`. If none fits, extend the component rather than styling at the call site.
  Run `make card-contract`; see `docs/cards.md`.
- Match the closest existing component before introducing a new visual
  treatment. Reuse shared `Dock*` components and color tokens.
- Text actions use `.dockPrimary` for local priority and `.dockSecondary` for
  companions. Size belongs to their common container: `.dockButtonSize(.compact)`
  (28pt default, including Settings pages), `.standard` (36pt, modal form
  footers only), or `.accessible` (44pt decisions); `make button-contract`
  rejects new `.standard`/`.accessible` uses. `.dockCompact` is a compatibility alias, not an independent size. Never size
  individual action labels with height/vertical padding or use native
  `.controlSize` to size Herm actions. Modal footers supply standard size.
  Run `make button-contract`; see `docs/button-sizing.md` for rules and audit.
  Clickable text must be recognizable before hover. Use `.dockLink` for inline
  navigation; reserve `.dockHover` for rows, tabs, icons, disclosures, and content
  tiles with a visible interaction cue. Never use `.plain` or `.borderless` for
  standalone text actions. Linked metadata pills need a navigation icon and
  underline; static pills must not. Check disabled, pending, keyboard-focus,
  Light, Dark, Glass, and Monochrome states. Hover alone is insufficient.
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
