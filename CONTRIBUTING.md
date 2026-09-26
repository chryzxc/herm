# Contributing to Herm

Herm is a native macOS Swift package. Hermes remains the
authoritative owner of agent/runtime state; local repository, terminal, and
integration features must preserve that boundary.

## Prerequisites

- macOS 14 or newer
- Xcode with Swift 6 and the `swift-format` tool (`xcrun --find swift-format`)
- A working Hermes installation for manual runtime checks

## Local loop

Run the complete required check from the repository root:

```sh
make check
```

The formatter currently reports the repository's pre-existing style debt as
diagnostics while the mechanical formatting pass is kept separate from feature
changes. A future formatting-only PR can promote this to a strict failure gate
without mixing thousands of whitespace changes into behavior work.

Individual commands are available when iterating:

```sh
make test          # unit/model/transport tests
make build-release # production compilation
make lint          # formatter check, no edits
make format        # explicitly rewrite Swift formatting
make smoke-contract # launcher syntax + UI accessibility contract
make run           # build/sign/launch the debug app bundle
make package       # produce dist/Herm.dmg
```

The debug launcher is `Scripts/run-debug-app.sh`. Do not use `swift run` for
manual menu-bar focus testing. `make package VERSION=1.2.3` creates the
versioned release DMG.

## Before opening a PR

1. Add or update focused tests for behavior changes.
2. Run `make check` and record any environment-only limitation.
3. Perform a manual wide/narrow popover check for UI changes.
4. Verify pending, unavailable, stale, failure, and confirmation states.
5. Update `README.md` and `DESIGN.md` when user-visible behavior changes.
6. Keep privacy, persistence, capability, and architecture changes in separate
   reviewable commits.

For parity surfaces, document the source of truth and lifecycle explicitly:
Hermes owns agent/runtime state; local Git/GitHub and Apple integrations own only
their declared projections. Every mutation must state whether it is confirmed,
whether it affects the active session or only subsequent sessions, and what the
user sees when the capability is unavailable, denied, malformed, or stale.
Inventories do not imply mutation authority. Skills, plugins, MCP server
management, provider setup, and third-party MCP invocation remain unavailable
unless the installed Hermes contract is verified. An update requires an explicit
confirmation and a Hermes restart for new sessions; recovery guidance is
copy-only unless a named action is implemented.

Never add a second durable store for Hermes sessions, agents, Kanban records,
external issues, repository state, or terminal output. Provider mutations must
be capability-gated, typed, explicitly confirmed, and covered by tests.

## Test selection

Use Swift Testing or XCTest filters during iteration, for example:

```sh
swift test --disable-automatic-resolution --filter RepositoryCodeWorkspaceTests
swift test --disable-automatic-resolution --filter HermesCapabilityServiceTests
```

The full suite is required before merge. Network and live third-party accounts
must not be required by tests; use deterministic fixtures and test doubles.

## Manual smoke check

After `make run`, verify launch, global shortcut, session restoration, prompt
streaming, clarification/approval actions, repository Changes, capability
refresh, and the narrow-screen Ask/Control transition. For terminal or
integration work, additionally verify that session/project switches cannot
route an action to the previous context and that unavailable providers fail
closed.
