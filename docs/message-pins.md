# Message pins

Herm's message pin action is backed by Hermes Agent. User and assistant messages
with a verified stored identity can be pinned. The conversation header's pin
button opens the list; select a preview to jump to that message, including older
history that has not been loaded yet.

Pins are bookmarks for navigation. They do not keep a message in model context
or protect it from deleting/rewinding its conversation. Context compression
preserves pins through Hermes' logical message UID. Explicit branches begin
with an independent pin list; profiles do not share pins.

## Backend installation

Stock Hermes Agent does not expose message pins. The companion patch is
[`patches/hermes-message-pins.patch`](../patches/hermes-message-pins.patch), based
on Hermes commit `1744a19e0df`. From the Hermes Agent checkout:

```sh
git apply --check /path/to/hermes-agent-dock/patches/hermes-message-pins.patch
git apply /path/to/hermes-agent-dock/patches/hermes-message-pins.patch
```

Restart the `hermes serve` process used by Herm after installing the patch.
Restarting while a turn is active interrupts that turn, so finish it first.
On its next normal writable store open, Hermes creates a `message_pins` table
without rewriting conversation text. No dependencies or config options change.

The patch is local and can need rebasing after `hermes update`. Herm disables
message pin actions if the endpoints are missing or their responses are invalid.
Hermes Desktop and the CLI are not given new message-pin UI by this patch; the
canonical storage and authenticated API are available for them to adopt.
Session exports currently do not include message pins.

## API

- `GET /api/sessions/{session_id}/message-pins?profile=…&limit=500&offset=0`
  returns `supported`, `requested_session_id`, canonical `session_id`, `profile`,
  `pins`, and `pagination`. Pins contain `row_id`, `message_uid`, `role`, a bounded
  `preview`, and `timestamp`.
- `PUT /api/sessions/{session_id}/message-pins/{row_id}?profile=…` with
  `{"pinned": true}` or `{"pinned": false}` confirms the requested pin state.

Both endpoints use Hermes' existing session token and profile routing. They
accept exact session IDs and reject foreign, hidden, or removed messages. Writes
are idempotent. Pin identity is scoped to the verified compression root and UID,
so compaction can replace physical SQLite row IDs without dropping bookmarks.
