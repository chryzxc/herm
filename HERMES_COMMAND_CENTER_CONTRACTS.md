# Hermes Command Center Contracts

Herm intentionally leaves these surfaces unavailable until Hermes
advertises a runtime capability and returns bounded, redacted structured data.
Herm must never replace these contracts with terminal-table parsing or direct
provider SDK calls.

## Repository and activity

- `projects.repositories.list` (`projects.repositories`): paginated stable
  project/repository IDs, safe display name, repository-root reference, active
  state, and revision.
- `activity.changes.list` (`activity.changeFeed`): cursor-based bounded events
  with stable ID, source timestamp, category, source references, and safe
  summary. Prompt bodies, credentials, raw tool output, and arbitrary paths are
  forbidden. This is required for durable activity history.
- `sessions.usage.list` (`sessions.usage`): per-session model, token categories,
  context use/max, timestamps, and optional provider-supplied cost. This is
  required before cross-session usage or cost totals appear.

## Developer integrations

- `dev.pull_requests.list` (`dev.pullRequests`): repository ID, number, title,
  state, draft state, review decision, merge state, and safe URL.
- `dev.ci.status` (`dev.ci`): repository/revision, check name, state,
  conclusion, timestamps, and safe URL.
- `dev.errors.list` (`dev.errors`): issue ID, title, severity, state,
  first/last seen, count, and safe URL.

All collection responses use `items`, `next_cursor`, and an inexpensive total
when available. Errors use a safe message and retryability metadata. Hermes,
not Herm, owns OAuth, provider SDKs, credential storage, redaction, and
authorization.

## Existing deferred contracts

`cron.reports.list/get`, `mcp.tools.get`, and `mcp.tools.invoke` retain the capability, schema, confirmation, authorization,
and redaction requirements documented in `IMPLEMENTATION_PLAN.md`.

## Implemented workflow adapters

Herm now has named, typed wrappers for `skills.manage`, `mcp.catalog`,
`mcp.servers.list/add/set_api_key/test/remove`, MCP OAuth start/poll/cancel,
`subagent.list/steer`, and `learning.detail/edit/delete`. Support is checked per
operation from actual responses; a version number or one successful integration
does not authorize another method. The registry is `HermesFeatureIDs`.

- Installed skills, including disabled entries, come from `profiles.describe`;
  skill toggles use the verified profile-scoped `/api/skills/toggle` route.
  Removal uses Hermes' hub uninstall route and checks the returned action name/PID
  against its recorded exit code. Starting a process is not successful removal.
- Named-profile memory uses the verified scoped `/api/learning/node` routes,
  which call Hermes' learning mutations. The launch profile may use learning RPC.
  Fingerprinted entry IDs prevent unsafe positional edits after replacement.
- Cron lists and mutations carry their owner. Run now uses the named Hermes CLI
  operation with an explicit profile and requires a successful exit result.
  Report bodies use an actual captured session; no structured cron-report API is
  invented. Run and delivery outcomes are distinct.
- Recall uses `/api/sessions/search`, an explicit profile, and a 20-result cap.
  Its supplied snippets have no message IDs, so navigation opens conversations.
- Session capacity requires owned resume, configured `model.options`, and
  acknowledged `config.set` session scope. Multiple quota accounts are not
  attributed to a session. `session.interrupt` must confirm interrupted status.
- Worktree creation uses the existing native Git adapter. Hermes session creation
  sends `cwd` and `cwd_explicit`, then validates the returned owner/directory.
  Partial success is preserved. Subagent steering acknowledges Queued separately
  from delivery; the current list contract does not prove eventual delivery.

Quiet/digest and source/working-set preferences persist references only. Quick
unsent content has its own versioned Application Support store. No Hermes session
database or transcript index is copied into Herm.

### Notch working-set metadata and observed compatibility (2026-10-13)

Working-set watch uses the existing profile-scoped `session.list` contract, requesting at most
200 recent records. This read supplies titles and previews, not authoritative busy state. Live
state is accepted only from events with an explicitly supplied or previously captured owner;
unresolved aliases mark projections stale. At most two profile reads run concurrently, through
the existing ControlCenter client and event subscription. Saved actions and checkpoints require
no new Hermes method; they prepare local drafts only.

The installed runtime accepted the dedicated test profile and idempotent explicit-directory
session creation. A lazy `session.resume` response omitted `info.profile_name` for a named
profile. Herm retains the owned-resume refusal and explains that ownership could not be
confirmed. Version strings do not override this response check. Independent read and capture
checks are recorded separately; a successful transport test does not establish model-turn,
approval, routine, integration authorization or keyboard acceptance.
