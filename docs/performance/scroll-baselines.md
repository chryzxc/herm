# Synthetic scroll-work baselines

This is a partial measurement surface for #85, not proof of smooth scrolling.
It exercises synchronous production parsing, native Markdown document layout,
history range helpers and Activity projection in an isolated Release test process.
No workspace model, transport or native diff canvas is instantiated. It never
launches Herm, connects to Hermes, opens a browser, or attaches to a user's session. Normal tests do not opt into capture.

## Reproduce

From the repository root on macOS with Swift 6 and Xcode tools:

```sh
sh Scripts/capture-scroll-performance.sh /absolute/new-directory/before
HERM_SCROLL_PERF_PROFILE=1 sh Scripts/capture-scroll-performance.sh /absolute/new-directory/profile
```

The script requires exactly one absolute output path and profiling in {0,1}, and
atomically creates a new leaf directory, refusing existing paths and symlinks.
Owned process groups receive TERM then KILL after two seconds on timeout; surviving
owned descendants are cleaned up without process-name searches.
It compiles tests with
`swift build -c release --build-tests --disable-automatic-resolution -Xswiftc -no-whole-module-optimization -Xswiftc -enable-testing`, then runs
`swift test -c release --skip-build --disable-automatic-resolution --filter ScrollPerformanceCaptureTests`.
Only this test is executed; compiling the executable target does not launch it.
Release optimization remains enabled; whole-module optimization is disabled to
bound compilation cost and testing access is enabled for existing `@testable`
imports. Both sides of any comparison must use those same settings.
`HERM_SCROLL_PERF_OUTPUT` must be absolute and capture is disabled under DEBUG.
Use the script rather than setting that variable in ordinary test runs.

Artifacts: `samples.jsonl` (each operation), `summary.json` (per-cell, per-repetition
statistics and advisory limit), `metadata.json` (scope/settings/unavailable reasons),
`environment.txt` (HEAD, dirty paths, OS, CPU, Swift, load), build/test logs,
`status.txt`, and `profiler-status.txt`. Exports contain synthetic cell names and
numbers, never source text, transcript text, arbitrary environment values or errors.
Keep raw captures with comparisons; these are local artifacts, not telemetry.

## Fixed workload

The standard production fixture supplies 30 projects, 500 sessions, 500 messages,
and a 131072-byte Markdown response. Session IDs/timestamps are fixed. The native
Markdown render key uses a fixed UUID. Message UUIDs from the production fixture
are intentionally not exported or used as cross-run comparison keys.

Each cell has one excluded warm-up repetition and five recorded repetitions:

- Idle: 100 operations per repetition, separately timed preparation, fresh native
  container apply, fresh intrinsic-height/layout, and reused container layout.
  Preparation uses the production builder and may benefit from process caches.
- History: 100 range-helper operations; not a wheel/trackpad gesture benchmark.
- Activity: 100 projections of 1000 completed plus 8 Running pipeline records;
  not a rendered Activity view or polling benchmark.
- Diff: input has 10000 removed/added line pairs with 160-character bodies;
  `diff.parse.bounded-prefix` measures parsing through production's 48 KiB/900-row
  limits. Metadata records input bytes, retained bytes/lines and truncation. This is
  not native canvas layout, scrolling, split/wrap or syntax-preparation coverage.
- Visits and streaming are not measured. Deferred native preparation and model
  completion tasks cannot be attributed safely by this synchronous harness.

Native bounds are 1000x700 points. No SwiftUI theme is instantiated; native views
use host appearance. Reduce Motion is recorded, not changed. No workspace model,
transport, application delegate, browser or window is created.
Cold means a fresh native container, not cold OS caches. Warm means reused native
container with cached intrinsic height. No disk-cache eviction is attempted.

## Units and interpretation

Wall milliseconds use ContinuousClock around synchronous main-actor work. CPU
milliseconds use getrusage user+system time of the entire test process, not just
the main thread. Peak RSS is Darwin ru_maxrss in bytes: a process-lifetime high
watermark, not current memory, per-cell allocation, shared memory or footprint.
Main-thread stack samples require a usable optional Time Profiler trace.

Missing frame/hitch/footprint/shared-memory/display-refresh/browser-enabled data
are null with reasons. Native layout, RPC requests and streaming delta counts
must never be presented as compositor frames. There is no supported 60/120 Hz
pass/fail claim, whole-UI interaction latency measurement or rendering gain here.

Percentiles use nearest rank: sorted[max(0, ceil(p*n)-1)]. Each repetition retains
count, median, p95 and maximum. Run-median minimum/maximum describe variability
between repetitions, not operation p95. Advisory p95 limit is the median of the
five repetition p95s plus twice their maximum absolute deviation from that median.
Zero variance or fewer than five repetitions is uncalibrated (null). These
synthetic operation summaries are descriptive only.
Never fail CI on these timing values. Investigate only after two new comparable
runs exceed a baseline advisory limit; this tooling does not auto-classify regressions.

## Paired before/after procedure

Use the same machine, Swift/Xcode, power mode, appearance, Reduce Motion, window
bounds, fixture, cell IDs, capture code, repetitions and profiler setting. Run
serially with no concurrent builds/captures, allow thermal recovery, and retain
both environment files plus raw samples and summaries. For a base without this
tooling, apply the identical test-only tooling to both worktrees without carrying
production changes. Record base/candidate HEAD and dirty state. Pair each cell and
repetition; report median/p95 and run-median range on both sides, not just a ratio.
Do not compare profiler-instrumented results to uninstrumented results. Rerun
noisy captures and disclose load/thermal differences. Never infer improvements
from this initial baseline alone.

## Profiler and completion boundary

Optional profiling waits for this test's PID only and attempts a 10-second Time
Profiler recording with `--no-prompt`; record is bounded at 45 seconds and TOC
export at 30 seconds. Separate exit statuses and raw samples survive failure.
A template listing or an empty trace is not evidence. Inspect the exported TOC
for actual sampled data before treating a trace as usable. The test reserves a
15-second attach grace before work when profiling is requested.
The script starts the profiler ten seconds into that grace so its ten-second
recording can overlap actual workload rather than recording only the sleep.

Actual frame/hitch captures, whole-UI history/Activity visits and browser-enabled
lifecycle measurements remain required to complete #85. They are unavailable in
this safe isolated host; do not close the issue based on these synthetic captures.
Rollback removes the test tooling/script/docs/link only; no production state or
migration changes.

## Recorded baseline

See the delivery report and retained capture directories for real command results.
The checked-in methodology deliberately does not embed machine-specific absolute
paths or imply results from another environment are universal thresholds.
