# 0001: Herm hosts Hermes Desktop plugin pages on Desktop's own SDK

Status: accepted, 2026-11-16

## Context

Hermes Desktop plugins live in `<HERMES_HOME>/desktop-plugins/<id>/plugin.js`. They are ES modules that
import `@hermes/plugin-sdk` and React from the Desktop host and register contributions. Full pages are
registered with `ROUTES_AREA`. Users install some, such as `hermes-whiteboard`, mainly for the page.
Herm is a native client, so it can't load Desktop's renderer. It also must not change Hermes.

A unified package installed with `hermes plugins install` keeps its desktop half in
`plugins/<name>/` (its root `plugin.js`, else `desktop/plugin.js`). Desktop copies that half into
`desktop-plugins/` when it starts. The Hermes route that does the copy is served only on the web app
surface, not on the gateway Herm uses. Herm therefore reads halves where they are installed, read-only,
in Hermes' order: `desktop-plugins/`, then the default home's `plugins/`, then each profile's. The first
folder with a given id wins.

## Decision

Herm runs a compatible plugin's page in a `WKWebView` against Hermes Desktop's real SDK, React,
provider tree and stylesheet, built from a Hermes checkout rather than re-implemented.

- **The host is built from Desktop's source.** `Scripts/build-desktop-plugin-host.sh` bundles
  `apps/desktop/src/sdk` with Desktop's own Vite, resolve aliases and vendor chunk groups (read live
  from its `vite.config.ts`), and compiles `styles.css` with Desktop's Tailwind. Herm adds only
  `herm/bridge.ts` and `herm/host.tsx`, which replace the seams where Desktop reaches its own window:
  the gateway client, toasts, chat opening and navigation. The output (`DesktopPluginHost/sdk/`, with
  `SOURCE` naming the commit and `LICENSE` collecting every bundled package's notice) is git-ignored;
  `make package` builds it when missing. Bun's own bundler was tried first and dropped declarations
  across split chunks, which WebKit refuses to link.
- **Compatibility is decided before anything runs.** An ES import of a name the host doesn't export
  fails the whole module at link time. `DesktopPluginCompatibility` therefore compares the plugin's
  named SDK imports with `Resources/DesktopPluginHost/sdk-exports.json`, which yields
  `runsInHerm`, `needs([names])`, `desktopOnly` (no `ROUTES_AREA`) or `unknown`. There is no allowlist.
- **One manifest is the source of truth.** The build writes `sdk-exports.json` from the built
  `sdk.js`'s actual exports, and `make plugin-host-contract` fails on any drift.
- **A page that cannot start says so.** Errors before the page reports ready (including a module that
  fails to link) post a failed status, and Herm fails a page that stays silent for 20 seconds.
- **Herm's bridge is a closed set of ops.** The page can only post the ops in `DesktopPluginOp`: RPC
  request, REST, open session, save panel, notify and status. Anything else gets an error reply.
- **Plugins are trusted like Desktop plugins.** The RPC `request` op forwards any Hermes method on
  Herm's connection, exactly as Desktop's `host.request` does. Installing a plugin trusts its code;
  the ops bound what the page can reach outside Hermes, not which Hermes methods it calls.
- **REST is confined.** Calls are limited to the plugin's own `/api/plugins/<id>` namespace on Herm's
  gateway, with `..` and encoded dots rejected on both sides.
- **The page has no network of its own.** Its CSP is `connect-src 'none'`, images and fonts load
  only from the page itself or `data:`/`blob:` URLs, and `script-src` allows only `'self'` plus the
  import map's hash.
- **Files come from a custom scheme.** `herm-plugin://<id>/` serves only the bundled host files and
  that plugin's folder, after standardizing paths and resolving symlinks. Each plugin gets its own
  origin, which keeps `ctx.storage` (localStorage) separate per plugin: the id itself when it is
  already a plain host name, otherwise a hex spelling of the id, so two ids never share one.
- **Installed means offered.** Desktop stores its plugin enablement in its window storage, which
  Herm can't read, and Herm adds no switch of its own: every installed plugin whose page runs in
  Herm appears in More destinations. Pins use `plugin:<id>` raw values and survive while the
  plugin is missing.

## Consequences

- Panes, themes, composer slots, settings pages and palette entries are ignored. Only routes render.
  A route to a Desktop page Herm lacks returns to the plugin's home with a notice.
- Requests go to Herm's current connection; `host.requestProfile` passes the profile through.
- `GatewayHTTP` wraps bare-array REST responses as `{ "items": [...] }`. Plugins that expect a raw
  array need their own handling.
- Herm themes the page only through the CSS variables Desktop's `applyTheme` paints (seeds, shadcn
  tokens, `--dt-font-sans`, `--radius-scalar`), never with selectors. A renamed variable stops
  applying instead of breaking layout.
- The page has no network, so web fonts and remote images a plugin requests are refused.
- The host is built, not checked in. Release builds rebuild it from the Hermes revision in
  `Scripts/desktop-plugin-host/HERMES_REVISION`; a build without it lists plugin pages as unavailable
  instead of offering pages that cannot load.
- The bundle is about 33 MB (Shiki grammars dominate and load only when code is highlighted).
- Supporting a newer SDK means rerunning the build against a newer Hermes checkout. Plugins that
  needed the new names move from `needs` to `runsInHerm` without further changes.
