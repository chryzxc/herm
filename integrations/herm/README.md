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

Herm also handles Hermes' built-in `focus_pane` (files, terminal, review) and
`desktop_preview` events without this plugin.

```sh
mkdir -p ~/.hermes/plugins/herm
cp integrations/herm/plugin.yaml integrations/herm/__init__.py ~/.hermes/plugins/herm/
hermes plugins enable herm
python3 -B integrations/herm/test_plugin.py
```

Hooks apply immediately; tools load in new sessions.
