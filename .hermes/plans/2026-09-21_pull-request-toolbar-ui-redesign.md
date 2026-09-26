# Pull Request Toolbar UI Redesign

Date: 2026-09-21
Source audit: `DESIGN.md`, the supplied Pull Requests and Issues screenshots,
`Sources/HermesAgentDock/Repository/PullRequestCenter.swift`, and
`Sources/HermesAgentDock/Repository/GitHubIssueCenter.swift`.

## Clarified scope

Improve the Pull Requests list toolbar and make its tabs use the same visual
language as the Issues tabs. This is a presentation-only change:

- Keep the Pull Requests labels `All`, `Reviewing`, and `Authored`.
- Keep each tab's existing filtering behavior and selection repair.
- Do not copy the Issues filters, repository selector, counts, text, or issue
  functionality into Pull Requests.
- Do not redesign the pull request detail pane or change GitHub data contracts.

## Current problems

1. The Pull Requests toolbar puts filters and search in one horizontal row,
   which compresses both controls at the list pane's narrower widths.
2. Its selected tab uses the global accent as a bright filled button. The
   Issues tabs use a quieter selected surface, so the two neighboring repository
   workspaces do not feel like one product.
3. `PullRequestFilterTabButton` and `IssueFilterButton` independently implement
   the same control category with different typography, backgrounds, and
   spacing. This makes future visual drift likely.
4. The toolbar background and search treatment differ from Issues even though
   both screens use the same `PullRequestWorkspace` shell.

## Design direction

**Visual thesis:** a compact, calm repository workbench with one clear search
surface and low-chrome scope tabs that emphasize content over controls.

**Content plan:** retain the existing page header, then present a full-width
search control, the Pull Requests filter tabs beneath it, and the existing
pull-request list/detail split below. No new content is introduced.

**Interaction thesis:** tab selection changes immediately with a restrained
surface-fill transition; hover and keyboard focus strengthen the existing
button affordance without moving layout. Search remains continuously editable.
Respect Reduce Motion and do not add entrance animation.

### Target toolbar

```text
┌─────────────────────────────────────────────┐
│  ⌕  Search pull requests                    │
├─────────────────────────────────────────────┤
│  [ All ]   Reviewing   Authored             │
└─────────────────────────────────────────────┘
```

- Match the Issues toolbar's vertical composition, insets, and control heights:
  14pt horizontal inset, 10pt vertical inset, 8pt row spacing, 34pt search
  field, and 30pt tabs.
- Use `dockControlSurface` for search and a 7pt corner radius.
- Use 11pt tab labels; selected is medium weight and unselected is regular.
- Use `dockSurface4` for the selected tab fill, not `dockAccent`. Keep selected
  text `dockPrimaryText` and unselected text `dockSecondaryText`.
- Leave unselected tabs transparent. Do not add outlines, badges, counts, or
  decorative dividers between tabs.
- Keep the toolbar on `dockCanvas` with one bottom `dockBorderLight` hairline,
  matching Issues and the repository workspace's cardless design language.

## Implementation plan

### Phase 1 — Unify the tab presentation

Files:

- `Sources/HermesAgentDock/Repository/PullRequestCenter.swift`
- `Sources/HermesAgentDock/Repository/GitHubIssueCenter.swift`

1. Extract the existing Issues tab appearance into one repository-scoped,
   reusable view such as `RepositoryFilterTabButton`.
2. Give the shared view only presentation inputs: `title`, `isSelected`, and
   `action`. It must not know about `PullRequestFilter` or `GitHubIssueFilter`.
3. Replace both `PullRequestFilterTabButton` and `IssueFilterButton` with the
   shared view. Issues should render identically before and after extraction;
   Pull Requests should adopt that exact selected/unselected styling.
4. Preserve plain-button behavior, content shape, and semantic color tokens.
   Add a clear keyboard focus treatment only if the existing shared Dock button
   styles do not already provide one.

Expected result: one implementation owns the visual contract for repository
scope tabs, while each screen retains its own enum and actions.

### Phase 2 — Recompose the Pull Requests toolbar

File: `Sources/HermesAgentDock/Repository/PullRequestCenter.swift`.

1. Replace `listPane`'s single horizontal filter/search row with the same
   two-row `VStack` composition used by `IssueWorkspace.issueToolbar`.
2. Keep `TextField("Search pull requests", text: $center.query)` unchanged and
   place it in the first, full-width row.
3. Render `PullRequestFilter.allCases` in the second row using the shared tab
   view. Keep the order `All`, `Reviewing`, `Authored` and the assignment
   `center.filter = filter` unchanged.
4. Remove the vertical divider that currently separates filters from search;
   vertical spacing and the toolbar's bottom hairline provide hierarchy.
5. Do not add the Issues repository menu or open-issue count to this toolbar.
6. Keep errors in their existing stable area below the toolbar so loading,
   refresh, and error state changes do not shift the page header.

Expected result: Pull Requests visually aligns with Issues at 340–460pt list
widths without changing list density or the detail-pane allocation.

### Phase 3 — Accessibility and responsive checks

1. Give every tab a selected-state accessibility value or trait so VoiceOver
   announces the active filter; preserve the visible title as its label.
2. Verify tab order is search, All, Reviewing, Authored, then the first pull
   request row.
3. Confirm tabs remain fully visible at the 300pt minimum Pull Requests pane
   width and do not truncate at default and increased text sizes.
4. Confirm hover, focus, selected, and pressed states remain distinguishable in
   every mapped Dock theme, including forced-light themes.
5. Ensure any selection animation is a short fill transition only and is
   disabled under Reduce Motion.

## Verification

### Automated

- Add a lightweight presentation test for the shared tab style if the current
  SwiftUI test setup supports view inspection; otherwise keep its values in a
  small equatable presentation model and test selected/unselected token roles.
- Keep existing `PullRequestCenterModel` filtering tests unchanged to prove the
  redesign did not alter behavior.
- Run `swift test` and `git diff --check`.

### Manual visual QA

Capture Pull Requests and Issues side by side in at least one dark and one
forced-light Dock theme, checking:

- identical tab height, padding, corner radius, typography, and selection fill;
- Pull Requests still shows `All / Reviewing / Authored` and applies the same
  filters as before;
- the search field does not collapse when the list pane is at minimum width;
- filtering, searching, refresh, loading shimmer, empty results, error text,
  row selection, and detail selection remain stable;
- no toolbar or page-header jump occurs during refresh or filter changes.

## Acceptance criteria

- Pull Requests uses the Issues tab UI exactly, but not Issues text or behavior.
- The active Pull Requests tab uses the subdued `dockSurface4` selection rather
  than a bright accent-filled button.
- Search and tabs fit cleanly at the minimum list-pane width.
- No new controls or passive status labels are introduced.
- Pull request filtering, query matching, selection repair, list/detail state,
  and refresh behavior are unchanged.
- Issues has no visual or functional regression after the shared-component
  extraction.

## Non-goals

- Changing Pull Requests filter definitions or adding an `Assigned` filter.
- Adding repository scope, counts, badges, sorting, or status controls.
- Redesigning pull request rows, detail content, diff review, or session-scoped
  pull request surfaces.
- Changing GitHub API calls, persistence, navigation, or selection semantics.
