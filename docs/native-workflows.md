# Native review and workflow architecture

Herm remains a client of Hermes Agent. No runtime fork or replacement agent engine is introduced.

## Ownership

- `Review/`: immutable diff documents, native read-only canvas, local Git comparison
  service, transient review state, versioned recovery for user-authored revision
  notes, and explicit review-guide request coordination.
- `SessionWorkspace/`: session-scoped terminal ownership, local process-tree preview
  discovery, and presentation-only workspace restoration.
- `App/DesktopCaptureService.swift`: explicit window capture and optional accessibility
  context. Settings views stay in `Settings/`.
- `Conversation/`: composer context and saved user drafts. Canonical transcripts and
  execution remain Hermes-owned.
- `Features/GenerativeUI/`: validated visual rendering and offline HTML isolation;
  `GenerativeUIIntegration` remains the only host integration boundary.
- `PullRequests/`: local pending review comments and passive provider polling.

Stored watch lists and workspace references contain no copied
repository source, transcripts, provider responses, or terminal logs. User-authored
drafts and their explicitly attached files use the existing draft store.

## Validation

Run the native workflow, queue, comparison, terminal, draft, GitHub, and generative UI
regressions before release. Render review fixtures with `HERM_WORKFLOW_REVIEW_DIR` and
visual reply fixtures with `HERM_UI_REVIEW_DIR`. Review compact/wide layouts and
light/dark, Glass, and monochrome themes; verify keyboard focus and Reduce Motion.

Live Hermes acceptance must explicitly use local connection settings and isolated
fixture sessions. Permission-sensitive desktop capture requires a real user-granted
Screen Recording permission; optional app text also requires Accessibility.

## Product limits

Local Git, terminals, capture, and server discovery operate on this Mac. Watching
never submits agent work. Guides request analysis but do not enforce a sandbox.
No backend webhooks, remote filesystem parity, connected MCP Apps, or shells surviving
app exit are implied by these client features.

UI regression fixtures additionally use `HERM_WORKFLOW_UI_DIR` with
`WorkflowUIRenderTests`: real native settings switches beside an established
preference row, saved prompts, conversation selection, and context previews. Fixtures cover six themes; settings render at compact
and workspace widths. Rendering a fixture is separate from inspecting its PNG and
from live keyboard, permission, and Hermes acceptance checks.
