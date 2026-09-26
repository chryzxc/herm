# Hermes Agent Dock Composer Directives Design

## Goal

Bring Hermes Agent Desktop composer parity to the Dock for `@` references, Bot mentions, `/` commands, skill commands, argument completion, execution, and visible transcript rendering.

## Scope

The Dock supports the Desktop directive families: `@file:`, `@folder:`, `@url:`, `@image:`, `@tool:`, `@git:`, Bot/profile mentions, leading slash commands, inline slash references, skill/quick commands, command arguments, and visible command/reference text in user bubbles.

## Architecture

Hermes remains authoritative for command catalogs, completion results, profile/session routing, and execution. The Dock adds a pure composer-trigger parser, a typed completion service over `commands.catalog`, `complete.slash`, and `complete.path`, and a submission model separating raw/display text from normalized execution text. The existing Bot picker becomes a contributor to the unified `@` completion path.

Leading `/command` invocations are dispatched through Dock-owned actions, dedicated Hermes RPCs, or `slash.exec`/`command.dispatch` fallback. Inline `/skill` references remain ordinary prompt text. User bubbles always render the original visible command or mention exactly once.

## Transcript contract

`ChatMessage.text` must contain the user-visible command/reference text. Execution normalization must never replace or suppress that text. A command submission must produce one durable user message and separately render command output or the assistant response.

## Compatibility

The Dock probes completion/execution capabilities and preserves a Bot-only fallback when `complete.path` is unavailable. Missing capabilities render honest unavailable states; the Dock does not create a second command registry or shell-based interactive completion path.

## Non-goals

No changes to the upstream Hermes Agent runtime, no new core command system, no unrelated composer redesign, no rich transcript chips before plain-text parity is proven, and no changes to canonical Bot Chat identity.

## Acceptance

- `@` and `/` trigger detection works at the caret and respects whitespace/path boundaries.
- Desktop-backed completion contracts are used with session/profile context.
- Bot, path, URL, Git, tool, skill, quick-command, and slash-command flows are covered.
- Leading and inline slash forms are distinguished.
- Original `@`/`/` text is visible in the user bubble and is not duplicated.
- Focused tests and `swift test` pass, excluding only verified pre-existing failures.
