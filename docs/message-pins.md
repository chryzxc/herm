# Message pins

Herm's message pin action is backed by Hermes Agent. User and assistant messages
with a verified stored identity can be pinned. The conversation header's pin
button opens the list; select a preview to jump to that message, including older
history that has not been loaded yet.

Bubble actions refresh their session target when a conversation resumes under a
new runtime session ID, so retained messages can still be pinned after that change.
An accepted pin completes even if the transcript view is replaced; leaving the
conversation before the queued action starts cancels it.

Pins are bookmarks for navigation. They do not keep a message in model context
or protect it from deleting/rewinding its conversation. Context compression
preserves pins through Hermes' logical message UID. Explicit branches begin
with an independent pin list; profiles do not share pins.

## Keep a message visible while working

Use **Open message in new tab** in a completed message’s bubble actions to open a
closable reading tab in the third panel. This is independent of pins and works
without the backend patch. Open several messages for reference; selecting the
same message again returns to its existing tab. Reading copies stay scoped to
their conversation during the current app run and are not saved after quitting.

Hover a third-panel tab’s icon or name to expand the tab itself and reveal its
full name and close button. Compact background tabs collapse to icons when the
pointer leaves. Close has a separate, full-height click target. Labels collapse only
when the open tabs need more room, keeping the active name visible when possible.
The strip reveals the active tab when you switch tabs or resize. Drag a tab’s name
or icon onto another tab to change its position while the window stays still, or use **Move tab left/right** in its
context menu. Built-in tabs and previews can be mixed; each conversation keeps
its order for the current app run.


Inspector tab hover expansion uses a leading-aligned row without width animation. Drag previews carry the whole tab, including its icon, title, background, and close action.

## Bot and activity previews

Known bot mention pills open the bot's available profile data in the third panel.
Bot dispatch pills show the full task and reported reply. Click a tool row to
inspect its input, arguments, result, timing, and changes where Hermes reported
them. Existing thinking and diff disclosures keep their inline behavior. There
are no extra preview links or menu actions in the transcript. The preview icon
appears only in the whole message bubble's action row beside Copy and Reply.
These tabs use the same temporary, conversation-scoped behavior as message tabs.
When source data is no longer loaded, the preview labels its retained captured copy.

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
