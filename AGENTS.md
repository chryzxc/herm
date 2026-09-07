# Hermes Agent Dock contributor guidance

Read `DESIGN.md` before changing a user-facing view. It is the source of
truth for Dock UI behavior and styling.

## UI consistency

- Match the closest existing component before introducing a new visual
  treatment. Reuse shared `Dock*` components and color tokens.
- Use 16pt semibold only for page headers. Use 12pt semibold titles and 12pt
  detail text for compact empty states, matching existing repository and
  session empty-state components. Dense metadata may use 11pt where an
  adjacent established component already does.
- Do not add decorative dashboards, speculative controls, or placeholder
  content. Every control and status must reflect a real capability or state.
- Do not add passive lifecycle labels (for example, `IDLE` or `READY`) unless
  they change a user decision or accompany an actionable recovery path. Do
  not add controls, labels, or secondary functions merely to fill space.
- An interactive surface must make its primary interaction work immediately.
  For example, a terminal must open in a valid directory and accept typed
  commands; it must not render a disabled shell or explanatory chrome instead.

## Layout stability

- Do not insert or remove transient loading, retry, or projection rows above a
  page header or primary content. Put short status in an existing fixed slot
  (such as a header subtitle or control spinner) so refreshes do not make the
  page jump.
- Keep loading, empty, unavailable, and loaded states within the same stable
  container and maintain the surrounding layout whenever practical.
