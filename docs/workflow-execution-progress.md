# Herm workflow implementation

This tracks execution of the approved workflow roadmap.
Herm's notch and quick preview remain the primary interaction. Hermes owns execution, sessions,
integrations, scheduling, and durable knowledge; this roadmap changes Herm only.

## Notch improvement iteration — 2026-10-13

The follow-up plan is implemented in Herm's source, with release checks in progress:

| Release | Implementation | Evidence / remaining gate |
| --- | --- | --- |
| A: baseline and live validation | Frozen-source validation; opt-in dedicated-profile native harness; local timing report | Supported model-free contracts pass; named owned resume and PDF rendering unavailable on installed runtime |
| B: keyboard preview | Explicit shortcut mode, scoped selection, arrows/Return, Escape hierarchy, outside dismissal and guarded focus return | Selection regressions pass; end-to-end VoiceOver/focus acceptance remains |
| C: saved actions | Four editable starters, custom actions, optional bound destination, draft-only preparation, confirmed retarget with original material retained | Preparation and persistence tests pass; no automatic execution |
| D: checkpoints | Separate user-note store, exact draft reference, destination membership validation, restore only notch context, explicit clear | Exact/missing/invalid draft tests pass; no transcript or workspace restoration |
| E: comparison | Two bounded observed reads retained for explicit comparison; line changes and added/removed output references | Text reconstruction and long-result fallback tests pass; native render reviewed |
| F: working-set watch | One persisted set, scoped metadata reads, bounded concurrency, existing event subscription, global blocking decisions/failures | Profile collision, wrong owner, cancellation, disconnect, concurrency and no timer tests pass |

The existing 368 × 360pt preview is retained. New bodies reuse stable header/scroll/footer
slots and shared Dock controls. Actions/checkpoint notes persist in
`Application Support/Herm/WorkflowContent/content-v1.json` (versioned, atomic, 0600 file /
0700 directory). Preferences hold only references, including the watched set ID.
Application termination flushes both the quick draft and workflow-content stores.

Validation so far: 52 focused tests in seven suites passed, followed by 22 tests in seven
suites for watch, persistence, preparation, checkpoint restoration, comparison and native
rendering. Native captures are under `/tmp/herm-next-workflow-renders`.
The first full check ran 1,309 tests with one login-shell fixture startup failure. The fixture
now waits for real command execution before sending backspace-sensitive input; its focused
recheck passed (20 tests / three suites). A full rerun passed 1,310 tests / 145 suites and the
accessibility contract check. The final snapshot then passed 1,311 tests / 145 suites and
the accessibility check, including structured completion-error handling. The final release
build passed in 533.24 seconds; `make check` exited successfully. The frozen check ran in
`/tmp/herm-next-iteration-validation`, using `/tmp/herm-next-iteration-build`, with its log at
`/tmp/herm-next-final-check3.log`. The final native-render/regression run passed 16 tests /
five suites in 2.159 seconds, verifying that checkpoint inspection preserves its exact saved
draft association and note timestamp. Autosaved note edits retain the association; explicit
Save checkpoint can associate a matching current draft only while capture/submission is inactive.
The final source/test hash comparison found zero drift from the working tree. Git HEAD remained
`a683e249793c7df230cdd5b88c66441187120fe3`; staged work and existing edits were preserved.
The check validates those frozen bytes, not any future edits. Existing compiler/lint warnings remain.

Live acceptance used only profile `herm-acceptance-20261013-52085be1`, created through Hermes
without cloning credentials. It creates fixture sessions/material and never submits a model
turn, changes a routine/integration, or alters another profile. Supported connection/capability,
profile identity, idempotent explicit-directory creation, scoped inventory/result, generic-file
reference and image-upload/detach checks passed. The named lazy resume omits profile identity,
so Herm deliberately refuses owned actions. `pdf.attach` requires unavailable `pdftoppm`.
These are compatibility limitations, not passed operations. The final native acceptance policy test
passed in 6.132 seconds, with six supported operation checks and two unavailable operations
recorded honestly. Its local report is
`/var/folders/2v/20clxg7n0112j2sfxvvk5lc40000gn/T/HermWorkflowAcceptance/1ACE331B-2D56-4CD6-BD25-768BDF47AD6A/report.json`. The test profile and its fixture
sessions are retained for further acceptance; no user data was removed.

Run further model-free checks with:

```sh
Scripts/check-workflow-runtime.sh herm-acceptance-20261013-52085be1
```

Local reports contain operation timings, safe error codes, unsupported reasons and fixture
resource references. They contain no credentials, transcripts or analytics transmission.
These timings establish a compatibility baseline; no latency/interruption improvement is claimed.

Remaining release checks: authenticated model turns, approvals/lost acknowledgment against the
live runtime, routine recovery and integration authorization, complete coding/research/automation
flows, keyboard/VoiceOver/focus restoration and reduced-motion interaction. The dedicated
profile has no credentials; configure it through secure Hermes settings to exercise model work.
Source implementation does not establish that these runtime gates are passed.

The sections below record the original roadmap and earlier validation history.

## Phase 0: dependable decisions

Implemented; focused regression checks passed:

- Quick decisions capture their original session, profile when supplied, and request ID.
- Pending state prevents repeated clicks and concurrent answers from the workspace composer.
- Received JSON-RPC refusals retain the request and expose an explicit retry.
- Missing or malformed acknowledgments are uncertain, not successful or automatically retried.
- Approvals can be rechecked with `approval.pending`, and clarifications with the
  `session.events.since` open-request snapshot, before another quick response.
- Clarification choices do not consume the workspace draft, images, or PDF.
- Explicit expiration clears only the matching request. Late acknowledgments cannot clear a replacement.
- File-delivered questions remain until an acknowledged send; replaced questions are not deleted.
- README limitations now distinguish existing group chats and chat-backed cron output from unavailable contracts.

Compatibility boundaries:

| Operation | Accepted result | Unsupported / ambiguous behavior |
| --- | --- | --- |
| `approval.respond` | Nonnegative `resolved` count; zero means no request was resolved | Keep request; block quick resend after an unreadable acknowledgment |
| `request.answer` | `status: ok` or `status: expired` | Keep request; block quick resend after an unreadable acknowledgment |
| `approval.pending` | `approvals` array with usable request IDs | Retain uncertain state if unavailable, malformed, or denied |
| `session.events.since` | `open_requests` array with usable server request IDs, methods, and params | Retain uncertain state if the installed runtime omits this snapshot |

These shapes were checked against the local upstream contracts. A live runtime check remains outstanding.
Older runtimes that omit an authoritative pending-request snapshot leave the answer uncertain.
New requests and confirmed refusals remain actionable. Approval cancellation uses the server request
ID, while approval responses use the distinct tool approval ID; Herm retains both identities.

## Phase 1: Result Peek

Implemented; result regressions and native render checks passed:

- Finished session rows open a saved-result preview inside the existing fixed notch panel.
- An on-demand, profile-targeted `sessionMessages(latest: true)` read loads up to 500 recent messages.
- Only the latest user turn contributes the reply and generated files. Old artifacts and tool-call
  preambles do not become the latest result. An unanswered new turn never reuses the previous answer.
- Copy uses the actual saved text. Reply captures the same destination. Open session is the only
  reading action that navigates the workspace.
- A deliberate successful read marks the matching completion reviewed. Hovering does not. There is no new polling loop or model-generated summary.
- Missing files are identified; relative paths require opening the session. Executables and app
  bundles use the existing artifact opener's Finder behavior.
- A profile switch or collapsed preview clears the selected result. Cancelled reads cannot update a
  replacement preview. Loaded content remains a snapshot until the preview is reopened.

The result is explicitly labeled **Latest completed reply**: it does not claim a durable turn ID that
the installed REST history does not prove. Hermes can resolve an old session ID to a continuation;
an unexpected returned owner is rejected rather than displaying output under an incorrect identity.
GUI focus/accessibility and live runtime checks remain outstanding.

## Phase 2: capture and recovery

Implemented in the current workspace:

- A dedicated versioned QuickDraftStore persists unsent text, explicit profile/session/project,
  source references, file bookmarks and acknowledged upload references. Atomic writes use 0600
  permissions. Pasted images use draft-owned storage; cleanup cannot delete user-selected files.
- Add, drop and paste capture into the independent quick composer. Folders and oversized files
  are rejected; changed or unavailable files stay visible. Preparation runs off the main actor.
- Generic files use `file.attach` and its returned `@file:` reference. Images and one 25 MB PDF
  retain their own attachment contracts. The advertised exclusive-submit capability is required
  for attachment-bearing submission.
- Destination validation precedes uploads and submission. Known partial uploads survive retry;
  runtime, message-count and working-directory changes stop unsafe reuse. New sessions retain
  their durable identity and use the upstream idempotency key. Quick runtime aliases retain owner
  profile/session attribution for subsequent requests and notices.
- Lost or malformed mutation acknowledgments and restored interrupted submissions require review.
  No automatic resend occurs. Successful submission or confirmed discard cleans draft-owned files.
- Result Peek now bounds excerpts to 12,000 characters and 12 outputs, holds at most eight in-memory
  snapshots, and offers explicit Update while the displayed content stays stable.

The initial capture/result/decision contract run passed 39 tests including native rendering.
Subsequent alias and quiet-policy changes are undergoing frozen-workspace verification because
another edit changed DockTheme.swift during the ordinary build. Live upload compatibility remains
an acceptance check; local upstream source inspection does not prove a running gateway's behavior.

## Phase 3: quiet periods and digest

Implemented in the current workspace; 50 focused tests across eight suites passed, including
native result/capture/digest rendering and the accessibility identifier contract:

- One coordinator at HermDelegate controls existing notch, pet announcement and system-notification
  producers. Quiet is opt-in with 30/60 minute or indefinite duration and one expiry callback.
- Blocking approvals, clarification requests and authoritative stopping failures may interrupt.
  Ordinary completion/quota/information notices are suppressed and deduplicated by owner/event.
- The reference-only digest is bounded to 50 entries plus overflow, survives restart, reconciles
  restored sources and offers explicit source navigation. Its body replaces the existing preview.
- Period end surfaces one digest announcement after existing interaction guards permit it.
  Notification opt-in and rail attention remain intact. There is no new polling or model call.

## Phase 4: routine and integration recovery

Implemented in the current workspace:

- Failed, blocked, delivery-failed and pinned routines appear in Activity. Detail names the
  owner profile and separates execution and delivery outcomes. Report reads use captured
  sessions; missing report bodies route to Automation.
- Pause/resume and deliberate new runs validate the owning inventory and acknowledgment.
  Duplicate triggers are guarded, including uncertain outcomes; explicit history review
  allows another separately confirmed attempt. Existing Automation actions capture owners.
- Skills inspection/search/install/toggle/removal and MCP catalog, preset/custom HTTP setup,
  secure credentials, OAuth, connection tests and removal use verified Hermes lifecycle paths.
  Each unsupported operation is independently unavailable. Skill removal checks process
  name/PID and recorded exit code; spawning it is not presented as removal success.
- MCP reload explicitly confirms its effect on all connected live sessions. OAuth and skill
  removal use bounded action-only checks, with cancellation; no idle poller was added.
- Routine notices join the existing quiet/digest coordinator. Digest entries retain job/run
  identities, with error text hashed rather than persisted as an event reference.

## Phase 5: destinations, capacity and Recall

Implemented in the current workspace:

- Working sets persist user labels and durable profile/session/project references. Runtime
  aliases are removed. Selection preserves workspace navigation and explicit project scope.
  Missing references remain visible until replaced or removed.
- Recall searches Hermes in the captured profile after 300ms, at most 20 results. Late reads
  are discarded. Copy/insert use supplied snippets and conversation references; inserting
  never silently retargets the quick draft. Navigation opens conversations, not exact messages.
- Capacity requires an owned session and configured model inventory. Stable single-account
  provider mappings expose remaining allowance/reset information; multiple accounts stay
  unallocated. Read time and missing upstream cache age are explicit. At 20% remaining or
  below, quick Send shows a nonblocking advisory. No forecast or automatic fallback exists.
- Idle configured model changes publish only acknowledged session scope. Busy, deferred,
  mismatched or unacknowledged mutations remain actionable failures. Stop requires an
  authoritative interrupted result. Capacity reads are interaction-driven, not idle polls.

## Phase 6: research and coding review

Implemented in the current workspace:

- Sources disclosure offers actual HTTP/HTTPS links as candidates and explicit pinning,
  optional labels/user URLs, captured reply references when supplied, external opening and origin-preserving quoted corrections.
  Markdown export names the reviewed bounded excerpt and pinned references, without
  implying claim-level verification.
- Eligible Herm-submitted turns capture repository HEAD and starting-tree condition.
  A clean baseline requires an acknowledged, observed start/completion and an exact submission attempt before enabling bounded diffs since the turn started; missing/dirty
  baselines retain current repository review with its actual scope. Evidence requires
  repository/revision provenance and is invalidated on known associated changes. Later turns, failures, missing start events and disconnects invalidate the baseline.
- Confirmed worktree setup uses native Git from committed HEAD, then Hermes session.create
  with explicit cwd, owner/directory validation and idempotency key. Partial success keeps
  the directory and recoverable unsent draft. Review/discard or deliberate retry is explicit.
- Subagent steering lists live children of the captured parent and targets one accepting
  child. Queued is distinct from delivery; unknown acknowledgment prevents blind repeat.
- Memory correction edits the actual fingerprinted entry. Named profiles use verified
  scoped HTTP lifecycle routes; launch-profile learning RPC is supported. Hermes validates
  replacement/drift. No local memory graph, transcript index or pending-write approval exists.

The workspace composer remains independent. New local preferences are additive and contain
references; unsent quick content remains in QuickDraftStore. Remote gateways, automatic macOS
Focus integration, OS sharing extensions, automatic screen capture, a native browser, and a
client plugin platform remain outside this release scope.

## Compatibility and measurement

Every new runtime operation validates actual responses and captures its profile/target.
A successful read or version string never authorizes an unrelated mutation. Unsupported or
denied methods report their own limitation. Hermes owns integration installation and secrets.
Preview read latency, workspace openings, admitted/suppressed announcements and mutation failures
use existing local development logs. There is no analytics transmission and no claimed improvement
before complete interactive measurements. Skill-removal and OAuth checks exist only while a
user-requested operation is active.

## Verification

Implementation of phases 0–6 is complete. The full frozen-workspace `make check` passed:
1,238 tests in 130 suites, the accessibility-contract test, script syntax checks, lint,
the final production build (484.54 seconds), and whitespace validation. `make check`
exited successfully. The final fixed-geometry native render test also passed (2.409 seconds).
These final checks include cross-profile completion-digest routing and the strict
file-delivered-answer acknowledgment safeguard.

A separate 80-test run across five suites passed, including native fixed-geometry renders,
owner-profile navigation, routing and real Git worktree fixtures. The routine preview retains
its Back and Open Automation actions while the report scrolls. Native snapshots cover result,
capture, digest, routines, Recall, working sets, capacity and subagent steering.

The earlier baseline failures below were resolved or their stale expectations corrected with
focused checks. Full tests now run serially because native UI fixtures share the main actor.
These checks include the preserved concurrent chat UI changes; they do not discard working files.
Later concurrent account-pool UI and chat-forwarding/quoted-reply edits were made after
freezing the source and are outside this validation snapshot. They are preserved in the workspace.
The final file-delivered-answer safeguard passed against this same frozen baseline;
its regression requires an immediate streaming acknowledgment and captured profile routing.

Live Hermes uploads, OAuth and integration mutations, and the complete interactive coding,
research and automation flows remain release acceptance checks. Keyboard focus, VoiceOver
interaction and reduced-motion behavior need interactive verification. Automated contract tests
and native render snapshots do not establish those outcomes. No UX performance improvement is
claimed; the implementation provides local measurement hooks without transmitting analytics.

### Live release acceptance still required

1. Coding: create an isolated task, confirm Hermes uses its returned directory, inspect the
   saved result and actual verification evidence, review the correctly labeled changes, and
   send a correction to the originating session while another workspace draft remains intact.
2. Research: capture an image/PDF/file, restart and recover its explicit destination, inspect
   the response, pin real source links, export Markdown and send a sourced correction to the
   originating session. Exercise missing files and an interrupted upload without blind retry.
3. Automation: start a quiet period, verify a blocking failure can interrupt and ordinary
   completions enter the digest, inspect execution and delivery separately, repair a supported
   integration and deliberately trigger a new run. Verify OAuth cancellation and notification
   opt-out. Check that restored digest entries return to their captured owners.

Also exercise keyboard/VoiceOver/focus and reduced motion, idle model changes and Stop this turn,
queued versus delivered subagent steering, memory fingerprint refusals, and offline/stale/retry
states against the installed runtime. These checks have not been performed by this implementation run.

### Historical milestone results

Earlier 2026-10-12 milestone:

- Final focused run: 50 tests in eight suites passed. It covers empty submission refusal,
  captured runtime alias attribution, profile-checked attachment cleanup, interrupted draft recovery,
  quiet bypass/suppression/deduplication/expiry and preserving failures from multiple owners.
- Native result, capture and digest render checks passed; the leaf containers retain their fixed size.
- `make check` was attempted on a frozen workspace to protect concurrent IDE edits. The full parallel
  suite reported failures and notch/pet geometry mismatches. The serial full run completed:
  1,199 tests in 128 suites, with 14 issues in six tests (roster revision, metadata timestamp,
  aggregate Kanban refresh, workspace contour, pet geometry and active-turn attachments).
  This is not a green release gate. The focused workflow run and script syntax checks passed.
- The final frozen-workspace release build passed in 542.38 seconds. Existing compiler warnings
  remain; passing compilation does not resolve the full-suite or interactive release gates.
- A validation-harness error leaked Git environment variables into fixture subprocesses, producing
  an unintended local commit. HEAD/index were restored to 9232987 without resetting working files;
  core.worktree was restored, and the author identity was restored from that commit with user approval.
  Subsequent checks do not inherit those Git variables.
- Preview read duration and workspace-open events are recorded in existing local development logs.
  No performance improvement or interruption reduction is claimed. Live Hermes, interactive keyboard/
  VoiceOver/focus checks and the complete coding/research/automation release flows remain outstanding.

- Existing quick-message, notch, and session-isolation suites: 66 tests passed before final changes.
- Decision, quick-message, notch, session-isolation, transport and feature-registry suites: 104 tests passed.
- Result Peek regressions: five tests passed, including opt-in loaded/empty/unavailable native renders.
- Full Swift Testing run: 1,168 tests, 15 issues. A serial rerun of the affected and workflow suites
  reduced this to four issues in 201 tests; the other async failures passed in isolation.
- All four persistent failures reproduced in an archived, unmodified HEAD (`9232987`): bot roster
  revision, historic timestamp formatting, static scenery batching, and attachment queuing during a turn.
  They are baseline failures and were left outside this feature change.
- `make lint`, shell-script syntax checks, and `git diff --check`: passed. Lint still reports the
  repository's existing formatting warnings; the new Swift files were formatted individually.
- Final serial workflow/accessibility-contract checks: 110 tests in nine suites passed.
- Workspace release build was interrupted by concurrent edits to `ProviderMark.swift`. The release
  build then passed in an isolated copy containing the feature's seven source files over clean HEAD.
  That frozen source matched the workspace's feature files; unrelated concurrent changes were not
  part of this isolated build. Existing compiler warnings remain.
- Native rendering verified. Interactive focus/keyboard/accessibility and live Hermes compatibility:
  not yet verified.

Manual runtime acceptance still to perform:

1. Peek at a finished background session while another chat has an unsent draft. Verify selection,
   draft, attachments and unread markers remain unchanged.
2. Compare copied output with the session's saved reply; open and reveal an existing generated file.
   Check missing and relative-path files take their documented recovery path.
3. Reply from a preview and verify the composer names its original destination. Switch profiles and
   confirm the preview clears; press Escape and verify the notch collapses without stealing typing focus.
4. Submit an approval or clarification once. Exercise confirmed refusal, disconnected acknowledgment,
   fresh pending read, replacement request, and expiration against the running Hermes gateway.

The final regression also verifies that a restored completion outside the visible profile's
inventory retains its captured owner for an explicit saved-reply read. That recovery does not
make expired approval or clarification references actionable.
