# Chat scroll verification

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
640-by-600-point viewport, a long Markdown reply every fifth row, and four-message
production paging. Scenarios cover 128 KB of prose, a 1,000-line code fence, and
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
