# Pull requests and Issues workspace

The features live in `Sources/Herm/PullRequests` and `Sources/Herm/Issues` within
one Herm app target. `GitHub` supplies transport and shared metadata controls;
`Markdown` supplies the canonical parser, attributed renderer, and native hosts.
The app routes typed item references between features and prepares chat context.

## Behavior

- Global and session PR lists keep their own filters and selections, while sharing
  detail records, discussion data, and per-item drafts. Drafts remain in memory.
- My work and repository browsing support history, sorting, metadata filters, and
  saved presentation preferences. Pagination reports partial coverage instead of
  presenting a truncated response as complete.
- Labels, Projects V2 membership and Status, milestones, assignees, and Development
  links use shared Dock controls. Editors stage changes and confirm the item and
  proposed edits. Restricted Projects do not prevent other sections from loading.
- Labels and assignments use deltas. Manual closing references target the issue;
  keyword-derived links are changed through the PR description editor.
- Descriptions, discussion, review bodies, and editor previews use
  `MarkdownMessageView`. Streaming hosts share the same rendering core. Font size,
  source revision, and theme participate in render invalidation.
- Readiness keeps checks, review decisions, draft state, and mergeability separate.
  Unknown mergeability is never displayed as conflict-free.
- Conflict analysis is explicit. It fetches into a temporary bare repository,
  verifies head/base revisions, runs `merge-tree`, and removes the temporary data.
  The operation has cancellation, a two-minute deadline, and a 512 MiB repository
  budget. It does not edit the user's checkout, index, branches, or refs.
- Inline review actions require a diff whose head/base revisions were verified.
  Failed verification retains available files, marks them potentially outdated,
  and disables new inline comments until a successful refresh.
- Landing controls recheck provider permissions and the confirmed head. Merge,
  auto-merge, and merge-queue requests have distinct outcomes; queued does not mean
  merged. GitHub remains authoritative for repository rules.
- Active pages refresh on a 60-second interval. Errors pause automatic retries;
  rate-limit responses gate subsequent requests. Hidden views cancel their tasks.
- Hermes handoffs prepare bounded context without submitting a prompt.

## Validation

Focused suites cover pagination, partial responses, label deltas, restricted
Projects, denied writes and retained drafts, expected-head landing protection,
issue-targeted links, shared detail state, Markdown output/cache behavior, diff
line numbers, and isolated conflict fixtures. `GitHubWorkspaceVisualTests` is an
opt-in fixture renderer for light/dark and narrow/wide layouts:

```sh
GITHUB_WORKSPACE_SNAPSHOT_DIR=/tmp/herm-github-renders \
  swift test --filter GitHubWorkspaceVisualTests
```

The focused run passed 159 tests across 14 suites in an isolated source snapshot
(to avoid concurrent unrelated source edits). Notebook and Terminal fixture
renders were inspected at narrow and wide sizes.

Live GitHub write acceptance, keyboard interaction, native text selection, and
production repository rule combinations still require integration/manual checks.
Run the full required suite in CI. No system notifications are enabled by this
feature. Native conflict editing and arbitrary Project custom-field editing are
outside its scope.
