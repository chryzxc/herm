# Navigation and page-loading audit

October 15, 2026. Scope: one desktop user switching between pages while local
repository reads, GitHub requests, and Hermes transcript requests are pending.
This follows the [earlier smoothness audit](performance-audit.md).

## Confirmed problems and changes

| Trigger | Problem | Change |
| --- | --- | --- |
| Leave Pull Requests while rows load | Shared row-summary tasks are unstructured tasks owned by the model. Canceling SwiftUI's row task did not cancel those requests. Their completions could still publish to the workspace after navigation. | Page disappearance cancels summary tasks and invalidates the load generation. Returning keeps existing records and can retry interrupted summaries. |
| Leave PRs or Issues during refresh, then return | Refreshes checked generation but not cancellation. Cancellation could become a visible failure, start fallback work, or publish an obsolete result. Manual refresh buttons started tasks outside the view lifetime. | Refresh and retry buttons drive view-owned tasks. Models reject canceled results, release refresh state with generation-aware cleanup, and invalidate obsolete loads on disappearance. |
| Large PR responses arrive | The PR API inherited main-actor isolation from its mutation protocol, including JSON decoding and record normalization. | Actor isolation is limited to the mutation protocol requirements. The stateless API implementations run outside the UI actor; the observable model still owns UI state on the main actor. |
| Many attached projects | PR and Issue discovery launched a Git subprocess for every project concurrently. | A shared discovery function admits four lookups at a time and stops scheduling on cancellation. The shared Git runner also rejects commands whose caller is already canceled. A command already running is allowed to finish. |
| Leave Artifacts while it indexes recent sessions | Up to 50 independent transcript tasks survived the page. Artifact extraction also ran on the main actor. | A structured task group limits concurrent sessions to four. Cancellation propagates to children, stops queued sessions, and discards partial results. Extraction runs outside the UI actor and checks cancellation between messages. Manual refresh uses the same view-owned task as initial loading. |

Existing records, selection rules, mutation confirmations, and layout are
preserved. Successful artifact refreshes still retain prior records for sessions
that fail to load. No new polling, dependencies, or UI controls were added.

## Other surfaces inspected

- Chat and navigation: existing bounded transcript rendering and streaming
  isolation; session polling checks cancellation after sleeping.
- Terminal and Explorer: existing bounded terminal retention and background
  repository/file reads. The shared Git cancellation guard also benefits
  repository detail loads. Native text layout remains on the UI thread.
- Quota, Bots, and session Activity: visible polling loops already stop on
  cancellation; quota and roster projections avoid publishing unchanged data.
- Today, Inbox, Kanban, Search, Automation, Usage, and Calendar: traced their
  shared control-model loading entry points. These maintain app-wide projections;
  navigating away is not a reason to stop active agent work or clear those caches.
- Office and Settings: inspected process-wait and polling paths. The existing
  Office subprocess invocation runs in a detached task. GPU/rendering frame cost
  and model-loading latency were not measured in this pass.

## Verification

`PageLoadCancellationTests` supplies delayed GitHub responses that deliberately
complete after cancellation. It checks that canceled refreshes show no false
failure, old responses do not overwrite a new visit, abandoned summary requests
stop before fetching checks/reviews, and interrupted summaries can be retried.
Additional fixtures check bounded repository discovery and artifact loading,
cancellation of queued work, and successful subsequent loading. A non-UI-actor
API construction test also guards against restoring protocol-wide UI isolation.

Validation uses an isolated source snapshot because other work is editing and
building this shared workspace concurrently. The navigation source files and
fixtures were compared against the workspace to confirm they match.

- Debug build: passed.
- Release build: passed (existing compiler warnings remain).
- Full native run: all 53 XCTest tests passed; 1,332 Swift Testing tests ran.
  All navigation/loading suites passed. Four tests failed in the concurrently
  edited theme and gateway code: the Glass metadata contrast threshold, a skin
  radius expectation, remote URL normalization, and remote encryption policy.
  The snapshot had captured newer tests with older source versions. Matching
  gateway source/test versions were synchronized for targeted verification.
  The two theme failures remain results of that broader snapshot run; those
  concurrent theme edits were not changed by this audit.
- Final focused run: all 81 tests in seven suites passed, including the six
  new cancellation tests, the PR API isolation guard, PR/Issue loading, artifact
  extraction, repository views, plan files, and synchronized gateway coverage.
- Repository lint completed with formatting warnings. Shell syntax checks and
  `git diff --check` passed.

A small Swift 6 compiler reproduction confirmed protocol-wide actor isolation:
the old API initializer required a main-actor hop; the revised protocol compiled
from an ordinary async function without that hop.

A three-second read-only stack sample of the running app did not capture the
reported freeze. It showed event-loop waiting and native layout activity. It is
not a reproduction or a before/after benchmark.

## Limits

This is a code and lifecycle audit, not a guarantee of zero lag on every page.
Live rapid-navigation frame timing, very large PR diff layout, Office GPU cost,
and external service latency still require interactive profiling. Cancellation
cannot interrupt a synchronous Git command or a single regex match already in
progress, but prevents queued work and stale UI publication in the fixed paths.
