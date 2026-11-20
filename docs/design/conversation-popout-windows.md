# Conversation pop-out windows (#275)

Status: design, awaiting approval. Prototype scope.

## Intent

Let a conversation detach from the main workspace into its own small
floating window, like tearing a tab out of a browser. Several can be open at
once, dragged anywhere on either monitor, and resized, so ongoing work can be
followed and steered beside a browser or editor without switching the main
workspace back and forth.

## Goals

- "Pop Out Conversation" detaches an existing conversation into a compact
  floating window holding only that conversation: transcript + composer
  (approvals, clarifications, stop, and attachments work as in split columns).
- The window title row identifies the conversation (title) and its profile.
- Detach semantics: a conversation lives in exactly one place. While a
  conversation is popped out, the main window and split columns do not also
  load it; selecting it anywhere brings its window forward instead.
- Opening or closing a pop-out never creates a Hermes session and never
  interrupts a running turn. Hermes keeps the history; closing only drops
  the view, and the conversation stays in the sidebar.
- Several windows at once, each movable across displays and resizable;
  frame remembered per conversation.

## Non-goals (prototype)

- Restoring pop-outs after relaunch (split columns don't either).
- Starting a new chat directly in a window; only existing sessions detach.
- Group chat rooms (not Hermes sessions) and dragging a row/tab out of the
  window to detach.
- Re-attach gesture back into the main window (close the pop-out, then click
  the chat in the sidebar).
- A sidebar, tabs, model/profile switching, or session tools inside the pop-out.

## Anti-goals

- A second durable store for Hermes data, or any Hermes engine change.
- A duplicate conversation, or two live views reacting to the same approval.
- Closing a window that stops or cancels agent work.

## Constraints

- Hermes-owned state only through existing RPCs/events (`session.resume`,
  `prompt.submit`, the shared gateway event stream).
- `WorkspaceStore`/UserDefaults may hold window frames only (display state).
- Follow DESIGN.md: shared `Dock*` components and color roles, `.dockPill` for
  the profile label; check Light, Dark, Glass, Monochrome.
- Must not relaunch the app (`make run`) during development.

## Approaches considered

- **A. Small window per conversation reusing the split-column chat (chosen).**
  `SessionPaneChat` on a disposable `EdgeQuickConversationModel`, exactly the
  path split columns, the notch quick chat and PR chat already use (shared
  gateway RPC client + `eventRouter` subscription, throwaway defaults suite).
  Smallest change, built on proven code.
- **B. Full workspace per window** (own `DockModel` + `DockPopover`). Rejected:
  every window would poll the session index and carry its own profile scope
  and settings; heavy, and contrary to "stays on one conversation".
- **C. Tear split columns off into windows** via `SessionPaneStore`. Rejected:
  couples window lifetimes to a single-window column layout store.

The user picked detach semantics and a small floating window holding only the
conversation panel.

## Design

**`ConversationWindowStore`** (`@MainActor`, shared, in `Conversation/`)
- `windows: [String: ConversationWindowController]` keyed by durable session id.
- `open(_ destination: QuickDestination, runtime:)`: if already open, focus it;
  otherwise create a controller. If the session is the main window's open
  conversation, the main window leaves it first (see below). If it sits in a
  split column, it is closed from that column.
- `focus(sessionID:) -> Bool`: brings a pop-out forward; used by routing.
- `isDetached(_ sessionID:)`, published `detachedSessionIDs` for the sidebar.
- `close(sessionID:)`, called from `windowWillClose`: shut down the model,
  unsubscribe, remove the entry.
- Pure resolution helper (testable, like `SessionPaneStore.resolve`):
  given session id, main-open id, column tabs, and detached ids, return
  `.focusWindow` / `.openWindow(leaveMain: Bool, removeFromColumn: Int?)`.

**`ConversationWindowController`** (`App/`, beside `DockWindowController`)
- An `NSPanel` (titled, closable, resizable, full-size content) at `.floating`
  level that can become key so the composer takes typing; does not hide when
  Herm deactivates; does not change the activation policy (Herm stays out of
  the Dock, like the notch panel).
- Default content size about 420x600; min about 320x360. Frame autosaved
  under `HermConversationWindow.<sessionID>`. First open cascades from the
  mouse's screen.
- Content: a 52pt title row (conversation title + profile `.dockPill`, under
  the traffic lights, following `DockWindowChrome`), then `SessionPaneChat`
  with window-sized `ConversationWorkspaceMetrics`; loading/failed states from
  `EdgeQuickConversationModel` in the same container.
- Title follows the session list (rename updates it); a deleted session closes
  its window.

**Routing hooks**
- `SessionNavigation.openSession(_:)`/`selectSession(_:)` path: if the store
  can focus a pop-out for that id, focus it and do not select it in the main
  window. This covers sidebar clicks, bot chat, project and PR chat openers.
- `SessionPaneStore.open`: a detached session focuses its window instead of
  adding a column/tab.
- Main window leaving a detached conversation: the same behavior as when the
  open conversation is deleted (clear selection to the empty/new chat state).
  Builder may use navigation history "back" instead if it is already exposed.

**Entry points**
- Sidebar row context menu: "Pop Out Conversation" beside "Open in Split View"
  (`SessionNavSessionRows.contextActions`), and the same on Bot chat rows
  (`BotChatsPage`) if it is a one-line addition.
- "Pop Out Conversation" in the chat header's existing "Conversation actions"
  menu (main header and split-column header), shown only when a saved
  session is open. (Planning call: a menu item instead of a new standalone
  header button, per the no-extra-chrome rule.)
- Sidebar rows of detached chats show the existing "shown" highlight that
  split columns use (`shownSessionIDs`), extended with detached ids.

**Known quirk carried over from split columns.** Closing the window discards
that window's unsent composer draft (`DockModel.shutdown`). Acceptable for
the prototype; noted in README.

## Tests (`Tests/HermTests/ConversationWindowStoreTests`)

- Resolution helper: already detached -> focus; main-open -> leave main;
  in column -> remove from column; group room id -> rejected.
- Store open/close bookkeeping: second open focuses, close removes the entry
  and unsubscribes from the event router, no `session.create` is issued
  (fake RPC client).

## Docs

README: a short "Pop-out conversations" paragraph. DESIGN.md: a spec inside
the conversation surface section for the pop-out window chrome.

## Left to the builder

Exact icon, title-row spacing, cascade offsets, whether bot-page entry is
included, and whether Spaces behavior needs `collectionBehavior` tuning
(default: stays on its Space, allowed beside full-screen apps).
