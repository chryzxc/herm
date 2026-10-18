# Clickable action audit

Audit date: 2026-10-18.

The audit searched all Swift sources under `Sources/Herm` for button styles,
links, and tap gestures, then inspected shared styles and action labels across
conversation, session, repository, GitHub, automation, settings, provider,
extension, artifact, Office, calendar, and notch surfaces. This is a source
inspection plus focused rendering verification, not an end-to-end click-through
of every runtime-dependent screen.

## Findings and fixes

| Finding | Change |
| --- | --- |
| Unstyled actions inherited a brightness-only hover treatment. | Hosting roots now default to `.dockCompact`. Explicit row/icon styles continue to own their appearance. |
| Secondary buttons could lose their outline in Glass or open chrome; themes with zero outline width could erase the contour. | Secondary and compact buttons keep a themed outline at least one hairline wide in every skin. |
| Standalone actions looked like body text across settings, source control, automation, artifacts, memory editing, session tools, and notch previews. | Use the shared 26pt compact button treatment, including disabled and pending controls. |
| Show more, source-session navigation, release notes, and inline GitHub links depended on color or hover. | Use persistent underlines via `.dockLink`, including monochrome skins. |
| GitHub projects, milestones, and development links looked identical to static metadata. | Linked pills have underlined accent text and an external arrow or internal chevron. Static metadata keeps its ordinary text treatment. |
| Compact press controls had no surface before hover. | `.dockPress` now keeps a quiet control fill and hairline contour at rest. |
| Pinned-message, session-picker, and automation selection rows could look like static summaries. | Add a persistent trailing navigation chevron. Office status filters use compact button outlines. |

The shared styles retain semantic buttons/links, disabled state, existing action
handlers, and pending-state ownership. There are no new transport operations or
mutation flows.

## Ongoing rule

[DESIGN.md](../DESIGN.md) defines the component choices and
[AGENTS.md](../AGENTS.md#ui-consistency) repeats the requirement for contributors:

- Actions: `.dockCompact`, `.dockSecondary`, or the local `.dockPrimary`.
- Inline navigation and expansion: `.dockLink`.
- Linked metadata: `DockMetadataPill` with `navigationIcon`.
- Structured navigation, icon controls, tabs, and chevron disclosures may use
  `.dockHover` when their visible label already communicates interaction.
- Native menu items keep their menu presentation. Selectable text, static
  labels, statuses, and read-only metadata remain non-interactive.

Review the resting state first. Then check hover, keyboard focus, disabled and
pending states, and narrow layouts. Include Glass and monochrome appearances;
color alone cannot distinguish a link from ordinary prose.

## Verification

- The frozen workspace copy built successfully. Freezing the inputs avoided
  unrelated concurrent source edits invalidating compilation.
- All 60 focused checks passed across the preview harness, theme store,
  GitHub module, message pins, and workflow roadmap suites.
- A temporary native macOS preview harness rendered the shared controls in
  Clean, Glass, Swiss, E-Ink, and Terminal with light and dark appearances.
  The gallery covers static text, actions, links, linked/static metadata,
  disabled controls, Copy, and pending feedback. The harness is not retained
  in the app repository.
- `git diff --check` passed. Live screen-by-screen interaction, keyboard focus,
  and runtime-dependent narrow layouts still need manual QA.
