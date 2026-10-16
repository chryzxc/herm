# App smoothness audit

Audited on October 13, 2026. Herm is a native macOS frontend for a local Hermes
runtime. The assumed load is one user with multiple active sessions, a busy
terminal, long replies, file previews, and background notch polling.

The review covered UI-thread file and process operations, repeated publications,
timers, rendering caches, transcript paging, Explorer highlighting, terminal
output, voice media, local persistence, quota refreshes, and Office lifecycle.
The changes keep the existing data owners and UI layout.

## Findings and fixes

| Priority | Trigger and lag source | Change |
| --- | --- | --- |
| 1 | Busy terminal: every PTY chunk split and rebuilt the retained transcript, copied it into a published property, and invalidated the surrounding SwiftUI workspace. | Count new bytes and newlines incrementally; trim only when a limit is crossed. SwiftTerm still receives the original bytes immediately. The diagnostic text is readable without publishing a redundant UI update. Blank lines and valid Unicode are retained. |
| 2 | Explorer: opening or editing a large file ran full-document syntax tokenization on the UI thread. Debouncing delayed that work but did not remove the pause. | Tokenize in a background task. Cancel superseded work and verify the source and path before applying colors. Native text edits and selection stay on the UI thread. |
| 3 | File review: opening the notes popover calculated the same line difference repeatedly during rendering. The one-second reload loop also read filesystem metadata on the UI thread. | Compute the difference in a background task when the baseline or document changes, only while notes are open. Read metadata in the background and discard canceled reload results. |
| 4 | Notch: the five-second delivery-question poll enumerated a directory, read every JSON file, and decoded them on the UI thread. | Read and decode in a background task, allow one poll in flight, and retain the existing sorted projection and answer validation. File removal after a successful answer also runs in the background. |
| 5 | Voice HUD: browser screenshots and generated images loaded through full-resolution `NSImage` file reads on the UI thread. | Reuse the shared background thumbnail loader and bounded image cache. Ignore canceled screenshot results. |
| 6 | File review: saving a note encoded the entire review archive and performed an atomic write on the UI thread. | Snapshot local review state and encode/write on an ordered serial queue. Drain pending writes during app termination so the final saved note is retained. |
| 7 | Attached or paused pet: a 20 Hz movement timer assigned the unchanged zero direction to an observed property, rebuilding its SwiftUI content. | Publish a direction change only when the value changes. Walking and sprite animation retain their existing cadence. |

## Measurements

Two local microbenchmarks used `swiftc -O`. They measure specific CPU work;
they do not measure trackpad frame rate or overall app speed. Other builds were
running during the audit, so these are individual observations rather than a
controlled hardware performance study.

| Fixture | Before | After |
| --- | ---: | ---: |
| Terminal retention: 4,000 chunks, each `log <index>: ` plus 70 ASCII characters and a newline; default 256,000-byte / 2,000-line limits | 62,868 ms | 31 ms |
| Tokenize 262,132 bytes of repeated Swift source, producing 33,228 tokens | 654 ms on the UI thread | Same parser runs in the background |

Both terminal implementations retained 162,000 bytes for the log fixture.
Regression tests additionally check blank lines, chunk boundaries, oversized
Unicode lines, and absence of redundant terminal UI publications.

## Existing protections retained

- Chat mounts a bounded message window, caches completed Markdown and native
  heights, isolates streaming text, and restores history anchors through the
  native clip view. Upward scrolling cancels streaming follow immediately.
- Repository command execution and directory/file reads already run off the UI
  thread. Workspace and activity archives already have background writers.
- Attachment thumbnails and uploads already prepare their payloads off the UI
  thread. Debug logging uses an ordered background queue.
- Quota reads run concurrently; quiet polling avoids publishing unchanged
  snapshots. Kanban parsing also has an off-thread path.
- Office reuses room geometry and materials and cancels movement/subscription
  work when its native view is dismantled.

## Validation and limits

Focused coverage includes terminal interaction and retention, file-review
persistence, delivery-question decoding, thumbnail loading, voice HUD semantics,
Explorer syntax and document replacement, pet behavior, and chat scroll guards.
Validation ran against a temporary source snapshot because gateway and keyboard
work was being edited concurrently in the live workspace. The final delivery
poll cancellation guard and matching gateway test macro corrections were applied
to the snapshot before the successful regression run.

- Debug build: passed.
- Focused regressions: 82 tests passed (25 XCTest and 57 Swift Testing).
- Full native suite, outside the execution sandbox: 53 XCTest tests passed;
  1,287 Swift Testing tests completed with one failure. The failing
  `GatewayConnectionTests.remoteTransportUsesTheProxyPrefixAndAuthenticatesBothProtocols`
  returned `.disconnected`; it does not exercise the smoothness changes.
- The sandboxed full run could not validate clipboard, tooltip, loopback, and
  RealityKit fixtures. Those UI and Office failures cleared in the native run.
- Repository lint completed with existing formatting warnings; shell syntax
  checks and `git diff --check` passed.
- Release build: passed against the same source snapshot. Existing compiler
  warnings remain.

Not measured: live trackpad frame timing, GPU frame cost in the 3D Office,
microphone/audio latency, or response time of external Hermes/provider services.
Native TextKit layout and applying syntax colors still run on the UI thread.
Those need interactive profiling before another rendering change is justified.
