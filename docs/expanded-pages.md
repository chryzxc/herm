# Expanded pages

Any view that expands to fill the window (Timeline, file diffs, local and
observed reviews, pull request code review) uses `DockExpandedPage` from
`Sources/Herm/DesignSystem/DockComponentStyles.swift`. Do not hand-roll a header
for an expanded layer: a plain `VStack` header draws under the traffic lights.

## What the component owns

- The title row. It renders `DockPageHeader`, which moves into the window title
  row beside the traffic lights when `\.dockTitleRow` is set (the router sets it
  for windows with chrome) and clears their width.
- Close. An optional close action supplies a `.dockCompact` Close button with `.keyboardShortcut(.cancelAction)`,
  so Esc closes every expanded page. Do not add a second close or
  `onExitCommand`. Persistent navigation pages omit the close action and do not
  capture Escape. Existing expanded presentations keep their Close action.
- Content isolation. Content gets `\.dockTitleRow` set to `nil` so nested
  `DockPageHeader`s render as ordinary panel headers.
- The canvas background.

## Usage

```swift
DockExpandedPage(title: "Timeline", subtitle: "Session execution", close: close) {
    SessionTraceCanvas(...)
        .padding(.horizontal, 16)
}
```

Optional: `help` (header tooltip, e.g. a full file path), `onRefresh` and
`isRefreshing`, and a `trailing` builder for actions placed before Close.

## Presenting

Present through the expanded-review router, and fall back to a sheet when the
window is too narrow (the router refuses below 800pt):

```swift
@Environment(\.expandedReviewRouter) private var reviewRouter
@State private var expandedSheet = false

Button {
    if reviewRouter?.present(expanded { reviewRouter?.close() }) != true {
        expandedSheet = true
    }
} label: { ... }
.sheet(isPresented: $expandedSheet) {
    expanded { expandedSheet = false }
        .frame(minWidth: 900, minHeight: 640)
        .modifier(ReviewSheetContext())
}
```

`ReviewSheetContext` clears the router and title row inside the sheet, so the
same `DockExpandedPage` renders as a normal sheet header there.

## Current users

- `SessionTraceExpanded` (Timeline)
- `SharedDiffView` in expanded presentation (file diff)
- `LocalReviewWorkspace`
- `ObservedRequestReview`
- `PullRequestDetailView.expandedReview` (inspector code review)
