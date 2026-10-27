# Pull requests and Issues workspace

The features live in `Sources/Herm/PullRequests` and `Sources/Herm/Issues` within
one Herm app target. `GitHub` supplies transport and shared metadata controls;
`Markdown` supplies the canonical parser, attributed renderer, and native hosts.
The app routes typed item references between features and prepares chat context.

## Behavior

- The primary rail has one GitHub destination. Its inner navigation selects Pull
  requests, Issues, or Repositories beside the existing page; narrow workspaces use a section
  picker. Returning restores the last section used in the app session. Settings → General → Sidebar provides one
  Show GitHub in sidebar switch; all three inner sections remain available.
- Global and session PR lists keep their own filters and selections, while sharing
  detail records, discussion data, and per-item drafts. Drafts remain in memory.
- My work and repository browsing support history, sorting, metadata filters, and
  saved presentation preferences. Pagination reports partial coverage instead of
  presenting a truncated response as complete.
- Labels, milestones, assignees, and Development
  links use shared Dock controls. Editors stage changes and confirm the item and
  proposed edits.
  Label pills retain GitHub’s repository-defined RGB colors in details and editors,
  with contrast-selected text; missing or malformed colors use the neutral theme.
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
  merged. GitHub remains authoritative for repository rules. Non-passing checks
  are warnings when GitHub reports a mergeable state (`UNSTABLE`); the app does
  not assume every check is required. Provider-reported blocks remain enforced.
  A successful merge applies the returned merged PR directly to the shared detail
  owner; merged is terminal across stale reads and list refreshes. The success
  card offers remote branch deletion with provider permission and default/protected
  branch guards. Atomic `updateRefs` compares the confirmed revision before
  deleting, including for fork heads. Local branches and worktrees are unchanged.
- Active pages refresh on a 60-second interval. Errors pause automatic retries;
  rate-limit responses gate subsequent requests. Hidden views cancel their tasks.
- Hermes handoffs prepare bounded context without submitting a prompt.
- Network actions show pending feedback in the active control and prevent repeat
  submissions. Confirmations capture the selected item and action before dismissal.
  PR and issue lifecycle writes apply the provider response immediately; stale
  in-flight reads cannot undo it. Failed saves retain drafts and choice-load
  failures expose Retry rather than a perpetual loading state.

## Validation

Focused suites cover pagination, partial responses, label deltas,
denied writes and retained drafts, expected-head landing protection,
issue-targeted links, shared detail state, Markdown output/cache behavior, diff
line numbers, and isolated conflict fixtures. `GitHubWorkspaceVisualTests` is an
opt-in fixture renderer for light/dark and narrow/wide layouts:

```sh
GITHUB_WORKSPACE_SNAPSHOT_DIR=/tmp/herm-github-renders \
  swift test --filter GitHubWorkspaceVisualTests
```

Set `GITHUB_NAVIGATION_SNAPSHOT_DIR=/tmp/herm-github-navigation` to render the shared
GitHub section navigation with both pages at narrow and wide sizes in light, dark,
Glass, and Monochrome themes.

The focused run passed 159 tests across 14 suites in an isolated source snapshot
(to avoid concurrent unrelated source edits). Notebook and Terminal fixture
renders were inspected at narrow and wide sizes.

`GitHubActionStateTests` also exercises delayed status/review writes, duplicate
submission prevention, dialog dismissal, stale or failed lifecycle follow-up
reads, issue list scope, and preserved local repository mapping. The action-state
pass ran 100 focused tests across 14 suites in the isolated validation copy.
Pending review snapshots were rendered in all four themes, with Notebook and
Monochrome checked visually.

Live GitHub write acceptance, keyboard interaction, native text selection, and
production repository rule combinations still require integration/manual checks.
Run the full required suite in CI. No system notifications are enabled by this
feature. Native conflict editing is
outside its scope.

GitHub Issues, Pull requests, and Repositories share `GitHubAccessRecoveryView`: a
compact permission panel with a selectable CLI command, Copy command, and pending
Retry feedback. Typed sign-in and permission errors show this panel when no cached
records exist; ordinary outages and rate limits retain their existing error UI.

GitHub includes a Repositories tab listing repositories accessible to the existing
GitHub credential, ordered by GitHub’s last-updated timestamp, newest first, with undated entries last.
List timestamps show that same update time; the detail pane separately shows the last push. Search matches names and descriptions;
visibility and archived filters operate on the loaded inventory. Repository browsing
uses the same single page header and resizable list/detail layout as Issues and Pull
requests. On wide windows, a compact list opens a spacious native detail pane; narrow
windows use the shared Back navigation. Details include description, language,
visibility, stars, forks, combined open issue/PR count, default branch, last push, and
license. The overview uses the loaded inventory and supports refresh; missing values
remain unavailable. Open on GitHub is a separate action, and Copy clone URL copies the
HTTPS address without cloning. The tab uses the shared access-recovery panel, reports
partial coverage, and retains data on refresh failure. Filters survive switching between
GitHub sections.

Repository browsing explicitly includes owner, collaborator, and organization-member
affiliations available to the active GitHub credential. The owner filter includes all
returned accounts and organizations; search and archive filters apply across them. Rows
use shared typography, compact descriptions, and the standard divider-led selection
treatment. Repository glyphs, visibility, and star metadata use neutral theme ink.
Language names use neutral pills with the existing bundled file icons; unknown languages
use a generic file icon, and Monochrome/E-Ink render the glyphs in neutral ink. Search,
visibility tabs, and a fixed status slot match the GitHub list controls. Details use
shared section headers and inspector groups; actions share compact sizing, and the
standard copy control confirms temporarily. The repository detail pane also loads the
five most recent commits on the default branch and the first release returned by GitHub,
including its tag, publication date, and draft or pre-release state. Commit links, SHA
copying, release notes, and an explicit external Actions link support deeper inspection.
Issues and Pull requests open the existing native browsers scoped to the selected
repository, with open state and recently updated sorting. Previous list filters and rows
reset on entry; cached details and comment drafts remain available. Search,
state/history, conversations, reviews, authoring, and recovery use the existing
features. The inventory supplies your highest reported repository permission and last-
updated time; absent permissions remain unavailable. Commit and release reads share the
existing GitHub credential, load independently, retain prior data with a stale note on
refresh failure, and cancel when the detail pane closes or changes repository. The
detail toolbar refreshes these reads and a recent activity feed. The feed shows up to
ten events returned by GitHub, ordered newest first, with actor, action, target, time,
and safe links to the relevant repository page. It includes pushes, issue and PR
updates/comments/reviews, releases, branch/tag changes, and other reported events.
Counts are labeled Statistics; recent issue, comment, and release events remain in
Overview. GitHub can delay events and limits the available history; an empty response
does not imply the repository has never been active. Activity has independent
unavailable, retry, and stale-data states and cancels with the selected repository.
Repository language labels are neutral pills with the same bundled Material file icons
used by file previews and Markdown. Unknown languages keep their name and a generic file
icon; Monochrome and E-Ink desaturate the glyph. Visibility and counts stay neutral.
From a repository, Issues and Pull requests open Herm’s existing native browsers with
that repository as the server-side scope, open state, and recently updated sorting.
Previous list filters and rows reset on entry so unrelated account data is not shown;
existing detail caches and comment drafts are retained. The usual search, state/history,
review, conversation, authoring, and recovery features remain available. Actions remains
an explicitly external GitHub link. A separate Activity tab follows GitHub’s repository
code activity view: compact commit-message rows, actor avatars, branch links, revision
ranges, and semantic merge/force-push badges. Branch, activity type, user, time-period,
and oldest/newest filters query GitHub’s repository activity endpoint. Branch/user menus
list values discovered in loaded activity. Up to 30 matching records are shown per
query, with an explicit coverage note at the limit. Visible rows load commit messages
and comparison counts using shared, bounded requests; missing counts are never invented,
and immutable details are retained if a refresh fails. Row menus open changes, copy
links or SHAs, and retry failed commit details. Switching filters cancels old work and
clears rows from the previous scope; leaving the pane cancels pending reads.
Repository browsing uses a compact filter toolbar and one detail tab bar. Overview uses an unboxed identity, compact statistics, and divider-separated repository details, release, commits, and events. Shared theme typography, language pills, native navigation, copy actions, and Activity filters remain consistent across widths.
