# Async interaction audit

Audited 2026-10-23. Scope: user-triggered SwiftUI actions across Herm, including
buttons that launch tasks indirectly and actions inside menus and confirmations.
Background polling, copy actions, local toggles, and immediate navigation do not
need a new loading indicator. This is a source audit; live provider/system-prompt
latency and the complete theme matrix still require manual acceptance.

| Surface | Feedback after this pass |
| --- | --- |
| Markdown PR/issue navigation | Conversation-scoped Opening overlay throughout resolution; repeat lookup suppressed; existing browser fallback retained |
| Chat composer and runtime approvals | Existing sending/working and approval pending treatments retained; image text extraction shows progress on its attachment and ignores removed or switched-chat attachments |
| Conversation actions | Pin, rename, hide, and delete activity appears in the persistent actions control |
| Group chat | Request progress in header/sidebar and composer, shared room mutation guard, pending approval response; inline retry, history, stop, and refresh indicators |
| GitHub issues/PRs | Existing detail/refresh, metadata, comment, authoring, merge, branch cleanup, and review submission pending treatments retained; floating conversation refresh now indicates progress |
| Source control and review | Existing model refresh/mutation and blame status retained; local review, Hermes review launch, repository and fleet refresh actions now indicate progress |
| Settings/session controls | Steer, rename, redirect, configuration retry, and supplemental refresh actions now indicate progress; confirmed session/project/process mutations show a persistent Applying change overlay |
| Memory correction | Load/inspect controls indicate progress; confirmed save/delete progress remains visible on the editor action |
| Calendar | Create Kanban task shows inline progress; Connect exposes service-owned progress and prevents duplicate permission requests, including requests launched from the calendar toggle |
| Gateway/accounts | Existing test/restart feedback retained; sign-in/out, agent selection/refresh, messaging test/restart, QR creation, and save now expose progress |
| Capabilities | Existing page/header and modal-footer busy feedback retained; skill-hub Search now also has local progress |
| Companion | Gallery refresh now indicates progress; existing Applying label retained |
| Files, browser, terminal | Existing file refresh and browser navigation feedback retained; Send Page to Chat now exposes progress on More; terminal typed commands retain their live terminal output |
| Automation, bots, quota, activity, capture, comparison | Existing model/modal/toolbar pending states retained |

Implementation uses shared design-system controls and existing model state. Spinners
do not insert rows above content. Confirmation flows and provider error handling stay
in place. No runtime contracts, durable operational state, or dependencies were added.
