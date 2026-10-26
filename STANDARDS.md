# Herm — Engineering Standards

updated: 2026-09-15 · enforced-by: Sentry review · exceptions: none without an ADR

## Style & naming

Swift 6 / SwiftUI, 4-space indentation. Types are prefixed by subsystem (`Dock*` for shared presentation, `Hermes*` for runtime boundary). Files live in the module directory that owns the concern — no cross-module grab-bags. Prefer value types and `enum` namespaces; mark UI-adjacent helpers `static` and pure so they stay testable.

## Error handling

Every failure has a user-visible honest state: unavailable, stale, or a safe diagnostic. Never invent data to fill a failed projection. External errors pass through `HermesDiagnosticsService.safeSummary`/`safeUserDiagnostic` before display. Fatal-style states (failed capability probes) fail closed and keep prior projections marked stale.

## Testing

`swift test` before every submit; new parsing/state-transition behavior ships with unit tests in `Tests/HermTests/` — extract logic into testable helpers instead of testing view types. UI contract changes that Hermes gates (kanban commands, capability terms) get adapter-level tests asserting the exact quoted-word command. No test count targets; no mocked-up evidence labeled as real behavior.

## Definition of Done

A card is COMMIT_READY only when: `swift build` and the relevant focused suite are green; README updated for any user-facing change (documentation rule); capability-gated controls verify their probe terms, not just `--help` exit codes; no credential-shaped value appears in UI, logs, or tests; layout-stability and empty-state rules from `AGENTS.md`/`DESIGN.md` are respected.

A feature is available to Generative UI only after its component or adapter is
registered, its availability is verified, its example passes contract tests, and its
actions reuse established handlers. Do not advertise an RPC name as an implemented UI.

## Boundaries

Transport and process-launch concerns stay in `HermesRuntime/` gateway services; persistent workspace state in `WorkspaceStore`; presentation state in `DockModel`. Views render state — they do not own RPC parsing, CLI word-building, or persistence. The Hermes engine install (`~/.hermes/hermes-agent`) is read-only; Herm features extend through verified Hermes contracts or user-state helper scripts, never engine patches.

## Git & commits

Conventional Commits, lowercase type, imperative summary scoped to the one-commit boundary (`feat: attribute kanban sessions without engine patches`). One independently reviewable behavior per commit. No issue/PR metadata in messages; no unrelated work riding along. Never commit secrets, credentials, or `.env` content.

## Observability

`DebugLog.write` for local diagnostics; user-facing status comes from Hermes-reported state. New failure modes need an explicit empty/unavailable state, not silent blanks.

## Security baseline

Secrets never enter Herm state (single sanctioned exception: the explicit SOUL.md editor write path). Provider keys live only in owner-only local provider config. Suspected credential values detected by the pre-commit signal pass are never repeated anywhere. Attachments re-validate size limits immediately before upload.

## Exceptions

None. Record any deviation as an ADR in `docs/adr/` with an expiry.

## Action sizing

All filled/outlined text actions use shared `DockButtonMetrics`; role changes
emphasis, not height. Set `.dockButtonSize` on the common action container.
`make button-contract` is required through `make guard`; no label-height or
per-button size exceptions are accepted. Follow `docs/button-sizing.md` and run
`DockButtonSizingTests` after changing shared action metrics.
