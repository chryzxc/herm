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

Each surface requires version `1`, a unique short `id` within its reply, `title`,
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
{"version":1,"id":"calculator","title":"Local calculator","fallback":"Enter a number to calculate its square.","kind":"html","html":"<label>Number <input id=\"n\" type=\"number\" value=\"4\"></label><button onclick=\"document.getElementById('answer').textContent=Number(document.getElementById('n').value)**2\">Calculate</button><output id=\"answer\"></output>"}
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
Herm does not add a general layout language, a graph editor, A2UI/MCP Apps
compatibility, or connected HTML apps.
