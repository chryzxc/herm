# Hermes Agent Dock Composer Directives Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Hermes Agent Desktop parity for `@` references/Bot mentions and `/` commands/skills to the Dock composer while preserving the original directive text in chat bubbles.

**Architecture:** Hermes remains authoritative through `commands.catalog`, `complete.slash`, `complete.path`, and existing command/RPC dispatch paths. The Dock adds pure trigger parsing, typed completion/submission models, unified composer presentation, and transcript-safe display/execution separation; the existing Bot picker becomes one `@` completion contributor.

**Tech Stack:** Swift 6, SwiftUI, AppKit `NSTextView`, existing Hermes JSON-RPC transport, Swift Testing, Swift Package Manager.

**Spec:** `docs/superpowers/specs/2026-09-22-composer-directives-design.md`

## Global Constraints

- Work only in `/Users/christian/Projects/hermes-agent-dock`; the upstream Hermes Agent checkout is read-only.
- Preserve all existing tracked and untracked work; do not reset, stash, clean, or overwrite the dirty baseline.
- Hermes owns sessions, profiles, commands, skills, and execution; Dock owns only presentation and transient composer state.
- User-visible command/reference text must remain in `ChatMessage.text` and render exactly once.
- Leading slash invocations and inline slash references must remain distinct.
- Missing backend capabilities fail closed with an honest unavailable/fallback state.
- Every behavior change updates README and the repo map in the same delivery.
- Use focused Swift tests after each slice and `swift test` before completion.
- Keep each implementation slice independently reviewable with one commit boundary.

---

## Task 1: Add pure directive parsing and submission types

**Files:**
- Create: `Sources/HermesAgentDock/Conversation/ComposerDirectives.swift`
- Modify: `Sources/HermesAgentDock/Conversation/ComposerText.swift`
- Test: `Tests/HermesAgentDockTests/ComposerDirectivesTests.swift`
- Test: `Tests/HermesAgentDockTests/ComposerTextTests.swift`

**Interfaces:**
- Produces `ComposerTriggerKind`, `ComposerTrigger`, `ComposerDirectiveParser.detect(textBeforeCaret:)`, `ComposerSubmission`, and `ComposerSubmissionBuilder`.
- `ComposerTrigger` carries `kind`, `query`, `tokenLength`, `isInline`, optional `scope`, and slash argument-stage state.
- `ComposerSubmission` carries `rawText`, `displayText`, `executionText`, and optional directive classification.

- [ ] Write failing tests for bare `@`, Bot queries, `@file:`/`@folder:` paths containing `/`, leading `/command`, inline `/skill`, whitespace boundaries, and free-text slash arguments.
- [ ] Run `swift test --filter ComposerDirectivesTests` and verify the new tests fail for missing parser symbols.
- [ ] Implement boundary-anchored pure parsing with Desktop-compatible rules: `@` ends at whitespace, path slashes remain inside `@` tokens, only a leading slash is executable, and later slash tokens are inline references.
- [ ] Implement submission construction so `displayText` preserves the original draft while `executionText` can be normalized independently.
- [ ] Run `swift test --filter ComposerDirectivesTests` and `swift test --filter ComposerTextTests`; both must pass.
- [ ] Commit with `feat(composer): add desktop directive parsing`.

## Task 2: Add typed RPC contracts and completion service

**Files:**
- Modify: `Sources/HermesAgentDock/HermesRuntime/HermesFeatureContract.swift`
- Modify: `Sources/HermesAgentDock/HermesRuntime/HermesControlTransport.swift`
- Create: `Sources/HermesAgentDock/Conversation/ComposerCompletionService.swift`
- Test: `Tests/HermesAgentDockTests/ComposerCompletionServiceTests.swift`

**Interfaces:**
- Produces typed request/response models for `commands.catalog`, `complete.slash`, and `complete.path`.
- Produces `ComposerCompletionItem` with stable ID, display text, insertion text, description, group, and source kind.
- Produces async completion methods that accept session/profile/workspace context and ignore stale request generations.

- [ ] Write failing tests for exact RPC names, session/profile propagation, catalog/argument completion mapping, path completion mapping, and stale-result suppression.
- [ ] Run `swift test --filter ComposerCompletionServiceTests` and verify failure.
- [ ] Add transport feature identifiers and typed decoding without exposing raw dictionaries to SwiftUI views.
- [ ] Implement bounded cache/in-flight generation handling so a response for an older draft cannot replace current completion items.
- [ ] Merge existing Bot inventory into `@` results without replacing backend path results.
- [ ] Add fallback behavior when `complete.path` or slash completion methods are unavailable.
- [ ] Run `swift test --filter ComposerCompletionServiceTests` and `swift test --filter HermesFeatureContractTests`.
- [ ] Commit with `feat(composer): add Hermes directive completions`.

## Task 3: Replace the Bot-only picker with unified `@`/`/` completion presentation

**Files:**
- Modify: `Sources/HermesAgentDock/Conversation/ChatComposerView.swift`
- Modify: `Sources/HermesAgentDock/Conversation/DockSupplementaryViews.swift` or the closest existing picker component.
- Modify: `Sources/HermesAgentDock/Conversation/ComposerText.swift`
- Test: `Tests/HermesAgentDockTests/ComposerTriggerPresentationTests.swift`
- Test: `Tests/HermesAgentDockTests/ComposerLayoutTests.swift`

**Interfaces:**
- Composer observes `ComposerTrigger`, `ComposerCompletionService`, loading/error state, and selected index.
- Selection replaces only the active token and preserves preceding/following text.

- [ ] Write failing tests for unified trigger visibility, `@` space behavior, slash argument behavior, token replacement, Tab/Enter/Escape, and empty/unavailable states.
- [ ] Run the focused tests and verify failure.
- [ ] Add one stable popover surface using existing Dock tokens and layout rules; group rows into Commands, Skills, Options, and reference categories.
- [ ] Wire text changes to trigger detection and completion requests without making the parent conversation tree observe every keystroke.
- [ ] Implement keyboard selection rules matching Desktop: Tab accepts; Enter/Space do not steal free-text slash arguments; Escape dismisses.
- [ ] Preserve the current Bot refresh and direct-routing behavior as a contributor/fallback, not as a second picker.
- [ ] Run `swift test --filter ComposerTriggerPresentationTests` and `swift test --filter ComposerLayoutTests`.
- [ ] Commit with `feat(composer): unify directive completion picker`.

## Task 4: Route slash submissions and preserve command text

**Files:**
- Modify: `Sources/HermesAgentDock/Conversation/DockModel.swift`
- Modify: `Sources/HermesAgentDock/Conversation/ChatComposerView.swift`
- Modify: `Sources/HermesAgentDock/HermesRuntime/HermesFeatureContract.swift`
- Test: `Tests/HermesAgentDockTests/SlashCommandSubmissionTests.swift`
- Test: `Tests/HermesAgentDockTests/DirectBotRoutingTests.swift`

**Interfaces:**
- `DockModel.submitComposerInput()` consumes `ComposerSubmission`.
- Command routing uses a typed `ComposerCommandRouter` or equivalent extracted helper rather than a SwiftUI switch ladder.
- User transcript append receives `displayText`; backend dispatch receives `executionText`.

- [ ] Write failing tests for one visible `/status` user message, inline `/skill` ordinary prompt behavior, leading command routing, skill/quick-command fallback, direct Bot mention preservation, and failed execution retaining the user bubble.
- [ ] Run the focused tests and verify failure.
- [ ] Implement Dock-owned action routing for commands already represented by model methods.
- [ ] Implement dedicated RPC routing where the feature contract exposes a structured method, then `slash.exec` and `command.dispatch` fallback for backend-owned commands.
- [ ] Ensure local transcript insertion and Hermes prompt submission cannot create duplicate user messages.
- [ ] Keep attachments on their existing safe path unless the referenced directive is supported by the same submission contract.
- [ ] Run `swift test --filter SlashCommandSubmissionTests` and `swift test --filter DirectBotRoutingTests`.
- [ ] Commit with `feat(composer): execute desktop slash commands`.

## Task 5: Verify message-bubble, copy, accessibility, and transcript behavior

**Files:**
- Modify: `Sources/HermesAgentDock/Conversation/ConversationMessageRow.swift`
- Modify: `Sources/HermesAgentDock/Conversation/ConversationMessageActions.swift` if needed.
- Test: `Tests/HermesAgentDockTests/ConversationMessageRowTests.swift`
- Test: `Tests/HermesAgentDockTests/ConversationMessageActionsTests.swift`

**Interfaces:**
- `ConversationMessageRow` continues to consume `ChatMessage.text`; no special hidden command state is allowed.
- Equality/content revision must continue to invalidate rows when visible directive text changes.

- [ ] Add failing tests for visible `/command`, `@bot`, and `@file:path` bubbles, wrapping, copy output, and accessibility labels.
- [ ] Run the focused tests and verify failure.
- [ ] Adjust only the minimum rendering/accessibility code required; preserve existing Markdown and attachment behavior.
- [ ] Confirm empty-command output does not hide a non-empty user directive.
- [ ] Run `swift test --filter ConversationMessageRowTests` and `swift test --filter ConversationMessageActionsTests`.
- [ ] Commit with `fix(conversation): preserve composer directives in transcript`.

## Task 6: Documentation, architecture map, and full verification

**Files:**
- Modify: `README.md`
- Modify: `ARCHITECTURE.md`
- Test: relevant existing suites and full package test run.

- [ ] Document `@` references, Bot mentions, `/` commands, inline slash references, backend compatibility, and visible transcript behavior in README.
- [ ] Update the repo map contracts, data flow, test map, and sharp edges with the new composer RPC path.
- [ ] Run all focused suites from Tasks 1–5.
- [ ] Run `swift test` from `/Users/christian/Projects/hermes-agent-dock`.
- [ ] Record the known pre-existing `OfficePreviewSimulationTests.routesConnectEveryActivityThroughWalkableSpace` failure separately if it remains unchanged.
- [ ] Manually verify the acceptance matrix: `@`, `@file:`, folder traversal, `/`, slash arguments, skill command, inline slash reference, Bot mention, visible user bubble, one-message durability, and unavailable capability behavior.
- [ ] Run `git diff --check` and reconcile the final changed-file list against the allowed scope.
- [ ] Commit with `docs: document composer directive parity` only if documentation is independently reviewable; otherwise include README/ARCHITECTURE changes in the owning feature slice.

## Final acceptance commands

```bash
swift test --filter ComposerDirectivesTests
swift test --filter ComposerCompletionServiceTests
swift test --filter ComposerTriggerPresentationTests
swift test --filter SlashCommandSubmissionTests
swift test --filter ConversationMessageRowTests
swift test

git diff --check
```

## Stop conditions

Stop and report instead of guessing when: the gateway does not expose a required contract; session/profile routing cannot be proven; the submission path would duplicate durable user messages; the existing dirty baseline conflicts with the planned write scope; a focused test remains RED after five minutes; GREEN is not reached by 80% of the task budget; or a normal verification step requires `--forceExit`.
