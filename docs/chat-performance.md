# Chat scroll verification

## Session switching — work in progress

Session switching retains a bounded in-memory preview of recently loaded messages
while Hermes confirms and reloads the selected session. The preview is a display
projection only; live events and pending sends remain in the model's canonical
state. Session actions wait for the fresh transcript, and an unsuccessful refresh
retains the preview with a retry action.

Opt-in `HERMES_DOCK_DEBUG_LOGS=1` or `--perf-trace` metrics record selection,
connection, resume, history fetch and projection, parsing, publication, and native
layout. They contain timings and counts only. Conversation history now uses a
240-row buffer and refills when the reader approaches the oldest loaded rows
with no more than two local pages left. A paired Release baseline and live
switch latency for the larger buffer remain to be measured.

The opt-in production transcript fixture runs five cold/cached pairs each for
prose, code, tool-heavy history, and a session switch with streaming state. It
uses controlled 30 ms resume and 10 ms history-read delays; fixture timings
are not live Hermes or physical-display measurements:

```sh
HERM_SESSION_PROFILE=1 swift test -c release --disable-automatic-resolution --no-parallel \
  --filter ConversationTranscriptIntegrationTests.releaseSessionSwitchTimings
```

With `--perf-trace`, `startup` records launcher installation and workspace
readiness. The `session_index` stages record publication of recents, the complete
inventory, and the first sidebar snapshot with rows. Compare the stages on the
same profile in cold and warm Release launches, and use `session_open`'s
`fresh_layout` for transcript readiness.

## Session composer drafts — 23 October 2026

Draft snapshots run only during session/new-chat navigation. They retain existing
Swift text/array storage and image instances, without attachment reads, encoding,
network calls, timers, or per-keystroke archive updates. Restore publishes the
final editor text once and changes only attachment fields whose values differ.

The focused regressions verify that 2,000 typed characters produce zero workspace
publications with 500 saved draft entries. An unchanged restore produces zero
editor or workspace publications. Before the optimization, 1,000 identical
save/restore pairs produced 2,000 editor and 6,000 workspace publications; both
counts are now zero. Matching text still resets history and completion state.

A Debug helper run measured 48.86 ms for 1,000 unchanged save/restore pairs and
265.26 ms for 1,000 transitions between different 1 MiB text drafts (0.27 ms per
transition). The fixture holds 500 session entries sharing sample text and image
storage; it does not allocate 500 distinct large images. It verifies image object
identity survives save/restore. These timings exclude Hermes loading, native
editor layout, and SwiftUI rendering, and do not establish a live frame rate.

Run with `swift test --disable-automatic-resolution --no-parallel --filter SessionComposerDraftTests`.
Verification uses a frozen source copy while other workspace changes are active.

The native fixtures mount `ConversationTranscriptView`, including its actual clip-view
observer, geometry preferences, snapshot source, and coordinator. The paging fixture
moves the native clip view and checks message identity and offset after layout; it
never applies an anchor correction itself. Mixed activity/body rows, hidden rows,
and stored-history prepends use the same container and must produce one frame per
message. Ordinary correctness tests run in CI.

Run the focused suites without parallel execution:

```sh
swift test --disable-automatic-resolution --no-parallel --filter \
'ConversationTranscriptCoordinatorTests|ConversationTranscriptSourceTests|ConversationTranscriptIntegrationTests|ConversationScrollObserverTests|ConversationRenderOptimizationTests|ConversationManualScrollTests|MarkdownPreparationTests|MarkdownRenderCacheTests|ConversationMessageRowTests|MessageNavigatorTests|TranscriptHistoryPagingTests|TranscriptStableIDTests|StreamingScrollDeferralTests|MultiSessionPerformanceTests|GenerativeUIIsolationTests|GenerativeUITests|GeneratedHTMLTests'
```

Timing is opt-in:

```sh
HERM_CHAT_PROFILE=1 swift test -c release --disable-automatic-resolution --no-parallel \
  --filter ConversationTranscriptIntegrationTests.releaseTranscriptBaseline
```

Set `HERM_CHAT_PROFILE_PAIR` (0–4) and `HERM_CHAT_PROFILE_SCENARIO`
(`prose`, `code`, or `streaming`) to select one cold/warm pair. This allows
before/after runs to alternate in separate fixture processes rather than mixing
compiler contention with scroll timings.

The benchmark uses five cold/warm pairs per scenario, 500 synthetic messages, a
640-by-600-point viewport and a long Markdown reply every fifth row. The original
Release comparison below used four-message production pages; current history
pages reveal eight messages. Scenarios cover 128 KB of prose, a 1,000-line code fence, and
streaming while browsing history. Each scenario/pair uses a new document suffix; its warm fixture reuses the same
content and process-local caches. The cold case introduces new documents, rather
than flushing every process cache. Identical sections can already have measurements
from the initial window, and adjacent documents can already have been prefetched.
These synthetic replies deliberately share long bodies, so this is a reuse stress
test rather than a prediction for every history. Neither label means a fresh-process
launch.

`step_work_ms` measures the synchronous native scroll and immediate layout/display
call. `page_work_ms` additionally accumulates explicit layout/display calls while
settling. Both exclude fixture sleeps, but asynchronous SwiftUI work can happen
between those calls. `main_thread_cpu_ms` measures the main thread's user and system
CPU time across the entire paging/settling interval, including deferred layout and
excluding sleep time. Compare CPU work and scroll-step latency separately.

Debug performance logs include transcript evaluations, page transactions, anchor
corrections, synchronous document parses, prefetched documents, and shared
measurement hits/misses. The opt-in fixture reports page-local parse and measurement
counts as well. Counters do not publish observable transcript state.

The coordinator accepts geometry only for its session, generation, and complete
mounted range. Settling cannot finish an unmeasured page or invent a scroll
direction. Native corrections cannot start another page. Navigator jumps wait for
matching layout, and session replacement cancels delayed work. The snapshot source
uses specific publishers and compares mounted descriptors by identity/revision;
live text remains observed in the streaming leaf. The observed-parent fixture
asserts zero message-body evaluations, zero Markdown remeasurements, and stable
native view identities after unrelated publications. SwiftUI can still request a
cheap container-body evaluation; that is distinct from snapshot publication and
message rendering.

Completed Markdown prefetch parses one adjacent page in each direction in one
cancellable background task. A miss renders synchronously. Shared measurements
contain numeric heights only and use exact source, section kind, width, scaled body
font/weight, theme identity/revision, and mention revision. Streaming measurements
stay local. Eviction affects performance only; Hermes remains the source of truth.
Each native document captures its measurement context once per layout solve.
New history rows skip section-view reconciliation until they own section views,
and their section caches allocate width history when layout requests a second width.
Anchor correction reuses the generation check from the accepted complete layout.

Each visible session rail scans messages and tool activity for PR links in
cancellable background tasks. Its in-memory index reuses results for unchanged
inputs, including inputs without links. Live activity updates can publish while
the history scan is still running.

A synthetic fixture does not measure physical trackpad momentum or prove a frame
rate. A live trackpad check requires a separately authorized app relaunch; these
checks never restart the running Herm app.

## Release comparison — 23 October 2026

Five before/after pairs per scenario ran as interleaved synthetic fixture processes
using optimized production objects. The baseline is the stage-1 production-container
extraction, before the coordinator, snapshot, and Markdown changes. Both builds used
the same fixture content, window size, and pacing. Compilation finished before timing.
The final correctness gate passed 113 Swift Testing tests and 18 XCTest tests; Debug
and Release builds passed. Verification used an isolated source copy to avoid
concurrent workspace edits, with the changed chat sources checked against the workspace.

Medians in milliseconds:

| Scenario | Cache case | Main-thread CPU before → after | Scroll step before → after |
|---|---|---:|---:|
| Prose | New documents | 481.62 → 186.72 | 479.62 → 12.91 |
| Prose | Warm | 418.90 → 205.36 | 419.42 → 10.81 |
| Code | New documents | 161.54 → 147.35 | 140.08 → 7.80 |
| Code | Warm | 150.83 → 150.52 | 130.40 → 6.92 |
| Streaming | New documents | 401.18 → 196.56 | 372.96 → 10.83 |
| Streaming | Warm | 398.26 → 215.54 | 373.36 → 10.24 |

Warm prose CPU work fell 51%, and streaming/history CPU work fell 46%. Warm code
CPU work was effectively unchanged (0.2% lower); creating visible native code views
still requires work. Every scenario's median scroll step improved, with no regression
above the 10% acceptance limit. These scroll-step timings exclude deferred SwiftUI
work; the CPU column accounts for that work across the settling interval.

All 15 warm after-cases performed zero synchronous document parses and zero shared
measurement misses, with 16,385 shared measurement hits in total. Regression tests
also verify exact remount heights without new section measurements and exclude
mutable streaming tails from completed caches. The section-mounting algorithm remains
unchanged. The data does not establish a trackpad frame rate.

[Raw paired results](benchmarks/chat-scroll-2026-10-23.csv) include cold/warm samples,
explicit layout/display work, main-thread CPU, and cache counters.

## Busy-session isolation — 23 October 2026

A follow-up audit found two avoidable invalidations: snapshots included global bot
step entries, and live tool activity republished snapshots even when the streaming
row was outside the mounted history window. The source now includes bot steps only
for the selected conversation's dispatch/mention record identities and includes live
activity only while its row is mounted. The view consumes those scoped inputs.
Canonical chunks and tools continue accumulating; returning to the reply or switching
sessions reads their latest values.

The new source regressions reproduced five unwanted publications for five update
batches before the change, and zero afterwards. Selected-session bot-step changes,
completion, session replacement with a stored/runtime alias, and returning to the
live row remain current.

The production native fixture covers both following the live reply and browsing
history with 500 messages, long Markdown, eight active background sessions, and
2,000 background chunk/tool events per case. It interleaves five selected-session
text/tool updates and workspace refreshes. Completed message bodies do not reevaluate,
completed row heights stay within one point, and mounting remains bounded. While
browsing history, native Markdown views retain their identities and measurements,
the scroll offset stays within one point, and subsequent older-page loading restores
its anchor within one point.

The focused gate passed 158 Swift Testing tests and 18 XCTest tests, including
multi-session, session isolation, history, navigator, streaming, Markdown, and
Generative UI coverage. The final session-switch source tests, Debug build, and
`git diff --check` also passed. These are synthetic correctness checks; they add no new
Release timing or physical-trackpad claim to the earlier comparison.

## Timeline follow-up — 23 October 2026

The Timeline tab had a separate rendering bottleneck. Its nested lazy stacks still
prepared the full loaded row list: a 1,000-row native fixture recorded 3,012 label
preparations and 4,000 bar preparations during initial layout. Five live tool updates
also rescanned the 500-message history five times after the initial scan.

Timeline now subscribes to execution-specific publishers, coalesces at 250ms, and
cancels subscriptions and pending updates while hidden. Completed request inputs
are cached by the canonical message mutation revision and session identity; history
prepends and replacements invalidate them. A parent equality boundary prevents
unrelated workspace publications from rebuilding the canvas.

Both labels and bars use the same native vertical viewport, keeping fixed 34pt
row extents and mounting one viewport of buffer. A persistent tail anchor preserves
Live following, and selection can reach rows outside the mounted window. Assistive
navigation retains the complete hierarchy. The grid and ruler use viewport-sized
drawing surfaces; clock ticks reuse precomputed time bounds and leave static counts,
labels, and Markdown outside their update scope.

The first corrected fixture prepared 157 labels and 157 bars, and the five live
updates reused the initial history scan. These are Debug work counters, with layout-pass counts varying by environment,
not frame-rate or Release latency measurements. The final native run recorded 134
label preparations and 134 bar preparations. Native regressions also exercise
scrolling to the beginning, middle, and end; pure regressions check shifted live
clock bounds, history invalidation, and hidden-work cancellation.

The broader chat review retains the existing ownership boundaries: canonical text
and activity remain in DockModel/StreamingText, completed Markdown retains its
measurement cache, the transcript coordinator owns anchors, and the sidebar/rail
use their focused projections. A combined fixture mounts production chat beside
Timeline during streaming and background tool bursts, then checks older-page
loading and the chat anchor. Further structural rewrites need evidence beyond
these verified update paths.

The final focused gate passed 269 Swift Testing tests across 24 suites and 18
XCTest tests, including Timeline, chat paging, streaming, multi-session isolation,
rail activity, agent projection, Markdown, navigator, and Generative UI checks.
The Debug build, color contract, and diff checks passed. Timeline visual fixtures
also rendered across Clean, Island, Glass, Monochrome, and E-Ink themes, including
narrow/wide layouts and live growth. Compilation used a frozen
source copy because unrelated workspace files were being edited during builds;
the changed Timeline sources, fixtures, message revision, and inspector integration
were checked against the workspace. The running Herm app was not restarted.

Run the Timeline and combined native regressions with:

```sh
swift test --disable-automatic-resolution --no-parallel --filter \
'SessionTracePerformanceTests|SessionTraceTests|ConversationTranscriptIntegrationTests'
HERM_TRACE_UI_DIR=/tmp/herm-timeline-ui swift test --disable-automatic-resolution \
  --no-parallel --filter SessionTraceRenderTests
```

## Streaming Markdown and activity-row follow-up — 23 October 2026

A second review covered the composer, completions, sidebar/rail, activity rows,
streaming Markdown, completed rendering, and session lifecycle paths. Two targeted
changes address repeated work without changing visual design or stream boundaries:

- Native streaming previously classified every chunk on each update. In a 16-chunk
  fixture, ten small appends caused 160 additional chunk preparations. The native
  coordinator now retains the exact stable prefix and prepares only changed suffix
  chunks. It checks source, context, and mutability as well as revision/identity,
  including when another stream reuses chunk IDs. The renderer consumes canonical
  `StreamingText.text` instead of joining all chunk strings again on each update.
- Activity rows previously received all selected-session dispatch and step entries.
  Each row now receives only records referenced by its own tool-call IDs, allowing
  unchanged activity rows to keep their equatable rendering boundary while a bot
  reports progress on another message.

Canonical stream text, chunk promotion policy, Markdown parser, native section
mounting, styling, and height measurement policies retain their existing owners.
The new section cache is local to the mounted streaming renderer and contains no
native views or durable state. Theme changes reapply styling while reusing pure
section preparation. Debug native-update logs report `prepared_chunks` per update.

The composer already caches serialization, highlighting, and layout by native
storage generation and geometry; this review retains that implementation. The
sidebar/rail and Timeline keep their focused projections, and chat's coordinator
continues to own paging and anchor correction. No additional broad observer/model
rewrite is introduced without evidence of another failing path.

The final functional gate passed 326 Swift Testing tests across 30 suites and 22
XCTest tests. Coverage includes composer completion/mentions, native editing and
selection, queue ordering, message actions, code copying across offscreen
continuations, streaming-to-completed handoff, parser parity, exact heights,
manual-scroll deferral, prompts, session replacement, history paging, Timeline,
rail activity, agents, and Generative UI. The chunk-preparation regression now
records ten additional preparations for ten small appends (160 before). The
production activity fixture confirms that a bot step and completion each evaluate
only their owning activity row; unrelated steps and completed message bodies do
not reevaluate.

The opt-in native fixtures also passed with 128 KB of completed/streaming Markdown,
a 6,000-line (252 KB) code fence, and rich-history paging. They check that scrolling
settle presents all received chunks with the exact reference height and preserves
the reader's offset within one point. Their step timings include an 8ms fixture
pacing sleep and ran in Debug under concurrent machine work; they are not a fresh
paired Release comparison or a frame-rate guarantee. The running Herm app was not
restarted, and no physical-trackpad check was performed.

Run the additional regressions with:

```sh
swift test --disable-automatic-resolution --no-parallel --filter \
'ChatHotPathTests|ConversationTranscriptIntegrationTests|ComposerInlineEditorTests|ComposerCompletionTests|StreamingPerformanceTests|ConversationManualScrollTests'
HERM_SCROLL_PROFILE=1 swift test --disable-automatic-resolution --no-parallel \
  --filter 'ConversationManualScrollTests.measureLongMarkdownScrollWork|ConversationManualScrollTests.pagingRichMarkdownHistoryPreservesTheVisibleMessage'
```

The final Debug build, color contract, and `git diff --check` passed. Verification
used the existing frozen source copy to avoid unrelated concurrent edits; changed
renderer/activity inputs and regression fixtures were checked against the workspace.


## Navigator and visual-reply task follow-up — 23 October 2026

The remaining transcript review found two history-sized operations outside native
Markdown layout. Snapshot equality manually compared every navigator entry even
when DockModel's cached projection was unchanged. Ordinary streaming replies also
concatenated their full text into a visual-reply task ID on each chunk, starting a
task that immediately returned because there was no `herm-ui` content.

DockModel now retains an immutable navigator snapshot. Canonical message or stored
history mutations mark its inputs dirty; the next read compares the rebuilt items
once, preserving snapshot identity for metadata-only edits. Ordinary activity and
scroll refreshes compare navigator identity in constant time. Navigator projection
also computes readable text once per message for both preview and search. No
additional durable history store is introduced.

Visual-reply task identity is now an optional parse request. Ordinary Markdown
keeps the same nil request throughout streaming, avoiding repeated task starts and
full-source concatenation. Visual requests include exact source, streaming status,
and reply identity/revision so completion, replacement, and session changes still
cancel obsolete parsing and update the displayed content. The existing fallback,
visual preference, document cache, and renderer remain in place.

New regressions exercise 5,000 loaded messages across 100 unchanged refreshes,
offscreen metadata and text edits, stored-prompt projection and history prepends,
session replacement, ordinary streaming request identity, visual completion, and
returning from visual content to the ordinary renderer. These are work-reuse and
functional checks, not a fresh paired Release latency comparison.


The focused functional gate passed 330 Swift Testing tests across 30 suites and 22
XCTest tests (352 total), with `--no-parallel`. It covers production paging,
anchor correction, streaming during history browsing, chat alongside Timeline,
composer editing/completion/queue ordering, message actions, Markdown selection and
code copying, session lifecycle isolation, stored-history search/jumps, visual
forms, and WebKit isolation. The 5,000-message regression retains navigator
identity and publishes nothing across unchanged refreshes and an offscreen token
metadata edit; an offscreen text edit updates search immediately.

The final Debug build, color contract, and `git diff --check` passed.

Verification uses the existing frozen source copy because concurrent work owns the
workspace build directory. The task-specific sources and changed model cache
sections match the workspace; unrelated concurrent model/voice edits are excluded
from that copy. The running Herm app was not restarted, and there is no new live
trackpad or paired Release timing claim.

Run the focused additions with:

```sh
swift test --disable-automatic-resolution --no-parallel --filter \
'ConversationTranscriptSourceTests|MessageNavigatorTests|GenerativeUIIsolationTests|GenerativeUITests|GeneratedHTMLTests'
```


## Larger history pages — 23 October 2026

A further review of transcript subscriptions, streaming leaf updates, native row
geometry, Markdown preparation, activity inputs, and navigator projection retained
the existing ownership boundaries. History pages increase from four messages to
eight in both directions. The initial 12-message window, 36-row normal backstop,
visible-row protection, jump context, footer following, and unread policy stay in
place. The Hermes storage fetch size stays at 120 rows; the change affects mounted
presentation pages, not transport state.

Markdown prefetch derives its adjacent ranges from the same page-size constant.
A new regression checks all eight neighboring documents on each side and excludes
mounted/distant messages. Production paging now asserts the exact revealed count,
one transaction and correction per gesture, a settled transaction, and anchor error
below one point, including a partial page at the transcript end. Additional normal
CI coverage repeats both directions with tall Markdown/code rows and live streaming.
Pure policy regressions cover whole-history traversal, reversals, oversized visible
spans, the mounting backstop, clamped edges, shrink, and prepended identities.


Five cold/warm pairs per scenario were recorded before and after this page-size
change using the existing native fixture in **Debug**. These ran serially on a
busy machine, not as interleaved paired Release runs. They are a tuning check,
not a new Release acceptance claim. Warm medians (milliseconds):

| Scenario | Scroll-step work, 4 → 8 messages | Main-thread CPU per page, 4 → 8 messages |
|---|---:|---:|
| Long prose | 25.76 → 13.01 | 368.02 → 230.28 |
| Code fence | 6.99 → 6.07 | 198.83 → 177.74 |
| Streaming while browsing | 14.26 → 12.02 | 204.33 → 261.15 |

Eight-message warm pages performed zero synchronous parses and zero shared
measurement misses in all 15 samples. The streaming scenario spent 28% more CPU
per page while revealing twice as many messages. Scroll-step medians did not
increase in these fixtures. Load/cache variation limits comparisons of the CPU
numbers; this does not establish physical trackpad latency or a frame rate.
[Raw Debug samples](benchmarks/chat-page-size-debug-2026-10-23.csv) retain explicit
layout/display work, CPU, and cache counters for all 60 cold/warm samples.


The final focused gate passed 332 Swift Testing tests across 30 suites and 47
XCTest tests (379 total), with `--no-parallel`. The opt-in 128 KB Markdown,
6,000-line/252 KB code fence, live/deferred streaming, and rich-history paging
fixtures also passed (two additional tests). They preserve the exact completed
height and reader offset after deferred updates; fixture step timings include
8ms pacing and are not presented as rendering-only latency.

Verification used the existing isolated source copy, with the changed policy and
all three changed fixtures checked byte-for-byte against the workspace. Unrelated
concurrent workspace changes remain untouched. The running Herm app was not
restarted; a live physical-trackpad check and a fresh paired Release comparison
remain outside this verification.

The final Debug build, color contract, and `git diff --check` passed.


## Find matching and Return selection — 23 October 2026

A further audit found a separate main-thread path: Find debounced query changes,
but then synchronously scanned full message bodies on the UI actor. Pressing
Return repeated that scan instead of using the displayed results. Snapshot
isolation and Markdown caches do not eliminate this work.

Find now scans Sendable navigator items in one cancellable background worker per
query. Cancellation is forwarded to the worker and checked between messages;
the UI task rejects a cancelled result after returning to the main actor. Matching
keeps the existing case/diacritic rules, full-text coverage, role matches, order,
and stored-prompt targets. Task identity compares the immutable navigator snapshot
rather than comparing full-text arrays during viewport/hover updates.

`MessageNavigatorSearchState` binds completed results and a pending Return action
to exact query, session, and snapshot identity. Return uses current results or
waits for that request. Old matches are hidden immediately when inputs change;
closing the panel cancels work. The existing empty/result slot reports pending
matching instead of briefly claiming there are no matches. This state is disposable
presentation state and adds no transcript persistence or runtime changes.

New checks cover a 500-message full-text/Unicode fixture from the main actor, worker
cancellation, pending Return, query/history/session replacement, close/reopen,
no matches, and a native Find field submitting before debounce completes. Debug
worker assertions also enforce that matching executes outside the main thread.


The final focused gate passed 339 Swift Testing tests across 31 suites and 47
XCTest tests (386 total), using `--no-parallel`. This includes the native Find
submission test, chat/Timeline concurrency, eight-message paging, tall-row anchors,
Markdown rendering and selection, streaming handoff, composer interactions,
prompts, message actions, and stored-history search/navigation. The worker fixture
runs from the main actor over roughly 6 MB of message text, with main-thread
execution rejected by its Debug assertion; no new frame-rate or Release timing
claim is made.

Tests use the existing isolated source copy because another SwiftPM process owns
the workspace build directory. The changed search, navigator adapter, transcript
call site, and new tests were checked against the workspace; unrelated concurrent
changes were preserved. The running Herm app was not restarted. This pass does
not include a physical-trackpad check or a fresh paired Release profile.

The final Debug build, `make guard` (strict lint, color contract, and diff checks),
and `git diff --check` passed.

## Active-work performance changes — 4 November 2026

Tool completion now updates each call once and merges the activity log using an
ID index. The control center avoids repeating a same-session bind during quota
polling and starts independent refresh branches concurrently. Timeline caches
its ownership and timing projections until the turn changes, and suspends its
presentation updates when all of its windows are hidden. Artifact reads can
publish incomplete page progress while retaining the last complete result.
The workspace shell subscribes to its own navigation and lifecycle inputs;
tool activity stays with the transcript and other surfaces that display it.

Regression fixtures were added for activity ordering, binding, concurrent
refresh, Timeline preparation, and shared artifact progress. They have not been
run. An initial isolated Swift test build was stopped at the user's request to
avoid slowing their machine. No paired Release timings, interactive latency,
memory comparison, or live scroll result was collected for this change, so no
performance target or end-to-end improvement is claimed.

## Chat viewport work — 4 November 2026

Markdown viewport notifications now schedule native layout, which finds the
buffered section range using the cached ordered frames. Mounting updates only
that range and the retained focused section. Each document keeps at most eight
inactive section views or 256 KiB of estimated attributed content; focused,
selected, and active interaction views remain protected. Numeric heights and
styled output continue to use the existing bounded caches. Code sections retain
their horizontal position across eviction.

The existing adjacent-page parser can warm exact completed-section heights
while the reader is idle. Warming yields between sections, stops during scrolling
or cancellation, and skips sections over 16 KiB. A single cold large code block
still needs synchronous layout. Activity lists prepare grouped steps once per
input change and mount their rows lazily. Disclosure state remains on the turn.

Opt-in performance tracing adds section visits, mount changes, foreground
measurements, and the maximum inactive-view count; it does not include message
content. CI fixtures cover bounded traversal, focus and selection, code position,
idle measurement, and activity grouping. These changes have not been built or
tested locally at the user's request, and no before/after latency or CPU figures
are available.

## Workspace responsiveness work — 5 November 2026

The workspace publishes width changes only when its responsive layout decisions change,
and persists divider adjustments after dragging. Settings keeps its detail mounted across
rail/menu transitions and reuses schema within a client/profile binding. Visible host
state gates selected polling and transcript preparation; idle Markdown warming also pauses
during window and divider resizing. Code-section height cache entries are width independent.

Activity calendar indexes are prepared away from the main thread, archive requests are
limited to two concurrent reads, and long Usage lists mount rows lazily. Bot roster updates
that leave mention appearance unchanged no longer invalidate mention styling.

This is a partial implementation of the broader workspace plan: host root reconciliation,
complete hidden-host suspension, focused inspector/field snapshots, archive demand ownership,
and selected-range background preparation remain open. The new regression fixtures have
not been run, and CPU, interaction latency, scroll performance, and memory remain unmeasured.

## Scroll preparation follow-up — 5 November 2026

Unchanged quiet session refreshes no longer republish the current title or an already
false loading flag. Timeline publishes its buffered row range separately from precise
viewport coordinates. Adjacent completed Markdown pages prepare TextKit layout in
2,048-character increments and cache exact code dimensions alongside section heights.
History waits for prepared measurements, with a one-second fallback to normal rendering
if preparation cannot complete. Session changes, navigation and direction reversals
invalidate pending page work. The cache retains numeric presentation data only.

The opt-in manual fixture records p50, p95 and maximum synchronous work without its
pacing sleep, along with main-thread CPU and Markdown counters. A separate synthetic
workspace fixture covers session rows, Usage and Settings in the shared shell. These
fixtures do not measure physical trackpad input or displayed frame times; see test output
and Instruments recordings for actual results. Exact TextKit parity, cancellation and
scroll-anchor regressions must pass before relying on the new preparation path.

The focused Debug gate passed 99 tests in 10 suites, and the Debug build and
`make guard` passed. One Debug fixture run measured p95 synchronous scroll work of
4.2 ms for completed 128 KiB Markdown, 3.1 ms for a 6,000-line code block, and
1.7–1.9 ms for deferred streaming. Timeline measured 0.56 ms; synthetic session,
Usage, and Settings surfaces measured 6.83–7.85 ms, 3.16–3.80 ms, and 0.73–2.14 ms,
respectively. These are individual Debug runs, not before/after comparisons or
displayed-frame measurements. CPU totals include time between paced steps.

The frozen baseline Release build was stopped before tests ran when free disk space
fell to approximately 5 GiB. An Animation Hitches recording targeted the SwiftPM
launcher rather than the spawned test process and cannot establish app hitch rates.
The five paired Release comparisons, Time Profiler capture, and physical-trackpad
check remain outstanding; no smoothness or no-regression target is claimed.

## Scroll preparation follow-up — 6 November 2026

Requested history pages can prepare while the reader scrolls, while speculative
warming remains idle-only. Paging no longer mounts an unprepared page after a
one-second timeout. A prepared page holds its parsed documents and exact numeric
measurements through the matching layout, including after cache eviction.

Attributed-text construction and text installation still contain synchronous
whole-section work. The production workspace benchmark, paired Release results,
valid Instruments traces, and physical-trackpad confirmation remain outstanding.
The changes above therefore do not establish a frame-rate or smoothness result.

The focused Debug run passed 101 tests in 10 suites, and the Debug build passed.
A subsequent Debug fixture run passed 24 tests; its 128 KiB completed Markdown
p95 was 7.6 ms, the 6,000-line fence p95 was 2.8 ms, and deferred streaming p95
was 3.8–3.9 ms. Live streaming reached 51.2 ms maximum in one run. These are
individual synchronous fixture timings, not paired Release or frame measurements.

## Incremental history preparation — 6 November 2026

History requests retain an ordered eight-message target across partial mounts. The
coordinator mounts a contiguous prepared prefix and restores the visible anchor;
remaining work is retained until the reader returns to the edge, reverses direction,
or the request is invalidated. Completed documents and exact measurements are held
through each layout transaction. Background preparation now parses prose and list
blocks and inline Markdown into a bounded, disposable cache; native styling and
TextKit remain on the main actor.

The focused Debug run passed 47 tests across native paging, scroll deferral,
selection, code copy, horizontal offsets, and Markdown preparation. The opt-in
manual fixture passed with 128 KiB Markdown (5.9 ms synchronous step p95), a
252 KiB code fence (3.7 ms), and deferred streaming (1.8–1.9 ms). These are
individual synthetic Debug measurements, not a paired comparison or displayed
frame times. A separate jump-to-latest native test failed with a 200-point bottom
offset and needs investigation.

The Release baseline was stopped during compilation; paired Release results and a
physical-trackpad check remain outstanding. Styling and text installation can still
perform whole-section main-thread work; resumable styling/installation and detailed
per-stage timing are not yet implemented.

## Battery responsiveness follow-up — 15 November 2026

Activity-triggered session index reads now use the quiet refresh path. Events
arriving during an index read retain one follow-up read, drained by the current
request's completion. Profile changes and shutdown discard pending demand.
Explicit refreshes retain their ability to supersede an older background read.

Performance capture defaults to timing only. Optional stack samples perturb the
measured app; sampled intervals are marked even when sampling ends mid-interval.
Reports include callback arrival-gap percentiles and threshold counts, expected
display-link intervals, power source, Low Power Mode, thermal state, and available
build identity. Callback counts and estimated missed frames are not displayed FPS.
Native host updates and sidebar projection refreshes record aggregate work only
while a capture is active. Stopping freezes timing and waits asynchronously for
an active sampler to terminate before saving; a new capture waits for finalization.

No live app was relaunched and no paired charger/battery measurements were taken.
These changes remove a known source of redundant workspace publications; they do
not establish an end-to-end battery smoothness improvement. Compare five paired
30-second timing-only captures of the same optimized baseline/fixed build workload,
window, conversation and scroll/hover actions on each power source, controlling Low
Power Mode independently. Compare callback-gap p95, counts above 100 ms, and host
work; check focus, selection and scroll position manually. Do not claim improvement
from sampled timings, and investigate remaining hotspots before changing pane hosts.

Verification: the focused run passed 15 tests in five suites (`SessionStartupTests`,
`ScrollRefreshTests`, `ActivityRefreshPublicationTests`, `CallbackGapSummaryTests`,
`HermPerformanceRecorderTests`). The debug build, `make guard`, and diff checks
passed. Existing unrelated compiler warnings remain. Release profiling, sampler
process integration tests, and physical battery/charger comparisons were not run.

## Root publication cascade — 16 November 2026

Captures from 15 November put the worst frames during agent file edits. In those
frames `developerWorkflow→root` bursts lined up with sidebar refreshes of 12–29 ms.
`DockPopover` held `DeveloperWorkflowModel` as a `@StateObject`, so each
filesystem-driven publication (notices, baseline status, watch state, file counts)
re-rendered the root. The root then updated three nested split-pane hosting views.

- The root now observes `DeveloperWorkflowModel.rootPresentationChanges`. This
  scoped publisher emits only when the repository path, Git status, worktrees or
  worktree availability change. Child views keep their own `@ObservedObject`.
- Watch-state and baseline-status writes are skipped when the value is unchanged.
  A notice insert is now a single assignment rather than three publications.
- The rail coalesces activity-only refreshes to 4 Hz on every power source, not
  only in Low Power Mode. With several running sessions, each one's ticks used to
  trigger a full rail rebuild. Selection changes still refresh at once and cancel
  any pending coalesced refresh.
- Bot activity pulses use the shared `dockMotion` clock instead of a
  per-pill `phaseAnimator`.
- Split-pane `DockWindowHostingView.layout()` records `hostLayout` work. The next
  capture can confirm or rule out the nested-host cascade before panes are
  restructured.

Not measured: paired before/after captures on battery and on charger. Follow the
comparison method in the previous section.

## History page batching — 19 November 2026

A 23 s capture on a 60 Hz display, in Low Power Mode with one running session,
lost 32% of frames. The worst seconds were the ones that paged history: up to
eight page transactions a second, each with its own anchor correction, and
26–45 dropped frames in each of those seconds. Preparation reports progress per
message, and every report mounted the ready prefix, so one eight-message page
landed as several single-row transactions. Each transaction republishes the
snapshot, re-lays out the mounted transcript and corrects the anchor.

- A partially prepared request mounts only half a page or more
  (`ConversationMessageWindow.mountsPartialPage`). It still mounts what is ready
  when the reader is within half a viewport of the edge, or when the whole
  request is ready.
- Repinning to the bottom of a widened window compacts it after the scroll
  settles, not under momentum.
- A held decorative clock re-checks every 0.5 s instead of every 150 ms
  (`DockMotionSchedule.heldRecheck`). It still renders each time it fires.
- `hostLayout` counts a nested pane host inside its parent's time as well.
  Captures now also report self time for each host as `hostLayout.<role>`
  (root, queue, workspace, inspector, panelLeading, panelTrailing). That shows
  which pane re-lays out about 11 times per frame in idle seconds. The capture
  recorded about 650 layouts a second with no scrolling or publications. The
  notch's two 30 Hz indicators run in their own panel and are not counted.

Not measured: a paired capture after these changes.

## Transcript hover during scroll — 20 November 2026

A 22 s chat-scroll capture on a 120 Hz display, in Low Power Mode with no
running sessions, lost 35% of frames. Steady scrolling seconds (t=2–18) had no
publications, yet each scroll tick re-rendered the pane host holding the
transcript (`hostLayout.panelLeading`, about 1.7 ms per render, 180–290 ms a
second). In `stack-t1s.txt`, 16 of the 37 samples taken in the scroll
display-link callback were `EventBindingManager.enqueueHoverUpdateIfNeeded`.
In that call, SwiftUI re-hit-tests every mounted row's hover, tooltip and
action-button region because content slides under a still pointer.
`DockHoverGate` only gates `mouseMoved`, so it never saw this path.

- The transcript scrolls in `HoverPausingScrollView`, the same scroll-phase
  hit-testing pause the sidebar uses. Hover resumes when the scroll goes idle.
- `ControlCenterModel.refresh` marks its projections refreshing or unavailable
  in one write per published dictionary instead of two per projection. The
  t=21 s burst (55 publications, 277 ms worst frame) came from this, started by
  the Activity sidebar mounting.

Still open: 36 samples blocked in `routeCursorRect` →
`SLSCopyWindowRoutingRecordsForScreenLocation`, a synchronous window-server
lookup inside `sendEvent`. Stack sampling was active for t=2–22 s, so those
seconds are inflated.

Not measured: a paired timing-only capture of the same chat.

## Decorative motion during scroll — 18 November 2026

A 23 s scroll capture on a 120 Hz display, in Low Power Mode with no running
sessions, lost 31% of frames. The one 30 Hz clock was the edge notch's
blocked-card pulse, and it ticked through every second, even idle ones. With
running sessions, each working indicator adds its own ticks, and each tick
re-renders its host while the scroll is trying to draw.

- `DockMotionSchedule` holds every decorative clock while a scroll is live
  (`DockScrollActivity.remainingSettle`). It resumes on the shared tick grid
  150 ms after the last wheel or momentum event.
- The notch pulses at 15 Hz when its only animated mark is the blocked pulse.
  It keeps 30 Hz for the working mark.

Not measured: a paired capture with several running sessions.

## Markdown scroll layout invalidation — 16 November 2026

Scrolling a chat stays rough after the sidebar and publication coalescing work,
so the question was whether the captures behind those changes describe the
remaining cost. They do not fully.

Observation. The installed `/Applications/Herm.app` reports build `af721430`;
every capture in `~/Library/Logs/Herm/Performance` (`report-3` is
`2026-11-16T11-43-37Z`) carries build `19dee7b5`, which predates `#210`. No
capture exists of a build containing it. The `2026-11-16T07-01-06Z` capture (no
stack samples) still estimates 55% lost callbacks, so sampling is not the cause,
and its seconds with no publications and no body evaluations drop 35-45 of 120
frames (t=10: 76 callbacks, worst 28 ms; t=12: 82 callbacks, worst 32 ms).
`stack-t8s.txt`, taken in such a second, shows the main thread in
`NSDisplayCycleFlush` -> `NSView layoutSubtreeIfNeeded` ->
`NSHostingView.layout` -> `ViewGraphRootValueUpdater.render` for ~93 of 269
samples, with fewer than 25 samples in Herm-owned frames. The per-frame cost is
an AppKit/SwiftUI layout pass, not Markdown section layout.

Mechanism. `MarkdownRenderDocument` registered bounds and frame change observers
on every ancestor up to the clip view, and each notification set
`needsLayout = true` (`Sources/Herm/Markdown/MarkdownRenderDocument.swift`).
Every scroll tick changes the clip bounds, so each mounted assistant message
requested a layout pass per tick, and `updateMountedSections` then returned early
because the mounted range had not changed. The observers now call
`viewportDidChange()`, which mounts the newly visible sections directly and only
requests layout when the solved width or frame cache is out of date; width
changes still go through `setFrameSize` -> `needsLayout`.

Hypotheses still open. Whether this per-tick layout request is what keeps the
window's display cycle in `layoutSubtreeIfNeeded` per frame needs a live A/B on
the same build. The remaining 100-800 ms stalls in `report-3` (t=2, 5, 15, 16,
22, 28) coincide with developer-workflow and session-workspace bursts and
message streaming, which is the publication class `#210` targets; and
`SessionAgentStateWriter.commit` still JSON-encodes on the main thread (14 of 269
samples in `stack-t8s.txt`). Both are follow-ups, not this change.

Recorder bias to control. The recorder's expected interval is always 8333 us, so
dropped callbacks are counted against 120 Hz on a `.common`-mode run-loop display
link; that measures main-thread availability rather than presented frames, and
includes idle seconds where nothing needs drawing. `/usr/bin/sample` suspends the
app while sampling, and Low Power Mode changes frame pacing.

Acceptance for the live comparison. Same conversation, window size, power source
and Low Power Mode on both builds, stack samples off, 30-second scroll captures:
compare seconds with zero publications (callback count, worst gap) and the
`layoutSubtreeIfNeeded` share in an optional sampled run, then confirm focus,
selection and that sections still mount across the whole scroll. This change was
verified by tests and builds only; no live capture of either build was taken
here.

Verification: `MarkdownScrollLayoutInvalidationTests` (2 tests) red before the
observer change on `!container.needsLayout`, green after; the chat hot-path,
render-optimisation, render-cache, scroll-observer, scroll-refresh, manual-scroll
and scroll-fixture suites passed; `make build` and `make guard` passed.

## Multi-session attribution — 18 November 2026

The heaviness is reported while several sessions run at once. The newest capture
(`2026-11-16T11-43-37Z`) was made on build `19dee7b5`, 37 commits behind `main`.
It predates `#212`, `#214`, `#229` and `#243`. It also recorded
`low_power=true` on AC power, which throttles the CPU.

In that capture, seconds with no publications and no counted bodies still lost
30–50% of their callbacks. The main thread was in `NSHostingView.layout` and
AttributeGraph updates, with hover and cursor updates, and almost no time in
Herm frames. The recorder could not say what invalidated the graph, or whether
the open chat or the background sessions caused it. This change adds that
attribution:

- **Scenario context per second.** The timeline adds `running=N`, which is the
  number of sessions working. It also adds `ctx:` marks:
  - `events.current` / `events.background` / `events.unscoped`: gateway events
    handled on the main thread, split by whether they belong to the open chat.
    Their cost is recorded as work under the same names.
  - `transcript.snapshotPublished` / `transcript.snapshotUnchanged`: transcript
    refreshes that changed nothing. These are often triggered by another
    session's publishers.
  - `transcript.page` and `transcript.anchorCorrection`.
  - `scrollWheel`.
  - `session_open.<stage>`.
  - `motionTick@<rate>Hz`: shared animation-clock ticks, each of which
    re-renders the window. These explain publication-free seconds that still
    drop frames.
- **Session opens.** `recordSessionSwitch` stages (`resume`, `parse`,
  `history_project`, `cached_layout`, `fresh_layout`) now appear in the report
  with their timings, not only in `Herm.log`.
- **Publication origins (stack sampling enabled).** For `DockModel`, `ControlCenterModel`, `botMode`,
  `sessionNavNavigation` and `workspaceStore`, each publication's call stack is
  cut after the last Combine frame. The first four Herm frames are kept: the
  `@Published` setter and its callers. At most 6,000 samples are kept, and they
  are symbolicated with `atos` when the report is saved. A stripped build shows
  raw addresses instead.
- **Work and bodies.** New counters cover `transcriptSnapshot`,
  `ConversationTranscriptView`, `ConversationMessageRow`, `TurnActivityView` and
  `SessionNavSidebarSessionRow`. Gateway events, transcript snapshots and session
  opens also emit `OSSignposter` intervals in Instruments' Points of Interest
  lane, so a Time Profiler run lines up with the report.

Fixes in the same change:

- `ConversationChangeSummary.files(in:)` is memoized. A completed tool call's
  diff preview never changes, but every transcript body evaluation re-split it
  for each mounted turn. The cache key is call id plus the preview's size and
  hash.
- `SessionNavSidebarSessionRow` no longer observes `SessionPaneStore` itself.
  Each pane-store publication used to invalidate every mounted row. Parents now
  pass `isShownInPane`, and it is part of the row's equality.

`HoverPausingScrollView` keeps its scroll-phase hit-testing toggle. The
captured stacks show SwiftUI hover updates during scroll, and that toggle is
what suppresses them in the sidebar.

Next capture: a current `main` build, Low Power Mode off, with three or more
sessions working, stack samples on. Within the 30 seconds, open two sessions,
scroll the sidebar, then scroll a long chat. Read `running=` and the
`events.background` work, the `transcript.snapshotUnchanged` count and the
`motionTick` rates for each lossy second. Then read the top publication origins.

Verification: `ConversationChangeSummaryTests` and `HermPerformanceRecorderTests`.
No live capture was taken for this change.

## Idle battery drain from decorative motion — 20 November 2026

A live Herm with working sessions, sitting in the background, sampled at about
8% CPU (`sample`, 10 s) with no input. About 7% of the main thread was
`CA::Transaction::commit` and window layout, driven by `DockMotionSchedule`
ticks: the notch's working mark at 30 Hz and live Bot faces at 15 Hz, which keep
moving while Herm is in the background by design. The clock ran just as fast
with the screen locked or asleep, when nothing could see it.

- `DockMotionBudget` holds every decorative clock when no Herm window is on
  screen (`NSApp.occlusionState`, screens asleep, session switched out),
  re-checking once a second. Visible motion keeps its full rate in the
  background and in Low Power Mode: capping it made the notch visibly choppy.
- The notch's always-on poll timers (delivery questions, Kanban/Bots, quota),
  the pet's parked tick, the pet refresh and the update check now carry timer
  tolerance so macOS can coalesce their wakeups.

Not measured: a paired before/after energy capture; this needs a relaunch.

## Whole-app audit and performance contract — 20 November 2026

Capture `2026-11-20T02-10-27Z` (120 Hz display, Low Power Mode) lost 35% of
frames while scrolling a transcript. Self time per host: `panelLeading` (the
transcript pane) 180–290 ms/s, `root` about 45 ms/s, `panelTrailing` about
3 ms/s. A `ControlCenterModel` refresh burst of 55 publications produced one
277 ms frame.

Fixed:

- Three perpetual animations bypassed `DockMotionSchedule` and rendered at the
  display rate, through scrolls and off screen: the repository loading
  shimmer (`repeatForever`), the voice HUD subagent orbs (cyclic
  `phaseAnimator`) and the live trace clock (`TimelineView(.animation)` at
  10 Hz). All three now use `.dockMotion(rate:paused:)`.
- About 20 parsers built an `ISO8601DateFormatter` per call, several of them
  once per row while refreshing lists on the main actor (Control Center
  activity dates alone have 29 callers). They now share `ISO8601Parsing`;
  a cached parse measured about 3× cheaper.
- The sprite frame timer, the message navigator's 30 Hz pointer poll and
  the dictation meter now carry timer tolerance.

Pane hosts use AppKit's normal constraint update pass so newly visible rows
and changing reply content can lay out. Replacing that pass with a layout
request reduced root layouts from 62 to 30 over 30 scroll steps but dropped
constraint updates in the session list and transcript. The scroll budget
allows two root layouts per step plus settling slack, with zero sibling
layouts. `PaneLayoutBudgetTests` also checks that panes accept update requests.

Not measured: the transcript pane's own ~2 ms layout per scroll tick needs an
Instruments trace on a Release build. Debug (`-Onone`) builds run this
SwiftUI and projection work several times slower; judge smoothness on a
Release build.

### Rechecking the scroll and refresh changes

Use the same conversation, window dimensions, display refresh rate, and power mode for each comparison. Record steady scrolling first. Then open Activity and repeat the scroll while a reply streams. Repeat with several working sessions to distinguish session-event processing from viewport work.

Timing-only captures include callback gaps, host layout, and publication counts. Enable stack samples in a separate recording for publication origins and stalled-frame stacks. The Office scene also records stationary animation and label layout as separate work totals while a recording is active.

The current changes reuse Markdown prefix geometry, suppress hover during live scrolling on macOS 14, and skip a shared Control Center refresh when reopening a recently refreshed sidebar. New frame-pacing measurements for these changes are pending.

The follow-up adds `markdown.viewport` and `markdown.linkCursorRects` to the
recorder and skips custom cursor geometry for sections without links. Session
switches refresh the selected session’s projections. Sidebar refreshes reuse a
capability probe for up to one minute. Repeated success with
unchanged data updates the internal freshness timestamp without publishing.
The simulator stops producing frames while hidden, and its native display
receives same-size frames directly. Diff highlighting batches text edits, the
Timeline cache uses each turn’s activity, row-only updates preserve session
indexes, and Calendar keeps one EventKit event query in flight.

Transcript Markdown documents share clip-view observation. A clip scroll skips
documents wholly outside the clip with no native sections and documents fully
visible with every section mounted. As a long reply crosses a section boundary,
existing sections keep their native frames and newly visible sections are mounted.
Ancestor geometry changes invalidate the clip-relative frame. Streaming keeps
only the short suffix needed to detect a phrase split across flushes. The
Timeline reuses historical call indexes by transcript revision, and Kanban
dragging scans only the destination lane up to the drop slot. Control Center
reuses client-wide capability results and verifies process support from the
focused session’s own process listing. New frame-pacing measurements are pending.

In a standalone AppKit fixture, 30 scroll steps across a 160-section reply
reduced viewport updates to 20 offscreen replies from 600 to zero. The scrolling
reply visited eight sections instead of 204 and mounted the same eight new
sections. This fixture used fixed-height native section views and measured
viewport work rather than text layout or live frame pacing.

Long streamed replies keep their rendered body during completion. Final Markdown
parses off the main actor, and native layout reuses matching stable-section heights.
Stored system notes also parse off the main actor after the history fetch. Navigator
previews refresh on demand and reuse each unchanged message's entry. Split panes
keep their hosting roots and defer content changes while hidden. Large generated
tables reuse filtered and sorted rows and mount near the viewport. Activity event
reads follow visible consumers, read receipts publish once per batch, and PTY
output uses ordered batches of up to 8 KiB with a yield between deliveries.

Under CPU contention, macOS pointer moves share one pending hover delivery per
window, and the desktop split skips an unchanged navigation pane. Final reply
preparation checks the work budget between TextKit chunks and keeps matching
mounted sections through completion. Kanban attribution walks decoded tool fields
without encoding another copy of the payload. Quiet session-index reads wait for
input to settle and merge immutable inputs off the main actor. The merge retries
against newer session metadata before it can publish. Speculative transcript
preloads use utility priority and wait for input between requests.

The two November 21 recordings found that the leading split hosts accounted
for 64–77% of measured hosting layout time, including scroll periods with no
model publications. Frame-sized pane hosts now service constraint updates before
their own layout while the wheel event targets them. AppKit still handles regular
constraint requests outside the gesture and for the other panes. In an isolated
AppKit fixture with both splits, 30 scroll steps took 60 root and 60 outer-workspace
layouts before the change and 30 each after it. The conversation laid out 30 times
and showed the same 30 new rows in both runs. Neither the Chats list nor the
inspector laid out. Pane visibility changes use the layout scheduled by their
frame changes. New captures name each of these hosts separately.

### Shared workspace host

Activity and Chats both reached AppKit window layout in the live Debug samples.
The desktop shell now gives the Chats list, current page, and inspector widths
inside the window's SwiftUI host. In an isolated optimized AppKit fixture, 60
scroll steps produced 120 hosting-view layout passes through one split and 180
through two nested splits. Both shared-host layouts took 60 passes. The Chats
list kept its 640-point scroll offset through collapse and reopening. The
fixture counts layout work and timing from programmatic scrolling.

The workspace status footer observes its own activity and tray state. Online
refreshes skip writing an already empty stale timestamp, and the recorder
reports footer publications under `workspaceStatus`. A live Release trackpad
comparison remains pending.

### Workspace refresh work

The shared-host AppKit fixture ran two 120-step passes per layout and surface.
Mean main-thread CPU per pass changed from 336 to 297 ms for Chats, 273 to 265 ms
for Usage, and 184 to 167 ms for Settings. This Debug fixture uses programmatic
scrolling. Its slowest steps vary with layout and system scheduling.

A separate 400-session, 25-project Debug fixture averaged 10.4 ms per sidebar
rebuild before the activity projection moved off the main thread. The sidebar
coalesces bursts into one utility task and applies its result on the main actor.
Navigation can supersede a pending rebuild, and activity during a rebuild queues
a follow-up. In a paired Debug fixture, 12 updates to that inventory used 117.3 ms
of main-thread CPU through the synchronous path and 20.5 ms through the coalesced
path. Each update published the expected newest row. `sidebarRefresh` records
immediate refreshes and `sidebarPublish` records the cost of publishing a finished
snapshot to its consumers. Opt in with `HERM_SIDEBAR_PROFILE=1` and filter to
`SidebarSnapshotProfileTests`.

Microphone recognition partials update the Talk stage and audio-buffer readings
update the orb. Equal session automation reads and events skip presentation
publications. Loading and stale recovery still publish their visible changes.

Working avatars and their stepping tiles animate on native layers within their
existing footprint. In the Debug AppKit avatar fixture, the SwiftUI clock
control took two host layout passes in one window and six in three windows
over two-second observation intervals. The native avatar took zero in both.
Use `HERM_SCROLL_PROFILE=1` with the `profileWorkingAvatarAcrossWindows` filter.
This fixture isolates the indicator. Live Release frame pacing remains unmeasured.

Chats reuses pin and status projections across pointer and search updates and
pauses unread-count reads when collapsed or covered. Agent-state commits reuse
unchanged encoded session entries and keep the existing atomic v1 archive format.

### Performance contract

`make perf-contract` (part of `make guard`) rejects, in `Sources/Herm`:

| Pattern | Use instead |
|---|---|
| `.repeatForever(` | `TimelineView(.dockMotion(rate:paused:))` + `DockMotionSchedule` |
| `.phaseAnimator(` without `trigger:` | `trigger:`, or `.dockMotion` |
| `TimelineView(.animation…)` | `.dockMotion(rate:paused:)` |
| `TimelineView(.periodic(… by: <1))` | `.dockMotion(rate:paused:)` |
| `XFormatter().…` (allocate and use) | `ISO8601Parsing`, or a stored static formatter |
| repeating `Timer` without `tolerance` | set `timer.tolerance` / pass `tolerance:` |

`// perf-contract: allow <reason>` on the line or the line above opts out;
the reason is required (the pet's drag wobble uses it). The script also
ratchets observation fan-out: the `@Published` count of `DockModel` (118)
and `ControlCenterModel` (93), and the number of views observing either
model whole (43 and 28), may not grow. Lower the caps when a change reduces
them.
