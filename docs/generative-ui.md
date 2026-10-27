# Generative UI in Herm

Generative UI ships in normal builds. Settings → Appearance → Generative UI is on
by default and applies immediately. Turning it off preserves canonical messages and
shows readable fallbacks. HTML always needs an explicit Open action.


No build or launch environment variable is required.

## Card composition and motion

Use one compact interactive card for one result, with the main visual and its
selected detail kept together. The reference map adds another future card type:
selecting a place coordinates the marker, route, camera, and detail strip.
The PR reference uses the same principle for commits, checks, and merge state.

The visual thesis is a calm native surface, one clear focal point, and motion
that explains changing state. The content order is the working visual, one
compact selected detail, and an action only when Herm supports it. The motion
sequence is immediate selection feedback, a coordinated spatial transition,
and a short detail transition within an unchanged outer frame.

Follow the generated-card motion rules in `DESIGN.md`:

- Use the shared Herm easing curve; 160–220ms for controls/details and
  350–500ms for spatial transitions. Preserve selection and stable element IDs.
- Accept new input during motion; cancel or retarget obsolete transitions.
  Update authoritative state immediately, without waiting for an animation.
- Keep card dimensions and transcript scrolling stable. Do not replay the
  entrance on every token, animate fake progress, or add perpetual decoration.
- Honor Reduce Motion and motion-free themes, preserve keyboard focus, and
  review narrow/wide and themed states in a short recording before enabling.

The [map motion study](previews/generative-ui-map-motion.html) uses illustrative
places to review selection, route tracing, detail changes, rapid input, and
reduced motion. It is a standalone design fixture and is not loaded by Herm.
Actual map data, location access, place photography, routing, and device handoff
are not implemented. A future native map adapter must use supported sources
and existing destination/action validation; the offline HTML sandbox remains
offline.

The study was checked at 320px, 360px, and 768px in Light/Dark where applicable,
with keyboard selection, rapid changes during transitions, stable card bounds,
and Reduce Motion. These are browser prototype checks; native in-app motion,
Glass/monochrome appearance, and actual map integration still need acceptance.

## Isolation and maintenance

- `Sources/Herm/Features/GenerativeUI/` contains the implementation;
  `Tests/HermTests/Features/GenerativeUI/` contains its focused tests.
- `GenerativeUIIntegration.swift` is the host boundary. Rendering, prompt
  preparation, text projections, and view-lifetime hooks go through that API.
  Core conversation and tool records have no generated-content fields, and
  history parsing keeps Hermes records unchanged.
- Presentation scopes own unsent form values and preview lifetime. Existing
  destination-validated submission handlers remain authoritative. The feature
  adds no executor, event ingestion, tool interception, or transcript store.
- When disabled, future prompts omit rendering instructions and existing replies
  use readable text projections. Legacy rendering context stays hidden without
  rewriting canonical records. Active HTML previews close immediately.
- New workflow cards belong here, using read-only adapters over existing stores
  and existing action handlers. Keep provider-confirmed state separate from
  generated content; do not derive a merge result from an assistant claim.

Run `swift test` for ordinary regression, generated-content, and WebKit isolation
checks. `GenerativeUIIsolationTests` covers shipping availability, readable
fallbacks, canonical message preservation, and compatibility with old archives.
The focused suites cover validation, forms, and the offline HTML host.

## Response format

Only assistant conversation content recognizes a fenced `herm-ui` JSON object.
When enabled, Herm instructs Hermes to use visual replies whenever interaction or
structure helps; users do not need to mention “Herm UI” or HTML. A request such as
“Create a savings calculator with starting balance, monthly contribution, annual
interest rate, and years” requests a complete HTML surface with editable inputs and
an immediately recalculating result. Explicit requests for plain text, source code,
or project/file changes retain their requested deliverable.
Use ordinary Markdown whenever an interactive view adds no value. Rendering
context is appended only when the setting is enabled, to workspace,
quick-message, group and client-submitted voice requests through the existing
submission paths; it does not change the model or require an additional model
call. Runtime-owned voice turns remain compatible.

```herm-ui
{"version":1,"id":"checks","title":"Validation","fallback":"The build and tests passed.","kind":"native","blocks":[{"type":"table","columns":["Check","Result"],"rows":[["Build","Passed"],["Tests","Passed"]]}]}
```

Each surface requires version `1` or `2`, a unique short `id` within its reply, `title`,
`fallback`, and `kind`. Native surfaces require `blocks` and omit `html`.
Supported block fields:

| Type | Fields |
| --- | --- |
| text | `text` |
| table | `columns: [String]`, `rows: [[String]]` |
| sources | `items: [{title, url}]` with public HTTPS URLs |
| gallery | `items: [{title, url}]` with HTTPS links or inline PNG/JPEG/WebP data URLs |
| chart | `style: "bar"` or `"line"`, `points: [{label, value}]` |
| form | `fields: [{id, label, type, required?, options?}]`, optional `submitLabel` |

Table rows are arrays of string or number cells matching the columns. Numbers
become display text during decoding; the saved source remains unchanged. Objects,
arrays, booleans, and null cells are unsupported. Invalid visual replies show
“Visual reply unavailable” with their readable fallback and source disclosure.

Forms submit within canonical session conversations. Group replies can display
rich content; generated forms there retain their readable fallback.

Form types are `text`, `number`, `choice`, `multipleChoice`, and `boolean`.
Choice fields require unique string `options`. Submitting sends a user message
to the original profile/session; it does not execute a generated action. Never
request passwords, credentials, or approval decisions in these forms. Changes to
the source revision disable old forms. Unsent values survive view unmounting and
session navigation during the app lifetime; they are not a second transcript.

A surface is limited to 1 MiB, 100 blocks, and 1,000 rows/points per block.
Tables allow at most 20 columns, source/gallery lists 100 items, and forms 64
fields. Malformed, oversized, unsupported, duplicate-ID and incomplete content
uses readable fallback. During streaming, structured content stays pending until
the reply commits. Source inspection and source copying remain explicit.

```herm-ui
{"version":1,"id":"calculator","title":"Local calculator","fallback":"Enter a number to calculate its square.","kind":"html","html":"<label>Number <input id=\"n\" type=\"number\" value=\"4\" oninput=\"document.getElementById('answer').textContent=Number(this.value)**2\"></label><output id=\"answer\" aria-live=\"polite\">16</output>"}
```

HTML documents must inline CSS/JavaScript and resources. Prefer the injected
`--herm-background`, `--herm-surface`, `--herm-text`, `--herm-secondary`,
`--herm-accent`, and `--herm-border` CSS variables. A native explicit-open card
precedes execution. No persistent storage, external resources, network, files,
authentication, action bridge, tools, downloads, popups, or device access is
available. Closing or switching sessions destroys state; reopening reloads the
saved document. Changing the Herm theme also reloads an open preview to apply
the current palette. These restrictions combine the documented
[iframe sandbox](https://developer.mozilla.org/en-US/docs/Web/HTML/Reference/Elements/iframe#sandbox)
and [CSP](https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Content-Security-Policy)
with native WebKit navigation, resource and permission policies.

Generated replies are separate from operational activity. Chat retains its
existing loading animation, live tool steps and expandable completed summary.
PRs, routines, integrations, checkpoints and updates keep their established
native controls. Context and quota retain the existing monitoring views.
Herm adds bounded typed native graph/tree components, not an arbitrary layout language
or scriptable graph editor. A2UI/MCP Apps compatibility and connected HTML apps are not included.

## Expanded native formats and session Artifacts

The session Artifacts inspector tab uses the same disposable history index as the
global browser. Interactive replies join files, images, and links. Indexing validates
completed assistant surfaces without opening HTML. Saved tools store their original
profile/session/message/surface reference and source digest. A missing source remains
unavailable; Export creates an independent `.herm-ui.json` or self-contained HTML file.
Native inputs, sort/filter settings, selected items, tree expansion, and image controls
restore only for that source revision. HTML transfers one host between presentations;
it never persists DOM state. Close, session/profile changes, and disabling the setting
destroy the host. Theme changes and Reload restart its original document.

Use in current chat, Ask about selection, and Revise attach bounded untrusted context
to the existing composer. They preserve the draft and do not send automatically.
Forms remain restricted to the loaded original message in its owning conversation.
Revision links must resolve to an earlier exact source in the same profile/session.
The browser groups verified revisions and compares readable results through the shared
diff renderer. Reused titles or IDs do not establish lineage.

Version 2 retains the envelope and adds optional `datasets`, `metadata`, and
`revisionOf`. New blocks have `id`, `type`, and a typed `payload`. Existing legacy
blocks remain valid in version 2. Block IDs and dataset row/column IDs must be unique.
The original source is never rewritten.

```herm-ui
{"version":2,"id":"sales","title":"Fictional sales","fallback":"January had 12 fictional sales.","kind":"native","metadata":{"fictional":true},"datasets":[{"id":"sales-data","columns":[{"id":"month","title":"Month","type":"text"},{"id":"sales","title":"Sales","type":"number","unit":"units"}],"rows":[{"id":"jan","values":["January","12"]}]}],"blocks":[{"id":"table","type":"table","payload":{"dataset":"sales-data"}},{"id":"chart","type":"chart","payload":{"dataset":"sales-data","label":"month","series":["sales"],"style":"bar"}}]}
```

Dataset cells are strings, interpreted by typed text/number/ISO8601 date columns.
Tables preserve source order until sorted. Charts share dataset row selection and
support multiple numeric series. Crowded category charts scroll horizontally and
wrap labels in narrow layouts. Dataset cells, metric values, comparison values,
and tree values are strings. `metadata.assumptions` accepts a string or a list of
strings; list entries retain their order and render on separate lines. `source`
and `observedAt` are strings; `fictional` is a boolean. No field establishes verified
runtime status. Invalid field types identify their field path in the unavailable
reason. Original JSON, including assumption lists, remains unchanged in chat,
Artifacts, and explicit exports.

| Block | Payload |
| --- | --- |
| section | `title`, referenced block IDs in `blocks`, optional `paired`; no nested sections |
| metrics | `items: [{id,label,value,unit?,comparison?}]`; at most 20 |
| comparison | `criteria: [String]`, `options: [{id,title,values:[String],detail?}]` |
| checklist | `items: [{id,title,detail?}]`; local choices attached explicitly to chat |
| timeline | `items: [{id,title,detail?,date?,dependencies?:[id]}]` |
| graph | `nodes: [{id,title,detail?,status?}]` (workflow states), `edges: [{source,target,label?,style?}]` (`solid`/`dashed`); 200 nodes/500 edges |
| tree | `items: [{id,title,value?,parent?}]`; 1,000 items, no cycles |
| imageComparison | `before` and `after`, each `{title,url}` using inline PNG/JPEG/WebP data |
| record | `kind`, `id`; resolved by a registered current-workspace adapter |

All formats retain the 1 MiB surface limit and existing count limits. Missing fields,
unsupported types/versions, duplicate identities, cycles, and unresolved references
show an honest unavailable reason and readable fallback. Inspect the exact source
through the actions menu.

## Adding a feature without prompt drift

1. Implement its typed payload, validation, readable projection, and renderer.
2. Register its descriptor and a valid example in `RichFeatureRegistry`. The prompt
   catalog is generated from these descriptors; do not add another handwritten list.
3. Connected features register their current record IDs and resolver together through
   `RichHostActionRouter.Feature`. Use existing capability/permission authorities and
   action handlers. The catalog uses these same readers for each captured destination.
4. Add format, renderer, availability, and action-boundary contract tests. Unimplemented
   registrations are not advertised. Existing RPC names alone never establish support.

Registered connected navigation covers loaded PRs/issues, available Kanban tasks,
Calendar automation/task items, usage reports, and the current session Timeline.
Mac EventKit items remain local to Calendar. Missing CI reruns, network capture, and
deployment adapters use supplied snapshots or normal agent follow-ups instead.

`RichGenerationRecipes` contains natural-language acceptance prompts and fixtures for
calculations, scheduling, organization, learning, decisions, research/writing, data
inspection, developer exploration, UI review, and delivery workflows. These exercise
reusable native components and offline HTML, rather than installing separate apps.
Run the original Generative UI/HTML suites plus
`RichExpansionTests|RichLifecycleTests|RichTemplateContractTests|RichTemplateInteractionTests`.
The template suites cover every catalog entry, all twenty recipe families, documented
`herm-ui` examples, mixed dashboards, all form controls, and linked multi-series
charts. HTML examples execute in the real offline WebKit host to check input changes,
quiz scoring, and reset. Optional `HERM_TEMPLATE_REVIEW_DIR` writes native captures
at 320/640/1000pt and HTML snapshots without relaunching Herm.


### Task and development visual replies

Generated replies support native `code`, `findings`, and `workflow` blocks in version 2.
Code has a bounded, selectable monospaced viewport and an explicit Copy code action.
It displays commands without executing them. Findings show severity, detail, optional
location, and recommendation. Workflow steps show ordered proposed work or supplied
outcomes; every non-proposed status requires evidence and the view is labelled
Reported snapshot. Generated evidence remains an assistant claim, not live provider state.
Comparisons adapt to columns at wider sizes and visibly mark the selected option;
checklist details align beneath their labels. All use existing theme and action tokens.

The generation catalog guides planning, debugging, code review, CI-log review,
runbooks, configuration, onboarding, research, and budgeting toward appropriate
combinations of supported components. Simple answers still use Markdown.

| Block | Version-2 payload |
| --- | --- |
| code | `code`, optional `language`, `filename`; up to 64 KiB of code |
| findings | `items: [{id,title,severity,detail,location?,recommendation?}]`; severity `info`, `warning`, `critical`; up to 200 |
| workflow | `items: [{id,title,status,detail?,evidence?}]`; status `proposed`, `running`, `passed`, `failed`, `blocked`, `skipped`; up to 200; non-proposed states require nonblank evidence |

These formats participate in readable projections, exports, saved artifacts, and
registry-driven rendering tests. Filenames and finding locations are display text,
not filesystem access or executable actions.


## Runnable command cards

Version-2 `command` blocks render selectable shell text with Copy and Run in Terminal.
Use one block per step, in execution order. For example:

```herm-ui
{"version":2,"id":"drizzle-setup","title":"Drizzle setup","fallback":"Run bun run db:migrate, then bun run start after the migration succeeds.","kind":"native","blocks":[{"id":"migrate","type":"command","payload":{"command":"bun run db:migrate"}},{"id":"seed","type":"command","payload":{"command":"bun run start"}}]}
```

The card shows the local working directory before execution. Run uses this Mac's
session Terminal tab, with the selected worktree/project directory or Home when
unbound. The generated payload cannot override that directory. Each explicit Run
opens a fresh shell (reusing an unstarted initial shell), selects it and opens the
Terminal inspector. Existing jobs and partially typed input remain untouched.
Split shells remain alive; the new command is shown as a single focused pane.
Commands are not chained across cards: inspect the first result before running the next.

Run is available only while the original reply revision is loaded in its owning
profile/session and Generative UI is enabled. The action rechecks those conditions
and the captured directory at click time. Historical artifacts from other sessions
remain copyable; opening them never executes anything. Output, interruption and
shell lifetime belong to the existing Terminal workspace. A click is not a verified
success result, and it does not create verification evidence.

Commands are limited to 512 UTF-8 bytes and one line, without control or invisible
format characters. This stays below the initial PTY line buffer while its shell
starts. Longer scripts belong in copyable `code` blocks or project files.
Generated Run opens no additional shell once a group contains 16 shells; reaching
that limit or losing the directory
produces an in-card error. HTML remains offline without an execution bridge.
The generation recipes now include ordered database setup, dependency installation,
focused tests and development servers.
