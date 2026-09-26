# Transcript Jump Window Performance Remediation

Date: 2026-09-21 (revised same day after review)
Source audit: investigation of the message-navigator jump lag, same session
(`Conversation/ConversationMessageWindow.swift`, `Conversation/Views.swift`,
`Conversation/MessageNavigator.swift`, `Tests/HermesAgentDockTests/MessageNavigatorTests.swift`).

## Problem

Jumping to an older message via the navigator lags, the transcript stays
sluggish afterwards, and — as review surfaced — **any repeated load-more
interaction re-creates the lag**, because the mounted window only ever grows.

1. **Suffix-anchored window.** The mounted transcript is
   `messages.suffix(max(initialLimit, limit))`
   (`ConversationMessageWindow.swift:48-50`). A jump must therefore mount every
   row from the target to the newest message:
   `limitToReveal` returns `totalCount - ordinal + 1`
   (`ConversationMessageWindow.swift:56-65`). Jumping to message 5 of 400
   mounts ~396 rows in one `renderedMessageLimit` state write
   (`Views.swift:2168`). Tests codify this (ordinal 3 of 40 → limit 38,
   `MessageNavigatorTests.swift:114-149`).
2. **Eager layout before the scroll resolves.** The transcript deliberately
   uses an exact `VStack`, not `LazyVStack`, for correct document extent
   (`Views.swift:1927-1931`). All newly revealed rows are constructed and laid
   out synchronously on the main actor before `proxy.scrollTo(messageID,
   .center)` can resolve. First-mount cost per row is high: `MarkdownMessageView`
   parses full bodies through `RenderCache` (misses on first mount), plus avatar
   headers, 4-button action strips, shadows (`ConversationMessageRow.swift:105-256`).
3. **Unbounded accumulation — the general form of the bug.** Nothing ever
   shrinks the window except returning to the bottom
   (`Views.swift:2223-2244`, `ConversationMessageWindow.swift:128-142`).
   "Show earlier messages" grows the suffix limit by 12 per click with no cap
   (`Views.swift:2208-2214`, `revealedLimit` `:52-54`); 30 clicks → ~360
   mounted rows and the same lag as a jump. Any fix that only bounds the jump
   still has this hole via repeated load-more.
4. **Inflated window persists while browsing.** After a jump or load-more
   streak, every scroll frame evaluates per-row `GeometryReader` viewport
   preferences (`Views.swift:1971-1981`) and every popover re-evaluation diffs
   all mounted rows, until the user happens to return to the bottom.
5. **Dead machinery.** `shouldLoadEarlier`/`shouldRearmTopTrigger`
   (`ConversationMessageWindow.swift:158-168`) are unwired and untested.

Note: the working tree already carries uncommitted changes in
`Views.swift`, `MessageNavigator.swift`, `ConversationMessageRow.swift`
(the jump feature itself). This plan builds on that state; land or commit the
in-flight work before starting.

## Goals

- A jump to any message mounts a bounded number of rows (≤ `2 * pageSize + 1`)
  regardless of transcript length or distance from the bottom.
- **Hard bound on total mounted rows under any interaction sequence**: paging
  up or down, in any order, any number of times, keeps the mounted window
  ≤ `3 * pageSize` rows (plus the visible span's margin). Each individual
  interaction mounts exactly one `pageSize` increment.
- The reading position never visually shifts when rows are trimmed off-screen
  (platform scroll anchoring, not manual offset compensation).
- The exact-`VStack` presentation stays (no `LazyVStack` regression to blank
  tails); correctness comes from bounding what is mounted, not from lazy
  estimation.
- Existing contracts preserved: session-scoped jump targets and stale-session
  scroll rejection, unread badge semantics, streaming tail scroll cadence,
  session replacement reset, layout stability per DESIGN.md/AGENTS.md.

## Non-goals

- No virtualization/lazy list rewrite of the transcript.
- No navigator visual redesign (markers, previews, hover behavior unchanged).
- No auto-trigger paging on scroll edge proximity (manual buttons remain the
  interaction; wiring or removing the dead `shouldLoadEarlier` machinery is a
  follow-up).
- No Hermes-side changes; this is presentation-window policy only.

## Design

**One sliding window, no modes.** Replace the suffix limit with a single
clamped `Range<Int>` over the canonical messages. "Tail" is derived, not a
mode: `upperBound == totalCount`. This avoids the mode-transition trap where a
capped tail that pages up must retreat its end below `totalCount` and silently
becomes anchored.

- Per interaction, reveal extends one edge by `pageSize`.
- The opposite edge retreats to `pageSize` beyond the visible span (rows near
  the viewport are never trimmed; the transcript already tracks visibility via
  `MessageNavigatorViewport` preferences, `Views.swift:2053-2067`).
- Hard backstop: mounted count never exceeds `3 * pageSize` (36 rows).
- Trimming above the viewport is visually stable via
  `.scrollPosition(id:anchor:)` (macOS 14; package already targets `.macOS(.v14)`,
  `Package.swift:10`, and already uses `.defaultScrollAnchor(.bottom)`,
  `Views.swift:2022`).

## Workstreams

### Phase 1 — Window model: sliding bounded range

Files: `Sources/HermesAgentDock/Conversation/ConversationMessageWindow.swift`,
`Tests/HermesAgentDockTests/MessageNavigatorTests.swift`.

1. Model the window as a plain clamped range; all transitions are pure
   functions. Keep the file's documented invariant: Hermes owns every message;
   this policy only bounds mounted rows.
   ```swift
   // State: Range<Int> over model.messages indices.
   static func tailRange(totalCount: Int, limit: Int = initialLimit) -> Range<Int>
   static func visibleRange(_ range: Range<Int>, totalCount: Int) -> Range<Int>
   ```
   **`visibleRange` clamps at projection time** so a momentarily stale range
   (same-session refresh/branch shrink) can never index out of bounds.
2. Constants: `jumpContextAbove = pageSize`, `jumpContextBelow = pageSize`,
   `maxMountedRowCount = 3 * pageSize`.
   `jumpWindow(aroundIndex:totalCount:)` clamps
   `index - jumpContextAbove` up and `index + 1 + jumpContextBelow` down.
3. Sliding reveal policy (the core fix for the load-more accumulation):
   ```swift
   static func revealEarlier(
       _ range: Range<Int>, totalCount: Int, visibleSpan: ClosedRange<Int>?
   ) -> Range<Int>
   static func revealLater(
       _ range: Range<Int>, totalCount: Int, visibleSpan: ClosedRange<Int>?
   ) -> Range<Int>
   ```
   - `revealEarlier`: `lowerBound -= pageSize` (floor 0); `upperBound` retreats
     to `visibleSpan.last + 1 + pageSize` (or unchanged if span unknown),
     hard-capped at `lowerBound + maxMountedRowCount`.
   - `revealLater`: `upperBound += pageSize` (ceiling totalCount);
     `lowerBound` advances to `visibleSpan.first - pageSize` (floor 0, or
     unchanged if span unknown), hard-capped by `maxMountedRowCount`.
   - Both guarantee `!isEmpty` after clamping.
4. Jump: `jumpWindowPlan(itemOrdinal:totalCount:)` returns the centered range;
   `jumpPlan`/`jumpEffect` and `ConversationMessageJumpPlan`/`Effect` carry the
   range instead of `renderedLimit`. `navigatorItems` unchanged (navigator
   still indexes the full transcript).
5. Count-change and compaction policy, range-based:
   - `rangeAfterCountChange(range:oldCount:newCount:isAtBottom:)`: at bottom
     and tail (`upperBound == oldCount`): slide — `upperBound = newCount`,
     keep mounted count (matches today's same-limit suffix slide). Otherwise:
     return unchanged (appends never shift indices; new rows simply are not
     mounted while reading above the bottom — the unread badge already covers
     awareness; this is a behavior change from today's grow-off-screen-below
     and is strictly cheaper).
   - `isLiveTail(range:totalCount:)` — `range.upperBound == totalCount`.
     Reading anywhere else means not-at-bottom, even if the mounted window is
     shorter than the viewport (keeps streaming-scroll guards, unread
     counting, and compaction correct for short windows).
   - `shouldCompactAfterRepinning(...)`: only when the window is a live tail
     and wider than `initialLimit`; browsing a non-tail window never
     auto-compacts. `compactedRange(totalCount:)` = last `initialLimit` rows.
   - `specForSessionReplacement()` → `tailRange(totalCount:)`.
6. Tests (rewrite the three window-contract tests; keep session-scoped and
   memoization tests untouched):
   - `revealLater`/`revealEarlier` slide: 40 clicks in one direction keep
     mounted count ≤ `maxMountedRowCount`; each click exposes exactly
     `pageSize` new rows; `visibleSpan` is never trimmed.
   - Alternating clicks converge without growth; unknown span falls back to
     no-trim under the hard cap.
   - `jumpWindow` centers the target, clamps at edges, mounts ≤
     `2 * pageSize + 1` rows; target inside `visibleRange`.
   - `visibleRange` clamps out-of-bounds ranges (negative start, end past
     total, empty transcript).
   - `rangeAfterCountChange`: at-bottom tail slides; otherwise frozen.
   - Compaction: non-tail never compacts; wide tail compacts on repin.
   - `testNavigatorSelectionDispatchesProductionTranscriptHandoff`: effect
     carries the range, scroll target stays mounted, stale-session rejection
     still holds.

Expected result: all window policy is pure and unit-tested; both jumps and
load-more are bounded under any interaction sequence.

### Phase 2 — Transcript integration

Files: `Sources/HermesAgentDock/Conversation/Views.swift`.

1. Replace `@State private var renderedMessageLimit` (`Views.swift:242`) with
   `@State private var mountedMessageRange: Range<Int>` initialized to
   `tailRange(totalCount: model.messages.count)`; `legacyChatScroll`
   (`Views.swift:1938-1941`) uses
   `model.messages[ConversationMessageWindow.visibleRange(mountedMessageRange,
   totalCount: model.messages.count)]`.
2. Track the visible index span: extend the existing
   `MessageNavigatorViewportPreferenceKey` handling
   (`Views.swift:2053-2067`) to also record the min/max array indices of
   rows intersecting the viewport (guarded write, same pattern as
   `visibleNavigatorTargets`). `revealEarlier`/`revealLater` receive it as
   `visibleSpan`.
3. Scroll anchoring for trims: add
   `.scrollPosition(id: $transcriptAnchorMessageID, anchor: .top)` on the
   `ScrollView`, bound to the topmost visible message ID (already derived in
   step 2). This is what keeps the reading position stable when rows above
   the viewport are trimmed. Verify interplay with `.defaultScrollAnchor(.bottom)`
   (initial position only — composes) and `ScrollViewReader.scrollTo`
   (composes; jump/bottom paths keep using `scrollTo`).
4. `jumpToMessage`/`transcriptSelectionHandler` (`Views.swift:2160-2206`):
   the `currentLimit` closure becomes a `currentRange` closure; the effect
   writes `mountedMessageRange = effect.windowRange`. Keep the existing
   yield + session-guard scroll dispatch (load-bearing for stale-session
   rejection; now cheap at ≤25 rows).
5. Edge buttons, one rule each, matching the existing top capsule exactly
   (same Dock styles, 12pt semibold, existing paddings):
   - Top: shown when `range.lowerBound > 0` → `revealEarlier`.
   - Bottom (new, after the message `ForEach`, `Views.swift:1984`): shown when
     `range.upperBound < totalCount` → `revealLater`, `arrow.down` +
     "Show later messages". Per AGENTS.md this is a real capability, not
     filler; it disappears at the transcript end.
6. Resets to `tailRange`: `onAppear` and `onChange(of: model.sessionID)`
   (`Views.swift:2024-2044`), the unread-messages badge (`:2117-2141`),
   `model.scrollToLatestMessageRequest` (`:2068-2072`) and
   `conversationScrollRequest` (`:2073-2075`) — the latter two must reset
   before scrolling to the `"conversation-bottom"` sentinel, otherwise the
   sentinel is reachable but the newest rows are not mounted.
7. `onChange(of: model.messages.count)` (`Views.swift:2076-2102`): use
   `rangeAfterCountChange`; unread-bubble delta logic unchanged.
8. `updateConversationPosition` (`Views.swift:2223-2259`): while the window is
   not a live tail, force `isConversationAtBottom = false` before the geometry
   comparison and skip `scheduleHistoryCompaction`; keep the past-end repair
   untouched (geometry-driven, mode-agnostic clamp to the footer sentinel).
   `scheduleHistoryCompaction` writes `compactedRange`.
9. Navigator viewport preferences and marker coloring need no change — only
   mounted rows report targets, and the navigator already dims unmounted ones.

Expected result: jump to message 5 of 400 mounts 25 rows and lands in the same
frame; paging 30 times in either direction still leaves ≤36 mounted rows; each
click exposes 12 rows without shifting the reader's position; returning to the
bottom (badge, scroll-to-latest, or paging to the end) restores the compact
tail.

### Phase 3 — Cleanup and documentation

1. Decide the dead trigger machinery: delete
   `shouldLoadEarlier`/`shouldRearmTopTrigger`/`topLoadThreshold`/
   `topRearmDistance` (`ConversationMessageWindow.swift:29-30`, `:158-168`)
   or leave with a follow-up to wire edge-proximity paging. Default: delete
   (unreferenced, untested).
2. README Conversations section: update the "Message navigator" and "Streaming
   chat" bullets to state bounded jump context and bounded earlier/later
   paging (same change set, per "Maintaining this document").
3. DESIGN.md: no behavior-rule addition expected (the work *enforces* its
   layout-stability rule at `DESIGN.md:114` — anchoring trims to the visible
   row is exactly that); re-check the transcript section while editing and
   only touch it if it documents history paging.

## Sequencing

| Phase | Scope | Est. | Lands independently |
| --- | --- | --- | --- |
| 1 | Range model + sliding policy + rewritten unit tests | ~0.5 day | yes — `swift build && swift test` green |
| 2 | Transcript integration (state, anchoring, buttons, resets) | ~1 day | yes |
| 3 | Dead-code removal + README | ~0.25 day | yes |

Phase 1 and the Phase 2 edit are one review unit in practice (the view will
not compile against the new API until updated); sequence them back-to-back.

## Verification

- `swift build` and `swift test` after each phase (CI parity per README).
- Unit: sliding-window coverage listed in Phase 1 step 6 (repeated reveals
  stay capped, visible span never trimmed); the production handoff test must
  still assert the stale-session rejection.
- Manual matrix:
  - 400+ message session: jump to an early marker — no perceptible hitch,
    target centered, ~2 screens of context both directions.
  - Page down 30 times from the jump target: each click exposes 12 rows, no
    reading-position jump when older rows trim, scroll smoothness at click 30
    ≈ click 1.
  - Page up 30 times from the live tail: same bound, same stability.
  - Alternating up/down clicks: no growth ratchet.
  - Streaming while reading an old window: live row not mounted, unread badge
    counts new bubbles, badge tap returns to the compact live tail and follows
    streaming.
  - Scroll-to-latest, unseen badge, and session switch while browsing history:
    immediate tail restore, no blank tail, no past-end overshoot (footer clamp
    intact); `scrollPosition` binding does not fight `scrollTo` or the initial
    bottom anchor.
  - Unread badge and compaction-on-return-to-bottom behave exactly as before.

## Documentation

User-visible behavior changes (bounded jump context, "Show later messages"
button, bounded history paging) → README Conversations bullets updated in the
same change set. DESIGN.md expected unchanged (verify while editing).

## Risks

- **`scrollPosition` interplay (highest risk).** The `id:` binding must not
  fight `ScrollViewReader.scrollTo` (jump/bottom paths) or
  `.defaultScrollAnchor(.bottom)` (initial position), and its per-frame
  binding writes must be guarded like `visibleNavigatorTargets` to avoid
  re-render churn. Fallback if it misbehaves in practice: drop the binding and
  compensate trims with `proxy.scrollTo(anchorRowID, anchor: .top)` in the
  same transaction (accepting a possible one-frame correction), or initially
  ship trims only on the reveal-*below* direction where the trimmed rows are
  above the click target by two full margins.
- **Visible-span plumbing.** `revealLater` trims from the top using
  `visibleSpan`; if the span is reported stale (preferences coalesce), the
  `pageSize` margin plus `maxMountedRowCount` backstop still guarantees
  correctness — only memory tightness degrades.
- **Same-session message-array replacement** (refresh/branch):
  projection-time clamping prevents crashes; identity is normally guarded by
  the session replacement reset — verify the refresh path in manual testing.
- **Reading above the bottom no longer mounts appended rows off-screen** (they
  arrive on return-to-bottom instead): cheaper, but confirm the unread badge
  reads as sufficient awareness in manual testing.
- The three rewritten contract tests must not weaken the session-scoping
  assertions they currently carry.
