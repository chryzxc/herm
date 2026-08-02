# Hermes Agent Dock

A simple native macOS menu-bar companion for Hermes Agent. Click the menu-bar icon for status and quick actions, or open the chat window to talk to Hermes without using Terminal.

## Run locally

```sh
swift run
```

The app expects the `hermes` executable to be available on the user’s PATH. On launch it starts a loopback-only Hermes backend, connects over Hermes’s authenticated `/api/ws` WebSocket gateway, and speaks the TUI Gateway JSON-RPC protocol. It uses `session.create`, `prompt.submit`, `session.interrupt`, and `approval.respond`, streams assistant messages, and surfaces approval requests in the native UI.
