# Performance follow-up — October 15, 2026

Herm is a native macOS frontend for Hermes. This pass assumes one user with
long streaming replies and repeated session-list refreshes. It follows the
existing October 13 audit rather than repeating its implemented changes.

## Findings fixed

1. **Unfinished Markdown could stall streaming.** The fallback chunk splitter
   searched backward through whitespace and rescanned each prefix to determine
   whether inline code, emphasis, or brackets were closed. A long unfinished
   span therefore caused quadratic work on the main actor. The splitter now
   records the last safe whitespace during one forward scan, retaining the
   same split policy and hard fallback.
2. **Session refreshes recreated ISO date formatters per timestamp.** Session
   index parsing now reuses a formatter confined to DockModel's main actor.
   Numeric timestamps and accepted date formats are unchanged.

## Measurements

Local optimized (`swiftc -O`) microbenchmarks, single observations:

| Workload | Before | After |
| --- | ---: | ---: |
| 20 chunk promotions: `prefix `, an opening backtick, then 2,000 copies of `word ` | 1,143 ms | 10.5 ms |
| Parse 1,000 identical ISO timestamps | 129.7 ms | 42.6 ms |

These measure individual CPU operations, not overall app speed or frame rate.
A deterministic comparison of old and new chunk policies preserved split
points for 300 mixed-Markdown fixtures. Native regressions cover unfinished
and closed spans, escaped delimiters, Unicode prefixes, the hard fallback,
and session timestamps across refreshes and time zones.

## Scope and limits

Reviewed streaming chunk selection and completion handoff, session refresh
parsing, Markdown cache bounds, attachment thumbnail loading, repository
command execution, persistence scheduling, and delegation polling. Existing
bounded caches, background I/O, and polling coalescing were retained.
This was a targeted source audit of high-frequency paths, not a line-by-line
review of every app feature.

Not measured: live scrolling/frame pacing, Office GPU cost, cold startup,
voice latency, memory under sustained use, or Hermes/provider network time.
The blank-line block-boundary path still checks inline state for each candidate;
this change specifically removes repeated fallback whitespace-prefix scans.

## Validation

- Debug app and test target compiled successfully in a fixed source snapshot
  at `/tmp/herm-performance-validation.qpKLsf`. The original checkout run was
  invalidated by concurrent edits to `DockTheme.swift`.
- Focused native run: all 78 tests in `StreamingPerformanceTests` and
  `DockNotificationTests` passed, including all three new regressions.
- Full native run: 53 XCTest tests passed. The Swift Testing run reported
  failures in `switchingSessionsRestoresCachedKanbanActivityImmediately`
  (expected task-b, received no tasks) and `everyThemeKeepsTextAndIconsVisible`
  (glass/dark metadata contrast 4.49 versus 4.5). It was stopped after several
  minutes in Office fixtures; the full suite is not green or complete.
  These failures are outside the changed paths; their baseline status was not
  established. The snapshot includes concurrent work present when copied.
- Shell script syntax and `git diff --check` passed. Targeted formatting lint
  completed with style warnings; no broad formatting rewrite was applied.
- Release app build and interactive profiling were not run. The isolated CPU
  benchmarks were compiled with optimization enabled.
