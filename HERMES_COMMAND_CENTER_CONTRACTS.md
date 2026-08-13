# Hermes Command Center Contracts

Hermes Agent Dock intentionally leaves these surfaces unavailable until Hermes
advertises a runtime capability and returns bounded, redacted structured data.
The Dock must never replace these contracts with terminal-table parsing or direct
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
not the Dock, owns OAuth, provider SDKs, credential storage, redaction, and
authorization.

## Existing deferred contracts

`cron.reports.list/get` and `mcp.catalog`, `mcp.tools.get`, and
`mcp.tools.invoke` retain the capability, schema, confirmation, authorization,
and redaction requirements documented in `IMPLEMENTATION_PLAN.md`.
