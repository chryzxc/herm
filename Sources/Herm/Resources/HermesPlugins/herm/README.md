# herm Hermes plugin

Serves what Herm publishes in `~/Library/Application Support/Herm/agent-surfaces.json`
(or `$HERM_AGENT_SURFACES`):

- **Rules** frozen into each new session's system prompt. When Herm settings change
  mid-session, `pre_llm_call` adds the updated rules to the next turn. While the plugin
  is enabled, Herm stops appending its rules to each message.
- **Guards** (`pre_tool_call`) that block a tool call, such as `open -a Chrome <url>`
  while Settings → Browser → Use Herm's browser is on. Guards are read live.
- **`herm_reference`** returns a surface's full reference.
- **`herm_inspector`** shows an inspector tab (files, changes, diff, terminal, browser,
  timeline, artifacts, github) beside the chat. Herm reads the tool's receipt.
- **MCP Apps** (`transform_tool_result`): while Generative UI is on, an MCP tool that
  declares a `ui://` view gets its view and call cached under `mcp-apps/` beside the
  manifest, plus a `herm_app` receipt in the result. See `docs/generative-ui.md`.

Herm also handles Hermes' built-in `focus_pane` (files, terminal, review) and
`desktop_preview` events without this plugin.

Herm installs this plugin automatically when it connects to Hermes Agent on the
same Mac, replacing it whenever the bundled `version` changes. Manual
installation for development:

```sh
mkdir -p ~/.hermes/plugins/herm
cp Sources/Herm/Resources/HermesPlugins/herm/plugin.yaml Sources/Herm/Resources/HermesPlugins/herm/__init__.py ~/.hermes/plugins/herm/
hermes plugins enable herm
python3 -B Sources/Herm/Resources/HermesPlugins/herm/test_plugin.py
```

Hooks apply immediately; tools load in new sessions.
