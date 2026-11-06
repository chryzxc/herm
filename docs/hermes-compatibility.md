# Tracking Hermes Agent changes

Herm’s tracker detects review work; it cannot prove an upstream runtime is safe.
The reviewed baseline is `Sources/Herm/Resources/HermesCompatibility.json`.
It is deliberately independent of the user's installed or running runtime.

## What runs

- Settings → Updates → Compatibility reads public GitHub metadata on opening
  (six-hour successful-check cache) or Check upstream. It resolves main once,
  then fetches the OpenRPC document at that exact SHA. It keeps successful results
  in memory and labels them stale if the next check fails. No credentials or
  session data leave Herm.
- `.github/workflows/hermes-compatibility.yml` runs daily at 09:00 Manila time,
  on manual dispatch, and on pull requests changing the scanner or baseline.
  It publishes an Actions summary and retains its Markdown report for 30 days.
  It has read-only permissions and does not open issues, edit code, advance the
  baseline, update Hermes, or restart Herm. Scheduled runs begin only after the
  workflow is merged into the default branch.

The shared Swift scanner fingerprints method parameters/results and their
transitive component schemas, including defaults, required fields, enum choices,
and closed object shapes. It ignores prose-only description/title/example edits.
It tracks both the regular and canonical method definitions. Changes/removals
are reported for declared Herm methods and all server requests/notifications;
additions anywhere are feature candidates. Failed or malformed fetches never
become a clean result. A workflow passing means the scan ran, not that the
reported work is resolved.

## Limits that require human review

HTTP endpoints, CLI commands, behavioral fixes behind unchanged schemas, plugin
semantics, release holds and undocumented payloads still require reviewing the
linked upstream comparison and running focused integration-contract tests. The
known backlog is always shown even when fingerprints have not changed. Removing
an item means a reviewer verified the fix, not merely that upstream changed.
A new API is a candidate, not a promise that Herm implements its UI.

The installed CLI shown in Settings may differ from a long-running gateway or a
remote backend. This tracker watches upstream development; runtime capability
probes remain the authority for enabling Herm controls.

## Local report

From the repository root:

```sh
swiftc Sources/Herm/HermesRuntime/HermesCompatibilityContract.swift \
  Scripts/hermes-compatibility/main.swift -o /tmp/hermes-compatibility
/tmp/hermes-compatibility Sources/Herm/Resources/HermesCompatibility.json --upstream main
```

For a deterministic offline run, replace `--upstream main` with an OpenRPC JSON
file path and its full 40-character commit SHA. The scanner and app share the
same parser and comparison. `HermesCompatibilityTests` covers transitive changes,
prose changes, recursive schemas, additions/removals, unavailable checks and stale
results.

## Reviewing the backlog and advancing the baseline

1. Inspect the linked upstream changes and affected Herm callers. Fix real
   integration gaps and add focused parser/state/adapter tests. Feature candidates
   can be deliberately deferred, with the reason recorded in review.
2. Update the known backlog with evidence; never remove unresolved items just to
   produce an empty report. Keep `trackedMethods` aligned with Herm’s feature IDs;
   the focused test checks declared transport coverage against the baseline.
3. Refresh signatures and the upstream SHA only after that review, using the
   scanner's explicit `--record-review` mode (see below). This retains the backlog.
4. Run the local report, focused tests, build and `make guard`. Review the baseline
   diff in the same PR as the required fixes. Automatic scans never advance it.

```sh
/tmp/hermes-compatibility Sources/Herm/Resources/HermesCompatibility.json \
  --upstream main --record-review > /tmp/HermesCompatibility-reviewed.json
# Inspect the proposed baseline, then copy it into Sources/Herm/Resources/ in the reviewed change.
```
