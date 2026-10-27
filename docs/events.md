# Events

Everything an app receives from the gateway, whether over the WebSocket, from the paged
`GET /v1/events` endpoint or in a webhook, is an **event** in the format defined here.

The format is the gateway's own. The gateway speaks to Telegram through **TDLib**, Telegram's
official client library, but TDLib's JSON never crosses the API, so a TDLib upgrade does not
change what an app receives.

In this document "you" are the developer of an **app**, a program that consumes the gateway.
**The user** is the person who runs the gateway and whose Telegram account it is signed in
to. Example accounts, handles, chat IDs, and message content are fictional.

How events are fetched is in [api.md](api.md#events). Which events an app may see is in
[grants.md](grants.md).

## Contents

- [Envelope](#envelope)
- [Event types](#event-types), with a full example of each
- [Chat summary](#chat-summary)
- [Message object](#message-object)
- [Sender](#sender)
- [Entities](#entities)
- [Forward origin](#forward-origin)
- [Media object](#media-object)
- [Not supported](#not-supported)
- [Versioning](#versioning)

---

## Envelope

```json
{
  "v": 1,
  "seq": 4810,
  "type": "message.new",
  "occurred_at": "2026-09-29T14:03:07Z",
  "recorded_at": "2026-09-29T14:03:07.412Z",
  "chat": { "id": "-1001234567890", "type": "channel", "title": "Acme Product Updates", "username": "acmeupdates" },
  "message": { … }
}
```

| Field | Type | Meaning |
|---|---|---|
| `v` | number | Format version. `1` throughout this document. See [Versioning](#versioning). |
| `seq` | number | **Sequence number**: the event's position in the gateway's log. Positive, strictly increasing, never reused. An app sees gaps, where events for chats outside its grant are skipped, but never a change of order. It is your cursor and your deduplication key. |
| `type` | string | One of the [event types](#event-types). Ignore types you do not know. |
| `occurred_at` | timestamp | When the thing happened. Telegram's own time where Telegram gives one (the message date, the edit date); otherwise the time the gateway learned of it. |
| `recorded_at` | timestamp | When the gateway appended the event to its log. `recorded_at - occurred_at` is the delivery lag. It can be hours after the Mac was asleep or offline, because the gateway fetches what it missed when it reconnects ([architecture.md](architecture.md#delivery-guarantees)). |
| `chat` | object | The chat the event belongs to, as a [chat summary](#chat-summary). Present on every event. In `chat.updated` it is the full chat object instead. |
| payload | | Further fields that depend on `type`, listed in the table below. |

Timestamps are RFC 3339 in UTC ([api.md](api.md#timestamps)). Ids are strings
([api.md](api.md#identifiers-are-strings)).

---

## Event types

| Type | Payload fields | Emitted when | Scope needed |
|---|---|---|---|
| `message.new` | `message` | A message arrives in a monitored chat, including messages the user sends themselves (`is_outgoing: true`), and for each message the gateway finds when catching up after being offline. | `messages:read` |
| `message.edited` | `message` | A message's text, caption or media is edited. The full message is sent, not a difference. | `messages:read` |
| `message.deleted` | `message_ids` | Messages are deleted for everyone. | `messages:read` |
| `chat.updated` | `chat` (full), `changes` | The chat's title, username, photo, member count or mute state changes. | `chats:read` |
| `chat.read` | `unread_count`, `unread_mention_count`, `last_read_inbox_message_id`, `last_read_outbox_message_id`, `is_marked_as_unread` | Read state changes, at most once per chat per second. | `chats:read` |
| `chat.position` | `is_pinned`, `order`, `is_archived` | Main-list order, pin or archive state changes. | `chats:read` |
| `message.reactions` | `message_id`, `reactions` | Message reactions change. | `messages:read` |
| `poll.updated` | `message_id`, `poll` | Poll votes or closure change. | `messages:read` |
| `monitoring.started` | `monitoring` | The chat enters the monitored set. | `chats:read` |
| `monitoring.stopped` | `monitoring` | The chat leaves the monitored set. | `chats:read` |

An app whose grant lacks `chats:read` never receives `chat.*` or `monitoring.*`. It can
still call `GET /v1/me` to read its `effective_chat_ids`.

### `message.new`

A text message in a group:

```json
{
  "v": 1,
  "seq": 4810,
  "type": "message.new",
  "occurred_at": "2026-09-29T14:03:07Z",
  "recorded_at": "2026-09-29T14:03:07.412Z",
  "chat": { "id": "-1001987654321", "type": "supergroup", "title": "Acme Support", "username": null },
  "message": {
    "id": "1523",
    "chat_id": "-1001987654321",
    "sender": { "type": "user", "id": "123456789", "display_name": "Grace Hopper", "username": "gracehopper", "is_bot": false },
    "date": "2026-09-29T14:03:07Z",
    "edit_date": null,
    "is_outgoing": false,
    "text": "@acmebot the export in v2.3 fails on large files, see https://acme.example.com/issues/812 #bug",
    "entities": [
      { "type": "mention", "offset": 0, "length": 8 },
      { "type": "url", "offset": 54, "length": 35 },
      { "type": "hashtag", "offset": 90, "length": 4 }
    ],
    "reply_to": { "chat_id": "-1001987654321", "message_id": "1519" },
    "forward_from": null,
    "media": [],
    "media_group_id": null,
    "link": null,
    "raw_content_type": "messageText"
  }
}
```

A channel post with a photo and a caption:

```json
{
  "v": 1,
  "seq": 4811,
  "type": "message.new",
  "occurred_at": "2026-09-29T14:03:20Z",
  "recorded_at": "2026-09-29T14:03:20.088Z",
  "chat": { "id": "-1001234567890", "type": "channel", "title": "Acme Product Updates", "username": "acmeupdates" },
  "message": {
    "id": "412",
    "chat_id": "-1001234567890",
    "sender": { "type": "chat", "id": "-1001234567890", "display_name": "Acme Product Updates", "username": "acmeupdates" },
    "date": "2026-09-29T14:03:20Z",
    "edit_date": null,
    "is_outgoing": false,
    "text": "v2.4 is out. Release notes: https://acme.example.com/releases/2.4",
    "entities": [ { "type": "url", "offset": 28, "length": 37 } ],
    "reply_to": null,
    "forward_from": null,
    "media": [
      {
        "media_id": "med_3fK9pQ2mR7tV1wX5yZ8aB4cD6eF0gH2j",
        "kind": "photo",
        "mime": "image/jpeg",
        "size": 184320,
        "width": 1280,
        "height": 720,
        "duration_seconds": null,
        "file_name": null
      }
    ],
    "media_group_id": null,
    "link": "https://t.me/acmeupdates/412",
    "raw_content_type": "messagePhoto"
  }
}
```

**Messages the user sends** arrive as `message.new` with `is_outgoing: true`, once, after
Telegram has confirmed them and given them their final id. This is the same whether the user
typed the message on their phone, sent it with `tgw send`, or an app sent it through
`POST /v1/chats/{chat_id}/messages` ([api.md](api.md#sending-messages)); the event does not
say which. A message that is still being sent, or that fails to send, produces no event.

### `message.edited`

The payload is the same as for `message.new`, with `edit_date` set; `occurred_at` equals it.

- Telegram does not say what changed. Compare with what you stored.
- There is one event per edit. Telegram announces an edit in two notifications; the gateway
  emits once per chat, message and `edit_date`.
- A content change that Telegram does not stamp with an edit date is not an edit and produces
  no event. Examples: votes on a poll, a link preview finishing loading.
- Edits of messages sent before the chat was monitored are delivered too. You may receive
  `message.edited` for an id you have never seen: treat it as an upsert.

```json
{
  "v": 1,
  "seq": 4812,
  "type": "message.edited",
  "occurred_at": "2026-09-29T14:05:02Z",
  "recorded_at": "2026-09-29T14:05:02.230Z",
  "chat": { "id": "-1001987654321", "type": "supergroup", "title": "Acme Support", "username": null },
  "message": {
    "id": "1523",
    "chat_id": "-1001987654321",
    "sender": { "type": "user", "id": "123456789", "display_name": "Grace Hopper", "username": "gracehopper", "is_bot": false },
    "date": "2026-09-29T14:03:07Z",
    "edit_date": "2026-09-29T14:05:02Z",
    "is_outgoing": false,
    "text": "@acmebot the export in v2.3 fails on files over 1 GB, see https://acme.example.com/issues/812 #bug",
    "entities": [
      { "type": "mention", "offset": 0, "length": 8 },
      { "type": "url", "offset": 58, "length": 35 },
      { "type": "hashtag", "offset": 94, "length": 4 }
    ],
    "reply_to": { "chat_id": "-1001987654321", "message_id": "1519" },
    "forward_from": null,
    "media": [],
    "media_group_id": null,
    "link": null,
    "raw_content_type": "messageText"
  }
}
```

### `message.deleted`

Telegram reports deletions in batches and without content, so the payload is a list of ids.
Only deletions for everyone are emitted: a message removed from the user's own view alone, or
dropped from TDLib's local cache, produces nothing (in TDLib's terms, the event requires
`is_permanent` and not `from_cache`). The ids may refer to messages your app never received.

```json
{
  "v": 1,
  "seq": 4813,
  "type": "message.deleted",
  "occurred_at": "2026-09-29T14:06:41.900Z",
  "recorded_at": "2026-09-29T14:06:41.903Z",
  "chat": { "id": "-1001987654321", "type": "supergroup", "title": "Acme Support", "username": null },
  "message_ids": ["1520", "1521"]
}
```

### `chat.updated`

`chat` is the full [chat object](api.md#the-chat-object) after the change. `changes` lists
which of `title`, `username`, `photo`, `member_count` and `is_muted` changed. Changes to the member count
alone are coalesced to at most one `chat.updated` per chat per `05:00`.

```json
{
  "v": 1,
  "seq": 4814,
  "type": "chat.updated",
  "occurred_at": "2026-09-29T14:10:00.512Z",
  "recorded_at": "2026-09-29T14:10:00.515Z",
  "chat": {
    "id": "-1001987654321",
    "type": "supergroup",
    "title": "Acme Support (official)",
    "username": null,
    "member_count": 12841,
    "is_monitored": true,
    "photo": { "media_id": "med_9aB2cD4eF6gH8jK0lM2nP4qR6sT8uV0w", "width": 640, "height": 640 }
  },
  "changes": ["title", "member_count"]
}
```

### `chat.read` and `chat.position`

Both carry the current [chat summary](#chat-summary). `chat.read` reports incoming read
progress (including reading on another device), outgoing read receipts, unread mentions,
and the manual unread flag. It observes state only; it never marks messages read.
The first change emits immediately; changes within the next second emit once at the end
of that interval with the latest state. A change undone during the interval emits nothing.

`chat.position` emits immediately for pin or archive changes. Pure order changes emit at
most once per chat per 10 seconds, with a trailing event carrying the latest order. Position
updates in folders do not affect these fields. Full position lists on last-message and draft
updates are also handled. Clients can use last-message time for provisional order between
events. Compare `order` numerically using a 64-bit integer or JavaScript `BigInt`, never
as a floating-point number or lexicographically. Higher orders appear first.

```json
{"v":1,"seq":4902,"type":"chat.read","occurred_at":"2026-10-27T14:00:00Z","recorded_at":"2026-10-27T14:00:00Z","chat":{"id":"-1001987654321","type":"supergroup","title":"Acme Support","username":null,"unread_count":2,"unread_mention_count":1,"last_read_inbox_message_id":"1523","last_read_outbox_message_id":"1520","is_marked_as_unread":false,"is_pinned":true,"order":"9221294780217032704","is_archived":false,"is_muted":false},"unread_count":2,"unread_mention_count":1,"last_read_inbox_message_id":"1523","last_read_outbox_message_id":"1520","is_marked_as_unread":false}
```

```json
{"v":1,"seq":4903,"type":"chat.position","occurred_at":"2026-10-27T14:00:01Z","recorded_at":"2026-10-27T14:00:01Z","chat":{"id":"-1001987654321","type":"supergroup","title":"Acme Support","username":null,"unread_count":2,"unread_mention_count":1,"last_read_inbox_message_id":"1523","last_read_outbox_message_id":"1520","is_marked_as_unread":false,"is_pinned":false,"order":"0","is_archived":true,"is_muted":false},"is_pinned":false,"order":"0","is_archived":true}
```

### `message.reactions` and `poll.updated`

Both carry a chat summary and a public `message_id`. Replace the message's entire
`reactions` array or `poll` object with the payload. An empty reactions array clears all
reactions. Repeated identical updates are suppressed while cached. View-count-only changes
are suppressed when the previous reactions are known. Poll content updates produce
`poll.updated`, rather than `message.edited`. Their timestamps are when the gateway
learned of the change; Telegram supplies no occurrence time for these updates.

The examples abbreviate the chat summary; its fields are the same as above.

```json
{"v":1,"seq":4904,"type":"message.reactions","occurred_at":"2026-10-27T14:00:02Z","recorded_at":"2026-10-27T14:00:02Z","chat":{"id":"-1001987654321","type":"supergroup","title":"Acme Support","username":null},"message_id":"1523","reactions":[{"emoji":"👍","custom_emoji_id":null,"count":3,"chosen":true}]}
```

```json
{"v":1,"seq":4905,"type":"poll.updated","occurred_at":"2026-10-27T14:00:03Z","recorded_at":"2026-10-27T14:00:03Z","chat":{"id":"-1001987654321","type":"supergroup","title":"Acme Support","username":null},"message_id":"1524","poll":{"question":"Ship Friday?","options":[{"text":"Yes","voter_count":3,"is_chosen":true},{"text":"No","voter_count":1,"is_chosen":false}],"total_voter_count":4,"is_closed":false,"is_anonymous":true,"type":"regular"}}
```

### `monitoring.started` and `monitoring.stopped`

Emitted when the user changes which chats the gateway monitors, or when the membership of a
monitored folder changes. An app receives them for the chats in its grant, so it learns when
its coverage of a chat starts and stops.

| `monitoring` field | Meaning |
|---|---|
| `source` | `"chat"`: the user monitors this chat individually. `"folder"`: the chat is monitored because it is in a monitored folder. |
| `folder_id`, `folder_title` | The folder, when `source` is `"folder"`; otherwise `null`. |

`occurred_at` is the moment of the change. After `monitoring.started`, messages from that
moment on arrive as `message.new`. Earlier ones are reachable only through
[history](api.md#history).

```json
{
  "v": 1,
  "seq": 4815,
  "type": "monitoring.started",
  "occurred_at": "2026-09-29T14:12:30.001Z",
  "recorded_at": "2026-09-29T14:12:30.004Z",
  "chat": { "id": "-1001555000111", "type": "channel", "title": "Industry News", "username": "industrynews" },
  "monitoring": { "source": "folder", "folder_id": "3", "folder_title": "Product" }
}
```

```json
{
  "v": 1,
  "seq": 4901,
  "type": "monitoring.stopped",
  "occurred_at": "2026-09-30T08:00:00.120Z",
  "recorded_at": "2026-09-30T08:00:00.121Z",
  "chat": { "id": "-1001987654321", "type": "supergroup", "title": "Acme Support", "username": null },
  "monitoring": { "source": "chat", "folder_id": null, "folder_title": null }
}
```

---

## Chat summary

The `chat` field on every event except `chat.updated` is a summary: enough to route and
label an event without a lookup.

```json
{ "id": "-1001234567890", "type": "channel", "title": "Acme Product Updates", "username": "acmeupdates" }
```

| Field | Meaning |
|---|---|
| `id` | The chat id, Telegram's number for the chat, as a string. |
| `type` | `private`, `basic_group`, `supergroup` or `channel`. A **supergroup** is a large group in which every member can post; a **channel** is a broadcast feed in which only admins post. All four are defined in [api.md](api.md#chat-ids). |
| `title` | The chat's name. |
| `username` | The public handle without `@`, or `null` when the chat has none. |
| `unread_count` | Integer count of unread incoming messages. |
| `unread_mention_count` | Integer count of unread mentions. |
| `last_read_inbox_message_id` | Public message id as a string, or `null` if no incoming message has been read. |
| `last_read_outbox_message_id` | Public message id as a string, or `null` if no outgoing message has been read by the recipient. |
| `is_marked_as_unread` | Boolean manual unread marker, independent of the counts. |
| `is_pinned` | Boolean; pinned in the main chat list. Archive and folder pins are not represented. |
| `order` | Main-list position as a decimal string; higher comes first, `"0"` means absent from the main list. |
| `is_archived` | Boolean; present in the archive list. |
| `is_muted` | Boolean; chat notifications muted, including inherited notification-scope settings. |

These new fields are `null` on older stored events where unknown. Current chat endpoints
use the latest state known from TDLib, even before a coalesced event is emitted.

The full chat object, with member count, photo and `is_monitored`, is in `chat.updated` and
at `GET /v1/chats` ([api.md](api.md#the-chat-object)).

---

## Message object

The same object appears in `message.new`, in `message.edited`, and in the response of
`GET /v1/chats/{chat_id}/messages`.

| Field | Type | Meaning |
|---|---|---|
| `id` | string | The message id, unique within its chat ([api.md](api.md#message-ids)). It increases with time within a chat but is not contiguous. |
| `chat_id` | string | The chat's id, repeated from the envelope so that the object stands alone in history responses. |
| `sender` | object | Who sent it. See [Sender](#sender). |
| `date` | timestamp | When it was sent: Telegram's server time, in whole seconds. |
| `edit_date` | timestamp or null | When it was last edited. |
| `is_outgoing` | boolean | `true` when the user's own account sent it. |
| `text` | string | The message text, or the caption of a media message; `""` when there is neither. The characters are plain text; formatting is represented by `entities`. Common service messages have a short English description. |
| `entities` | array | Spans of `text` with a meaning. See [Entities](#entities). Empty when there are none. |
| `reply_to` | object or null | `{ "chat_id", "message_id" }` of the message this one replies to. It is usually in the same chat, but a reply can point into another chat (a channel's linked discussion group), hence `chat_id`. The replied-to message is not included; fetch it through history if you need it. |
| `forward_from` | object or null | Where a forwarded message came from. See [Forward origin](#forward-origin). |
| `media` | array | Zero or one [media object](#media-object). Telegram allows one file per message; an album is several messages that share a `media_group_id`. The field is an array so that more can be carried later without a breaking change. |
| `media_group_id` | string or null | Set when the message is part of an album. All messages of the album share the value and arrive as separate `message.new` events. |
| `link` | string or null | `https://t.me/<username>/<id>` when the chat has a public username, otherwise `null`. |
| `reactions` | array or null | `{emoji, custom_emoji_id, count, chosen}` entries. One identifier is non-null for emoji/custom emoji; both are null for a paid Star reaction. Custom ids are decimal strings. `chosen` means this account reacted. Empty if none; `null` on older events. |
| `topic_id` | string or null | Forum topic id from the pinned TDLib schema’s `messageTopicForum.forum_topic_id`; not a discussion-thread id and not shifted like a message id. `null` outside forum topics. |
| `poll` | object or null | `{question, options: [{text, voter_count, is_chosen}], total_voter_count, is_closed, is_anonymous, type}`. Question and option text are strings, counts integers, flags booleans, and type is `regular` or `quiz`. `null` for non-polls and older events. |
| `raw_content_type` | string | The name of TDLib's content type for the message: `messageText`, `messagePhoto`, `messagePoll`, `messagePinMessage` and so on, or `"unknown"` if TDLib supplied none. **This field is not stable.** It tells you what kind of message you are looking at when the gateway does not model its content. Its values follow TDLib and can change when the gateway moves to a newer TDLib. Use it for logging and counting, not for logic. |

Messages whose content the gateway does not model (locations, contacts and uncommon service
messages) still produce a `message.new`. Common joins, leaves, title/photo changes, pins,
forum creation and calls get English text; polls carry their content in `poll`. `text` is `""`, or
the caption if there is one; `media` is empty, or holds the sticker or file; and
`raw_content_type` names the kind. The gateway never drops a message from a monitored chat.

---

## Sender

```json
{ "type": "user", "id": "123456789", "display_name": "Grace Hopper", "username": "gracehopper", "is_bot": false }
```

```json
{ "type": "chat", "id": "-1001234567890", "display_name": "Acme Product Updates", "username": "acmeupdates" }
```

| Field | Meaning |
|---|---|
| `type` | `user`: a person or a bot. `chat`: a channel posting under its own name, or a group admin posting anonymously, which Telegram attributes to the group itself. |
| `id` | The user id (positive) or the chat id. |
| `display_name` | The user's first and last name joined with a space, or the chat's title. Never empty: a user whom Telegram no longer resolves is `"Deleted Account"`, with `is_bot: false`. |
| `username` | The public handle without `@`, or `null`. |
| `is_bot` | Present only when `type` is `user`. |

---

## Entities

An **entity** is a span of `text` that has a meaning. Telegram defines many kinds; the
gateway keeps the ones an app is likely to act on:

| `type` | The span is | Extra field |
|---|---|---|
| `mention` | `@username` | |
| `text_mention` | The name of a user who has no username | `user_id` |
| `hashtag` | `#tag` | |
| `cashtag` | `$TICKER` | |
| `url` | A URL written out in the text | |
| `text_link` | Text that links elsewhere; the URL is not in the text | `url` |
| `bot_command` | `/command` | |
| `email` | An e-mail address | |
| `bold`, `italic`, `underline`, `strikethrough`, `spoiler`, `code` | Formatting | |
| `pre` | Preformatted code block | `language` (string or null) |
| `blockquote` | Quote, including expandable quotes | |
| `custom_emoji` | Custom emoji | `custom_emoji_id` (decimal string) |

Linked text continues to use `text_link` with `url`, the existing version-1 spelling,
rather than renaming it to `text_url` and breaking existing consumers.

Each entity has an `offset` and a `length`. Entities are sorted by `offset`, longest first
at the same offset. Formatting spans can overlap or nest; do not assume disjoint spans.

**Offsets and lengths are in UTF-16 code units.** That is how Telegram defines them, and it
is how JavaScript strings count, so `text.slice(offset, offset + length)` is correct in
JavaScript. In languages that count code points, convert first: an emoji before an entity
moves its offset by 2, not 1. In Python:

```python
def entity_text(text: str, offset: int, length: int) -> str:
    utf16 = text.encode("utf-16-le")
    return utf16[offset * 2 : (offset + length) * 2].decode("utf-16-le")
```

---

## Forward origin

```json
{ "type": "chat", "id": "-1001555000111", "display_name": "Industry News", "username": "industrynews", "message_id": "88", "date": "2026-09-28T19:20:00Z" }
```

| `type` | Forwarded from | Fields set |
|---|---|---|
| `user` | A user | `id`, `display_name`, `username`, `date` |
| `chat` | A post in a channel or group | `id`, `display_name`, `username`, `message_id` (in the origin chat), `date` |
| `hidden_user` | A user who hides their account on forwarded messages | `display_name` (the name shown), `date` |

`date` is when the original was sent. `id`, `username` and `message_id` are `null` where they
do not apply.

---

## Media object

```json
{
  "media_id": "med_3fK9pQ2mR7tV1wX5yZ8aB4cD6eF0gH2j",
  "kind": "video",
  "mime": "video/mp4",
  "size": 20971520,
  "width": 1920,
  "height": 1080,
  "duration_seconds": 42,
  "file_name": "demo.mp4"
}
```

| Field | Type | Meaning |
|---|---|---|
| `media_id` | string | Opaque, and stable per Telegram file. Fetch the bytes at `GET /v1/media/{media_id}` with the `media:read` scope ([api.md](api.md#media)). |
| `kind` | string | One of the kinds below. Tolerate kinds you do not know. |
| `mime` | string or null | The MIME type, when Telegram reports one. |
| `size` | number or null | Size in bytes. `null` until Telegram reports it. For some videos Telegram reports only an expected size, and that is what is given. |
| `width`, `height` | number or null | Pixels, for photos, videos, stickers, animations and video notes; otherwise `null`. |
| `duration_seconds` | number or null | Whole seconds, for video, audio, voice, video notes and animations. |
| `file_name` | string or null | The original file name of a document, audio file or video, when the sender's Telegram app supplied one. |

| `kind` | What it is | Notes |
|---|---|---|
| `photo` | A photo | The largest size Telegram offers, which is the size served. `mime` is `image/jpeg`. |
| `video` | A video | |
| `document` | A file of any type | |
| `audio` | A music or audio file | |
| `voice` | A voice note | |
| `video_note` | A round video message | `width` and `height` are both the side length. `mime` is `video/mp4`. |
| `sticker` | A sticker | `mime` follows the sticker's format: `image/webp`, `application/x-tgsticker` or `video/webm`. |
| `animation` | A silent looping clip (GIF-like) | |

The caption of a media message is the message's `text`, not a field of the media object, so
the same text-handling code serves every message.

A chat's `photo`, in the [chat object](api.md#the-chat-object), is a reduced media object:
`{ "media_id", "width", "height" }`. It is always a JPEG at Telegram's "big" size, reported as
640×640 because Telegram does not supply the dimensions of chat photos.

---

## Not supported

Format version 1 does not carry the following.

| Not included | Detail |
|---|---|
| View counts | Channel view counters. |
| Scheduled messages and per-message pinned flags | Chat main-list pins are supported. |
| Comment threads | Nothing beyond `reply_to`. |
| Locations, contacts and service messages as structured data | Common service messages have English `text`; other unmodelled content has empty text. All retain `raw_content_type`. |
| The user's account | Nothing about it beyond `is_outgoing`. |
| Secret chats and unmonitored chats | Secret chats are excluded. App delivery remains restricted to monitored, granted chats; ordinary private chats can be monitored. |

Any of these can be added later as an additive change, described next.

---

## Versioning

The mirror additions keep version 1: chat read/position/mute fields (plus the manual unread
marker), `chat.read`, `chat.position`, `message.reactions`, `poll.updated`, message reactions,
forum topic ids, poll objects, formatting entity types and English service-message text.
Older stored events decode without these fields and render unknown additions as `null`.
The existing `text_link` spelling and UTF-16 offsets remain unchanged.

Every event and every webhook body carries `"v": 1`. The API path (`/v1/…`) and the event
format version move together.

**Additive changes** keep `v: 1` and can appear at any time without notice:

- new fields on any object, `null` for older events where the value is unknown
- new event types
- new values of `entities[].type`, `media[].kind`, `forward_from.type` and `sender.type`
- new values of `raw_content_type`, which follow TDLib and are not part of the contract

An app must therefore ignore unknown fields, ignore unknown event types, and treat every
enumeration as open: a `switch` with a default branch that logs and continues.

**Breaking changes** bump `v` to `2` and are served only under `/v2/…`. Breaking means
removing or renaming a field, changing a field's type, changing the meaning of `seq` or
`since`, or changing the unit of entity offsets. `/v1/…` keeps serving `v: 1` events,
including events recorded after version 2 exists, for as long as version 1 is supported. A
deprecation is announced in this file with a date at least 90 days ahead. Events recorded
under version 1 stay readable under version 2, because the gateway renders events from
stored data rather than from stored JSON.

## Events from the gateway's own actions

When an app or the owner acts through the gateway ([api.md](api.md#message-and-chat-actions)),
no new kind of event appears and the action's response adds nothing to the log. The change
comes back from Telegram like a change made on the user's phone, and becomes the ordinary
event, once: `message.new` for a sent or forwarded message (after Telegram confirms it),
`message.edited`, `message.deleted`, `message.reactions`, `poll.updated`, and
`chat.position` or `chat.updated` for pinning, archiving and muting. Telegram sometimes
reports a deletion twice; the gateway records it once.

The [entities](#entities) in this document are also what an app sends to format text, with
the same UTF-16 offsets. `pre` may carry a `language`, as a string or `null`.
