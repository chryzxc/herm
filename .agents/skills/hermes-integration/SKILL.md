---
name: hermes-integration
description: Add or change a Herm feature that talks to Hermes (JSON-RPC method, streamed event, or `hermes` CLI command). Use when wiring new runtime data or mutations into Herm.
---

# Wiring Herm to Hermes

Herm is the front end only. Build features from existing Hermes RPCs, events and CLI
output. Never patch `~/.hermes/hermes-agent` or propose engine changes. If the
contract you need does not exist, stop and tell the user.

1. **Confirm the contract exists.** Check `ARCHITECTURE.md` → Contracts and the
   existing callers in `Sources/Herm/HermesRuntime/`. For CLI, confirm the exact
   subcommand and flags against the installed `hermes <cmd> --help`.
2. **Transport stays in `HermesRuntime/`.** RPCs go through `HermesControlRPC`.
   Build CLI commands as quoted words in `HermesCLIAdapter`, never as
   interpolated strings.
3. **Gate on capability.** Gate the control on `HermesCapabilityService` probe
   terms, not just the `--help` exit code, and fail closed: when the capability
   is missing, show an unavailable state.
4. **Project, don't own.** Parse into `DockModel`/`ControlCenterModel` state.
   Hermes responses are authoritative. Do not show final state optimistically,
   and do not keep a second durable copy in `WorkspaceStore`.
5. **Mutations** must be typed and explicitly confirmed. They must state whether
   they affect the active session or only later sessions.
6. **Errors** go through `HermesDiagnosticsService.safeSummary` before display.
7. **Tests:** cover the parsing and state transitions, plus an adapter test that
   asserts the exact quoted-word command. Use fixtures; never call a live Hermes.

8. **Generative UI:** expose a feature only after its typed component/adapter is
   registered, availability is verified, its example passes contract tests, and
   actions reuse established handlers. Register connected record readers and
   resolvers together in `RichHostActionRouter.Feature`; the next submission's
   catalog derives from `RichFeatureRegistry`, not a second handwritten prompt.
   An RPC name alone does not establish a working generated interface.

Then follow `verify-change`.
