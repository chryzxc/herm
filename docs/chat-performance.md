# Chat scroll verification

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
