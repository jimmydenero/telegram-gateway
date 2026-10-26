# API

The gateway serves an HTTP and WebSocket API on the loopback interface of the Mac it runs on:

```
http://127.0.0.1:41414
```

This document specifies that API. It is written for the developer of an **app**: a program
that reads Telegram messages through the gateway and, if the user allows it, sends messages
as the user. **The user** is the person
who runs the gateway: the Telegram account it is signed in to is theirs, and they choose what
each app may read. Example identities, credentials, and request IDs are fictional.

Related documents: the event objects the API carries are defined in [events.md](events.md);
the access model (what an app can and cannot see) in [grants.md](grants.md); a step-by-step
guide to building an app in [integrating.md](integrating.md); how the gateway is built in
[architecture.md](architecture.md).

Durations are written `mm:ss` (or `h:mm:ss` past an hour); values under a minute are written
in seconds, for example `10s`.

## Contents

- [Conventions](#conventions)
- [Authentication](#authentication)
- [Errors](#errors)
- [Access requests](#access-requests): how an app obtains a token
- [Grants](#grants): the grant object, `/v1/me`, webhook management
- [Chats](#chats): chats, folders, the monitored set
- [Events](#events): paged backlog and WebSocket stream
- [History](#history)
- [Sending messages](#sending-messages)
- [Media](#media)
- [Webhooks](#webhooks)
- [Health](#health)
- [Admin: login](#admin-login)
- [Admin: reload](#admin-reload)
- [Admin: links to Volgenic](#admin-links-to-volgenic)
- [Admin: pruning](#admin-pruning)
- [Rate limits](#rate-limits)
- [Not supported](#not-supported)
- [Endpoint index](#endpoint-index)

Endpoints under `/v1/admin/` are used by the gateway's own menu bar app and its `tgw`
command-line tool on the user's behalf. An app never calls them; they are specified here
because they are part of the same API.

---

## Conventions

### Port and configuration

The default port is **41414**. It is set in the gateway's configuration file:

```
~/Library/Application Support/TelegramGateway/config.json
```

```json
{
  "port": 41414,
  "events_retention_days": null,
  "media_cache_max_bytes": 2147483648,
  "secrets": "file",
  "api_id": 12345,
  "api_hash": "0123abcd…",
  "daemon_path": "/Applications/Telegram Gateway.app/Contents/MacOS/GatewayDaemon",
  "links": [{ "base_url": "https://volgenic.com" }]
}
```

| Key | Meaning |
|---|---|
| `port` | The TCP port the API listens on. |
| `events_retention_days` | How long events are kept. `null` keeps them forever. See [Retention](#retention). |
| `media_cache_max_bytes` | Size limit of the media cache. See [Cache](#cache). |
| `secrets` | Where the admin token and the key of TDLib's database are kept: `"file"` (default: `secrets.json` next to `config.json`, mode 0600) or `"keychain"` (the macOS login Keychain, for a signed build of the menu bar app). See [development.md](development.md#secrets). |
| `api_id`, `api_hash` | The gateway's identity with Telegram, which the user registers once at https://my.telegram.org. |
| `daemon_path` | Written by the menu bar app for its own launcher. The gateway ignores it. |
| `links` | The Volgenic servers the gateway links to ([link.md](link.md)), written by `tgw link add` and `tgw link remove`. Each link's token is in the secret store, not here. |

Unknown keys are ignored, so tools may add their own. Changes to `api_id`, `api_hash` and
`links` take effect on `POST /v1/admin/reload` ([Admin: reload](#admin-reload)); changes to
the other keys take effect when the gateway restarts.

**TDLib** is Telegram's official client library; the gateway embeds it to speak to Telegram.
It appears in this document only where its behaviour shows through.

The environment variable `TGW_PORT` overrides `port` for the process it is set on, which is
how a second gateway is run during development. `TGW_HOME` overrides the data directory
(default `~/Library/Application Support/TelegramGateway`). The `tgw` command-line tool and the
menu bar app read the same file, so they always find the gateway.

The gateway binds `127.0.0.1` only, never `0.0.0.0`. There is no TLS, because nothing leaves
the machine except webhooks and the outbound links to Volgenic ([link.md](link.md)), which
the gateway dials itself.

### JSON

- Requests and responses are `application/json; charset=utf-8`. Send `Content-Type` on every
  request that has a body.
- **Ignore fields you do not know.** The gateway adds fields without notice
  (see [Versioning](events.md#versioning)).
- Absent optional values are `null`, never omitted, so a field's presence is stable.
- Every response carries `X-TGW-Request-Id`. Quote it when reporting a problem.

### Identifiers are strings

Every identifier that originates in Telegram (chat id, message id, user id, folder id) is
encoded as a **JSON string**, for example `"chat_id": "-1001234567890"`. Telegram defines
these as 64-bit signed integers, and JavaScript, like any JSON parser that maps numbers to
IEEE doubles, silently loses precision above 2^53. Strings remove the hazard. Compare ids as
strings; never parse them or do arithmetic on them.

The gateway's own counters (`seq`, `limit`, sizes, counts) are JSON numbers. They are small,
and arithmetic on them is expected (`seq + 1`).

The gateway's own opaque identifiers are strings with a prefix that names their kind:
`req_…` (access request), `grant_…` (grant), `dlv_…` (webhook delivery), `med_…` (media).

### Chat ids

A **chat** is anything in Telegram that has a message timeline: a private conversation with
one person, a group, or a channel. A **chat id** is Telegram's number for it. Its sign and
magnitude encode the kind:

| Chat type (`type` field) | What it is | Chat id looks like |
|---|---|---|
| `private` | One-to-one chat with a person or a bot | positive: `"123456789"` (equals that user's id) |
| `basic_group` | Small group (up to 200 members, an older kind) | negative: `"-987654321"` |
| `supergroup` | Large group where every member can post | `"-100…"`: `"-1001987654321"` |
| `channel` | Broadcast channel: only admins post, everyone else reads | `"-100…"`: `"-1001234567890"` |

Telegram treats supergroups and channels as one kind internally and distinguishes them with
a flag. The gateway exposes them as two `type` values because the difference matters to an
app: a channel has no conversation, a supergroup does.

**Secret chats** (end-to-end encrypted private chats) cannot be monitored and never appear in
this API.

### Message ids

A **message id** identifies a message within its chat. It is not globally unique: message
`"1523"` exists in many chats. The gateway uses Telegram's public message id, the number that
appears in `https://t.me/<username>/<message id>` links and in Telegram's Bot API. (TDLib's
own message id is this number shifted left by 20 bits. The gateway converts at its boundary
and never exposes that form.)

### Timestamps

RFC 3339 in UTC with a `Z` suffix: `"2026-09-29T14:03:07Z"`. Values that originate in
Telegram have whole-second precision. Values the gateway generates may carry up to three
fractional digits: `"2026-09-29T14:03:07.412Z"`. Accept both.

### Pagination

List endpoints take `limit` (a number, capped per endpoint) and return `has_more` (boolean)
plus a cursor field named for the endpoint: `next_since` for events, `next_before` for
history, `next_cursor` for the admin chat list. When `has_more` is false the cursor field is
still present and still valid: it is where a later call continues from.

### CORS

None. The API is for local processes, not web pages. The gateway sends no CORS headers and
answers preflight requests with `404`.

---

## Authentication

Every endpoint except `GET /v1/health`, `POST /v1/access-requests` and
`GET /v1/access-requests/{id}` requires:

```
Authorization: Bearer tgw_Kq8sT2xvY9bLm4nR7wZ1aC3dE5fG6hJ0iU2oP4rS8tV
```

A **token** is `tgw_` followed by 43 characters of base64url (32 random bytes from the
system's cryptographic random generator). The gateway keeps only the SHA-256 hash of each
token, with one exception: an app token is held in plain form inside its access request for
the `10:00` hand-out window after approval, and erased with the request. A lost token cannot
be recovered, only replaced.

There are two kinds of token. They look identical; the gateway tells them apart by lookup.

| Kind | Who holds it | Can call | How it is issued |
|---|---|---|---|
| **App token** | One app | Non-admin endpoints, limited by the app's grant (its scopes and chats) | Issued when the user approves an [access request](#access-requests). One per grant. |
| **Admin token** | The menu bar app and the `tgw` command-line tool | Everything, including `/v1/admin/*` | Generated by the gateway on first start and kept in its secret store: `~/Library/Application Support/TelegramGateway/secrets.json` (key `admin-token`, base64 of the UTF-8 token) by default, or the login Keychain (service `TelegramGateway`, account `admin-token`) when `config.json` has `"secrets": "keychain"`. There is exactly one. `tgw secrets regenerate-admin-token` replaces it; the old one stops working when the gateway next restarts. |

The admin token on a non-admin endpoint (for example `GET /v1/chats`) sees everything the
gateway holds, as if it had every scope over every monitored chat. That includes sending: the
`tgw send` command sends the user's own messages with it
([Sending messages](#sending-messages)). `GET /v1/me` with the
admin token returns a synthetic grant with `"id": "grant_admin"`. The admin token has no
webhook.

### Authentication errors

| HTTP | `error.code` | When |
|---|---|---|
| 401 | `missing_token` | No `Authorization` header, or not `Bearer`. |
| 401 | `invalid_token` | Malformed, or not a token the gateway issued. |
| 401 | `token_revoked` | The grant behind this token was revoked. The body carries `details.revoked_at`. |
| 403 | `admin_only` | App token on an `/v1/admin/*` endpoint. |
| 403 | `insufficient_scope` | The grant lacks the scope. `details.required` names it (`"history:read"`). |
| 403 | `chat_not_granted` | The chat is outside the grant, is no longer monitored, or does not exist. The three cases are deliberately indistinguishable to an app token, so a token cannot discover chats it may not see. |

Example:

```json
{
  "error": {
    "code": "insufficient_scope",
    "message": "This endpoint requires the history:read scope.",
    "details": { "required": "history:read", "granted": ["messages:read", "chats:read"] }
  }
}
```

The WebSocket endpoint reports authentication failures differently, because a refused
upgrade cannot carry a JSON body: see [Close codes](#close-codes).

---

## Errors

Every non-2xx response has this body:

```json
{
  "error": {
    "code": "rate_limited",
    "message": "Human-readable explanation, safe to log.",
    "details": {}
  }
}
```

`code` is stable: branch on it. `message` is free text. `details` is an object, possibly
empty, whose keys are listed per code below.

| HTTP | `error.code` | Meaning | `details` |
|---|---|---|---|
| 400 | `invalid_request` | Body or query fails validation. | `field`, `reason` |
| 400 | `scope_not_requested` | An approval tries to grant a scope the app did not ask for. | `scope` |
| 400 | `chat_not_monitored` | An approval names a chat that is not monitored. | `chat_id` |
| 400 | `folder_not_monitored` | An approval names a folder that is not monitored. | `folder_id` |
| 400 | `chat_not_monitorable` | An attempt to monitor a secret chat or an unknown chat. | `chat_id` |
| 401 | see [Authentication errors](#authentication-errors) | | |
| 403 | see [Authentication errors](#authentication-errors) | | |
| 404 | `not_found` | Unknown route or id, or an access request that has been purged. | |
| 404 | `webhook_not_configured` | `GET /v1/me/webhook` on a grant with no webhook. | |
| 409 | `webhook_not_configured` | Any other webhook operation on a grant with no webhook. The admin token has no webhook, so `PUT /v1/me/webhook` with it answers this too. | |
| 409 | `already_resolved` | Approve or deny on a request that is no longer pending. | `status` |
| 409 | `webhook_not_paused` | Resume on a webhook that is not paused. | `state` |
| 409 | `cursor_behind` | A prune would delete events a webhook has not delivered yet ([Admin: pruning](#admin-pruning)). | `grant_id` |
| 409 | `reload_in_progress` | A reload was requested while another one is still running ([Admin: reload](#admin-reload)). | |
| 410 | `history_pruned` | `since` points below the oldest retained event ([Retention](#retention)). | `oldest_seq` |
| 410 | `media_gone` | Telegram can no longer supply the file (the message was deleted, or Telegram expired the file). | `media_id` |
| 413 | `payload_too_large` | Request body over 64 KiB. | |
| 429 | `rate_limited` | See [Rate limits](#rate-limits). The `Retry-After` header is set, in seconds. | `retry_after` |
| 500 | `internal` | A bug in the gateway. Report it with the `X-TGW-Request-Id`. | |
| 502 | `send_failed` | Telegram refused to send a message ([Sending messages](#sending-messages)). | `reason`, `telegram_code` |
| 503 | `not_logged_in` | The gateway has no Telegram session: the user has not signed in. | `auth_state` |
| 503 | `telegram_unavailable` | The endpoint needs a live connection to Telegram (history, sending, media, folders) and the connection is down. Endpoints served from the gateway's own store (events, chats, grants) keep working. | `connection_state` |
| 504 | `send_timeout` | Telegram did not confirm a message within `30s`. It may still be sent ([Sending messages](#sending-messages)). | `chat_id` |

One more code, `slow_consumer`, appears only in a WebSocket error frame
([Close codes](#close-codes)).

---

## Access requests

An app obtains a token through a device-code style flow: the app asks, the user approves in
the gateway's menu bar app, and the app, polling, receives the token. There is no browser
and no redirect, and the app never sees the user's Telegram credentials.

![The app posts an access request and receives a request id and poll URL. The gateway shows the request to the user in the menu bar app. The app polls every 3s and sees pending until the user approves, choosing chats and scopes; the next poll returns approved with the token and grant.](images/access-request.png)

### `POST /v1/access-requests`

Unauthenticated. Creates a pending request. The `request_id` is a 32-byte random value and is
the only credential needed to poll, so treat it as a secret until the flow completes.

Request:

```json
{
  "name": "Community Analytics",
  "description": "Classifies messages in product channels and counts topics per day.",
  "scopes": ["messages:read", "history:read", "chats:read"],
  "requested_chats": ["-1001234567890", "-1001987654321"],
  "webhook": { "url": "https://analytics.example.com/tgw/events" }
}
```

| Field | Required | Rules |
|---|---|---|
| `name` | yes | 1–64 characters. Shown to the user. |
| `description` | yes | 1–280 characters. Shown to the user: say what the app does with the messages. |
| `scopes` | yes | Non-empty array of scope names from [grants.md](grants.md#scopes). Ask for `messages:send` only if the app sends messages: the user sees that the app may send messages as them. |
| `requested_chats` | no | An array of chat ids, or the string `"any"`. Default `"any"`. This is a suggestion: the user chooses the actual set. Requested chats that are not monitored are shown as such, and the user can start monitoring them as part of approving. |
| `webhook` | no | `{ "url": "https://…" }`. `https` is required unless the host is `127.0.0.1`, `localhost` or `::1`. Omit it to use the WebSocket only; a webhook can be added later with `PUT /v1/me/webhook`. |

Response `201 Created`:

```json
{
  "request_id": "req_7Hs2kQm9vL4pX1nB8cR3tY6wZ0aD5eF2gJ4iK7lM9oP",
  "poll_url": "http://127.0.0.1:41414/v1/access-requests/req_7Hs2kQm9vL4pX1nB8cR3tY6wZ0aD5eF2gJ4iK7lM9oP",
  "status": "pending",
  "expires_at": "2026-09-29T14:18:07Z"
}
```

A pending request expires `15:00` after creation. The endpoint accepts 10 requests per
minute in total.

### `GET /v1/access-requests/{request_id}`

Unauthenticated. Poll every 3s. Polling faster than once per 2s is answered with `429`.

The response depends on `status`.

`pending`:

```json
{ "request_id": "req_7Hs2…", "status": "pending", "expires_at": "2026-09-29T14:18:07Z" }
```

`approved`:

```json
{
  "request_id": "req_7Hs2…",
  "status": "approved",
  "approved_at": "2026-09-29T14:05:40Z",
  "token": "tgw_Kq8sT2xvY9bLm4nR7wZ1aC3dE5fG6hJ0iU2oP4rS8tV",
  "webhook": {
    "url": "https://analytics.example.com/tgw/events",
    "secret": "whsec_9fA3kLm2Qp7Rt5Vx8Zy1Bc4De6Fg0Hj3Kl5Mn7Op9Qs"
  },
  "grant": {
    "id": "grant_Ab3dE5fG7hJ9kL1m",
    "app": { "name": "Community Analytics", "description": "Classifies messages in product channels and counts topics per day." },
    "scopes": ["messages:read", "history:read", "chats:read"],
    "chats": { "mode": "list", "chat_ids": ["-1001234567890"] },
    "effective_chat_ids": ["-1001234567890"],
    "created_at": "2026-09-29T14:05:40Z",
    "last_seen_at": null,
    "revoked_at": null
  }
}
```

- The token is included on every poll for `10:00` after approval. Then the request is purged
  and this URL answers `404 not_found`. Store the token the moment you see it
  ([Storing the token](grants.md#storing-the-token)).
- `webhook` is `null` when no webhook was requested. `webhook.secret` (`whsec_` followed by
  43 base64url characters) signs every delivery ([Webhooks](#webhooks)). It is shown here
  and nowhere else.
- The user may have granted fewer scopes and different chats than you asked for. Read
  `grant` rather than assuming.

`denied`:

```json
{ "request_id": "req_7Hs2…", "status": "denied", "denied_at": "2026-09-29T14:05:40Z", "reason": "Not now." }
```

`expired`:

```json
{ "request_id": "req_7Hs2…", "status": "expired", "expires_at": "2026-09-29T14:18:07Z" }
```

Denied and expired requests are also purged `10:00` after they resolve (`404` afterwards).
An app may create a new request at any time.

### Admin side

`GET /v1/admin/access-requests` lists pending requests. Add `?all=true` to include resolved
ones that have not been purged yet.

```json
{
  "access_requests": [
    {
      "request_id": "req_7Hs2…",
      "status": "pending",
      "name": "Community Analytics",
      "description": "Classifies messages in product channels and counts topics per day.",
      "scopes": ["messages:read", "history:read", "chats:read"],
      "requested_chats": ["-1001234567890", "-1001987654321"],
      "requested_chats_status": [
        { "chat_id": "-1001234567890", "title": "Acme Product Updates", "is_monitored": true },
        { "chat_id": "-1001987654321", "title": "Acme Support", "is_monitored": false }
      ],
      "webhook_url": "https://analytics.example.com/tgw/events",
      "created_at": "2026-09-29T14:03:07Z",
      "expires_at": "2026-09-29T14:18:07Z"
    }
  ]
}
```

`requested_chats_status` is `null` when `requested_chats` was `"any"`.

`POST /v1/admin/access-requests/{request_id}/approve` names the chats, or one folder, and
optionally narrows the scopes:

```json
{ "chat_ids": ["-1001234567890"], "scopes": ["messages:read", "chats:read"] }
```

or

```json
{ "folder_id": "3" }
```

| Field | Rules |
|---|---|
| `chat_ids` or `folder_id` | Exactly one of the two. Every chat must be monitored (`400 chat_not_monitored`); the folder must be monitored (`400 folder_not_monitored`). The menu bar app starts monitoring a requested chat before it approves, so the user makes one decision. |
| `scopes` | Optional. Defaults to the requested scopes and must be a subset of them (`400 scope_not_requested`). |

The response is `200` with the grant object. It contains no token: the token goes only to
the app, through polling. A request that is no longer pending answers `409 already_resolved`.

`POST /v1/admin/access-requests/{request_id}/deny` takes `{ "reason": "…" }`. `reason` is
optional and is shown to the app. The response is `200 { "status": "denied" }`.

---

## Grants

A **grant** is one app's access: a token, a set of **scopes** (which kinds of data) and a set
of chats (from where). [grants.md](grants.md) explains the model. The grant object:

```json
{
  "id": "grant_Ab3dE5fG7hJ9kL1m",
  "app": { "name": "Community Analytics", "description": "…" },
  "scopes": ["messages:read", "history:read", "chats:read"],
  "chats": { "mode": "folder", "folder_id": "3", "folder_title": "Product" },
  "effective_chat_ids": ["-1001234567890", "-1001987654321"],
  "webhook": {
    "url": "https://analytics.example.com/tgw/events",
    "state": "active",
    "cursor_seq": 4812,
    "pending_events": 0,
    "last_delivery_at": "2026-09-29T14:03:09Z",
    "last_error": null,
    "paused_at": null
  },
  "created_at": "2026-09-29T14:05:40Z",
  "last_seen_at": "2026-09-29T14:07:12Z",
  "revoked_at": null
}
```

| Field | Meaning |
|---|---|
| `chats.mode` | `"list"` (with `chat_ids`) or `"folder"` (with `folder_id` and `folder_title`). |
| `effective_chat_ids` | What the grant can see right now: the granted chats intersected with the monitored set. It changes when the user changes what is monitored or when the folder's contents change. Rely on this list. |
| `webhook` | `null` if the grant has none. `state` is `active`, `retrying` or `paused` ([Webhooks](#webhooks)). The secret is never included. |
| `last_seen_at` | The last authenticated request or WebSocket frame from this token. `null` until the token is first used. |

### `GET /v1/me`

Any app token. Returns `{ "grant": { … } }` for the calling token. Call it after connecting
and after any `monitoring.*` event to learn what you currently cover.

### `PUT /v1/me/webhook`

Sets or replaces the webhook URL. Body `{ "url": "https://…" }`. Response `200`:

```json
{ "url": "https://…", "secret": "whsec_…", "state": "active", "cursor_seq": 4812 }
```

A new secret is generated on every call, and the previous one stops working. If the webhook
was `paused` it becomes `active` and delivery continues from `cursor_seq`. When a grant gets
its first webhook, `cursor_seq` starts at the current head of the log: the webhook carries
new events only, and earlier ones are read with `GET /v1/events`.

| Call | Result |
|---|---|
| `GET /v1/me/webhook` | The `webhook` part of the grant object, or `404 webhook_not_configured`. |
| `DELETE /v1/me/webhook` | `204`. Pending deliveries are dropped and the cursor is discarded. |
| `POST /v1/me/webhook/resume` | `200` with the same body as `PUT`, without `secret`. Valid only when `state` is `paused`, otherwise `409 webhook_not_paused`. |

### Admin

| Call | Result |
|---|---|
| `GET /v1/admin/grants` | `{ "grants": [ … ] }`. Add `?include_revoked=true` to include revoked grants, which are kept for 30 days and then deleted. |
| `GET /v1/admin/grants/{grant_id}` | `{ "grant": { … }, "stats": { "events_delivered_24h": 812, "websocket_connections": 1 } }` |
| `DELETE /v1/admin/grants/{grant_id}` | `204`. Revokes the grant: its token answers `401 token_revoked`, its open WebSockets close with code `4499`, and its pending webhook deliveries are dropped. Immediate and permanent; the app must request access again. |
| `POST /v1/admin/grants/{grant_id}/webhook/resume` | The same as the app's own resume. |
| `GET /v1/admin/grants/{grant_id}/deliveries?limit=50` | Recent webhook deliveries, newest first (below). |

```json
{
  "deliveries": [
    {
      "delivery_id": "dlv_8Kp2mQ9xR4tV7wY1",
      "first_seq": 4810,
      "last_seq": 4812,
      "event_count": 2,
      "attempt": 1,
      "status": "succeeded",
      "http_status": 200,
      "error": null,
      "sent_at": "2026-09-29T14:03:09.117Z",
      "completed_at": "2026-09-29T14:03:09.245Z"
    }
  ],
  "has_more": false
}
```

`status` is `succeeded`, `failed` or `in_flight`.

---

## Chats

### The chat object

```json
{
  "id": "-1001234567890",
  "type": "channel",
  "title": "Acme Product Updates",
  "username": "acmeupdates",
  "member_count": 12840,
  "is_monitored": true,
  "photo": { "media_id": "med_3fK9…", "width": 640, "height": 640 }
}
```

| Field | Notes |
|---|---|
| `type` | `private`, `basic_group`, `supergroup` or `channel` ([Chat ids](#chat-ids)). |
| `username` | The public handle without `@`. `null` for private chats and for groups without one. A chat with a username is reachable at `https://t.me/<username>`. |
| `member_count` | `null` when Telegram does not report it: private chats, and channels whose count the account cannot read. |
| `is_monitored` | Whether the gateway currently watches this chat. For an app this is `false` only for a granted chat that the user has since stopped monitoring. The chat stays in the app's list so the app knows it lost coverage. |
| `photo` | The chat's profile photo as a reduced [media object](events.md#media-object), fetchable with `media:read`. `null` if the chat has none. |

### `GET /v1/chats`

Requires `chats:read`. Returns the chats in the grant (list or folder), each with
`is_monitored`. The response is never paginated.

```json
{ "chats": [ { …chat object… } ] }
```

`GET /v1/chats/{chat_id}` returns `{ "chat": { … } }`, or `403 chat_not_granted`.

### Admin: chat list, folders, monitored set

`GET /v1/admin/chats` returns the monitored chats.
`GET /v1/admin/chats?all=true&limit=200&cursor=…` returns every chat in the account's main
chat list, in Telegram's order (most recent activity first), paginated with `next_cursor`
(an opaque string). `limit` is 1–500, default 200. Secret chats are omitted. The full list
needs a signed-in gateway (`503 not_logged_in` otherwise).

```json
{ "chats": [ … ], "has_more": true, "next_cursor": "c_MTcyNzYxNDU4Nw" }
```

`GET /v1/admin/folders` returns the account's **chat folders**. A folder is a named tab in
Telegram's own apps ("Work", "Product") that groups chats; the user edits it on their phone
or desktop. The gateway exposes folders so that a grant, or the monitored set, can follow
one.

```json
{
  "folders": [
    { "id": "3", "title": "Product", "chat_ids": ["-1001234567890", "-1001987654321"], "is_monitored": true }
  ]
}
```

Folder ids are Telegram's and are strings like every id. A folder defined by a filter (for
example "all unread") is listed with the chats it currently contains, and the gateway
re-evaluates its membership whenever Telegram reports a change.

`GET /v1/admin/monitored-chats`:

```json
{
  "chat_ids": ["-1001234567890"],
  "folder_ids": ["3"],
  "effective_chat_ids": ["-1001234567890", "-1001987654321"]
}
```

`PUT /v1/admin/monitored-chats` with `{ "chat_ids": [ … ], "folder_ids": [ … ] }` replaces
the whole monitored set. Both arrays are required; empty arrays clear the set. The effective
set is the union of the listed chats and every chat in the listed folders. The response is
`200` with the same shape as `GET`.

| Condition | Response |
|---|---|
| An unknown chat, or a secret chat | `400 chat_not_monitorable` |
| A folder id the gateway has not seen from Telegram | `400 invalid_request` with `field: "folder_ids"` |
| The gateway is not signed in (it needs Telegram to validate a chat) | `503 not_logged_in` |

Each chat that enters or leaves the effective set produces a `monitoring.started` or
`monitoring.stopped` event ([events.md](events.md#monitoringstarted-and-monitoringstopped)).
When one `PUT` both removes and adds chats, the `stopped` events are recorded before the
`started` ones. The gateway begins watching a new chat within a few seconds. Events start at
the moment of the change: messages sent before a chat was monitored are available only
through [History](#history).

---

## Events

The gateway appends every event to one **event log** and gives each a **sequence number**
(`seq`): a positive integer that increases strictly across the whole log and is never reused.
There is one log per gateway, so an app sees gaps in the numbers where events for chats
outside its grant are skipped. Within what one app sees, order is by `seq` and never changes.
The event object is defined in [events.md](events.md).

An app keeps a **cursor**: the `seq` of the last event successfully processed. Passing that
cursor as `since` resumes later retained events. Persist the cursor after processing and
deduplicate by `seq` if a crash causes an event to be processed again.

Both endpoints below apply the grant at the time of reading. An app receives events for the
chats in its current `effective_chat_ids`, and only the event types its scopes allow:

| Event types | Scope needed |
|---|---|
| `message.new`, `message.edited`, `message.deleted` | `messages:read` |
| `chat.updated`, `monitoring.started`, `monitoring.stopped` | `chats:read` |

A chat that joins a grant (through its folder) brings its stored events with it; a chat that
leaves takes them out of view.

### `since` semantics

`since=<seq>` is **exclusive**: the response starts at the first event with `seq > since`.
`since=0` means from the beginning of retained history. Store the `seq` of the last event you
processed and pass it back unchanged.

### Retention

By default the gateway keeps every event forever (`events_retention_days: null`). The user
can prune old events ([Admin: pruning](#admin-pruning)) or set a retention period.

If a read starting after `since` would silently skip pruned events, that is if `since + 1`
is lower than the oldest retained `seq`, the request fails with `410 history_pruned` and
`details.oldest_seq`. `since=0` is exempt: it always means "from the beginning of retained
history". To continue after this error, resume with `since = oldest_seq - 1`, which delivers
the oldest retained event first. The events below it are gone from the log;
[History](#history) can fill the gap for messages.

### `GET /v1/events`

```
GET /v1/events?since=4700&limit=100&types=message.new,message.edited&chat_id=-1001234567890
```

| Query | Default | Rules |
|---|---|---|
| `since` | `0` | Exclusive lower bound on `seq`. |
| `limit` | `100` | 1–1000. |
| `types` | all | Comma-separated event types to include. |
| `chat_id` | all | One chat id. Repeat the parameter for several. |

Response `200`:

```json
{
  "events": [ { "v": 1, "seq": 4701, "type": "message.new", … }, … ],
  "has_more": true,
  "next_since": 4800,
  "head_seq": 4812
}
```

Events are in ascending `seq`. `next_since` is the `seq` of the last event returned, or
`since` when `events` is empty. `head_seq` is the newest `seq` in the whole log, so
`head_seq - next_since` bounds how far behind you are. The endpoint returns a page and never
waits: an empty `events` array means there is nothing new yet.

### `GET /v1/events/stream` (WebSocket)

A **WebSocket** is a persistent two-way connection opened with an HTTP upgrade request. Send
the same `Authorization` header on the upgrade. Query parameters are `since`, `types` and
`chat_id`, as above.

```
GET /v1/events/stream?since=4700 HTTP/1.1
Upgrade: websocket
Authorization: Bearer tgw_…
```

- With `since`, the gateway sends the backlog in order, then a `caught_up` frame, then live
  events as they are recorded.
- Without `since`, the stream is live only: there is no backlog, and the first frame is
  `caught_up` with the current head.

Every frame is a text frame holding one JSON object with a `type`:

| Frame | Shape | When |
|---|---|---|
| Event | `{ "type": "event", "event": { …event object… } }` | One per event, in `seq` order. |
| Caught up | `{ "type": "caught_up", "seq": 4812 }` | Once, after the backlog, or immediately if there is none. `seq` is the head of the log at that moment. The stream is now live. |
| Heartbeat | `{ "type": "heartbeat", "seq": 4812, "time": "2026-09-29T14:03:37.001Z" }` | Every 30s in which no event was sent. `seq` is the head of the whole log, so it may exceed the last event this app saw. |
| Error | `{ "type": "error", "code": "history_pruned", "message": "…", "details": { "oldest_seq": 4000 } }` | Immediately before the gateway closes the socket. Codes are the HTTP `error.code` values, plus `slow_consumer`. |

The gateway answers standard WebSocket ping frames with pong.

**Liveness.** Treat the connection as dead if no frame of any kind arrives for `01:30`, and
reconnect with the last `seq` you processed.

**The app owns the cursor.** There is no acknowledgement from the client. Reconnecting always
replays from `since`, so an app that processed `seq` 4810 and reconnected before storing it
receives 4810 again. Deduplicate on `seq` ([integrating.md](integrating.md#deduplicate-on-seq)).

**Slow consumers.** The gateway sends as fast as the socket accepts. If a connection falls
more than 10 000 events behind the head of the log (the socket is not draining while events
keep arriving), the gateway sends an error frame with code `slow_consumer` and closes with
`1008`. Reconnect with `since`; the backlog is replayed at whatever pace you read.

**Connections.** Up to 4 concurrent WebSocket connections per token, each with its own
`since`.

#### Close codes

The upgrade always succeeds, because a refused upgrade cannot carry a JSON body. Problems are
reported after it, as an error frame where the table says so, followed by a close with one of
these codes:

| Code | Meaning | Error frame first | Reconnect? |
|---|---|---|---|
| `1001` | The gateway is shutting down (restart or upgrade). | no | Yes, with backoff. |
| `1008` | `slow_consumer`: more than 10 000 events behind. | yes | Yes, with `since`. |
| `4400` | The query string is invalid (`since`, `types` or `chat_id`). | yes, `invalid_request` | No: fix the request. |
| `4401` | The token is missing, invalid or revoked. | yes: `missing_token`, `invalid_token` or `token_revoked` | No. |
| `4403` | The grant has neither `messages:read` nor `chats:read`, so there is nothing to stream. | no | No. |
| `4409` | Too many connections for this token (the limit is 4). | no | Only after closing another connection. |
| `4410` | `history_pruned` ([Retention](#retention)). | yes, with `details.oldest_seq` | Yes, with `since = oldest_seq - 1`. |
| `4429` | The token's request budget (600 per minute) is used up. | yes, `rate_limited` | Yes, after `details.retry_after` seconds. |
| `4499` | The grant was revoked while connected. | no | No. |

---

## History

`GET /v1/chats/{chat_id}/messages` requires `history:read`, and the chat must be in the
grant's `effective_chat_ids` (for the admin token: monitored).

It reads the chat's timeline **from Telegram**, not from the event log, so it reaches back
before the chat was monitored and before the grant existed, as far as the user's account can
see. It is slower than the event endpoints and has a tighter rate limit, because Telegram
limits history reads.

```
GET /v1/chats/-1001234567890/messages?before=1523&limit=50
```

| Query | Default | Rules |
|---|---|---|
| `before` | newest | Exclusive: return messages with an id lower than this. Omit it for the newest messages. |
| `limit` | `50` | 1–100. |

Response `200`, **newest first**:

```json
{
  "messages": [ { "id": "1522", "chat_id": "-1001234567890", … }, { "id": "1519", … } ],
  "has_more": true,
  "next_before": "1519"
}
```

Each item is a [message object](events.md#message-object), the same shape as in
`message.new`. Message ids are not contiguous: deleted messages leave holes. `next_before`
is the id of the oldest message returned; pass it as `before` to continue backwards.

`has_more` is `true` whenever a full page came back. The last full page before the beginning
of the chat is therefore followed by one empty page with `has_more: false`.

`503 telegram_unavailable` when the connection to Telegram is down.

---

## Sending messages

`POST /v1/chats/{chat_id}/messages` sends a text message to a chat **as the user**: it goes
out from the user's Telegram account, and everyone in the chat sees it as written by them. It
requires `messages:send`, and the chat must be in the grant's `effective_chat_ids` (for the
admin token: monitored). The gateway sends only to chats it monitors.

```
POST /v1/chats/-1001987654321/messages
Authorization: Bearer tgw_…
Content-Type: application/json

{ "text": "Thanks, this is fixed in 2.4.1.", "reply_to": "1522" }
```

| Field | Required | Rules |
|---|---|---|
| `text` | yes | Plain text, sent as written: no Markdown, no formatting entities. Not empty or only whitespace. At most 4096 characters as Telegram counts them, in UTF-16 code units, so an emoji outside the Basic Multilingual Plane counts as two. |
| `reply_to` | no | The id of a message in the same chat, as a string. The new message is sent as a reply to it. |

The gateway hands the message to Telegram and waits for Telegram to confirm that its servers
stored it, up to `30s`. Response `201 Created` with the message as Telegram stored it, with
its final id, in the [message object](events.md#message-object) format:

```json
{
  "message": {
    "id": "1530",
    "chat_id": "-1001987654321",
    "sender": { "type": "user", "id": "987654321", "display_name": "Ada Lovelace", "username": "ada", "is_bot": false },
    "date": "2026-09-29T14:05:12Z",
    "edit_date": null,
    "is_outgoing": true,
    "text": "Thanks, this is fixed in 2.4.1.",
    "entities": [],
    "reply_to": { "chat_id": "-1001987654321", "message_id": "1522" },
    "forward_from": null,
    "media": [],
    "media_group_id": null,
    "link": null,
    "raw_content_type": "messageText"
  }
}
```

The message also enters the event log as an ordinary `message.new` with `is_outgoing: true`,
exactly once, before the response is sent ([events.md](events.md#messagenew)). Apps that
hold `messages:read` for the chat receive it like any message the user sends from their
phone, including the app that sent it: deduplicate on the message id if that matters to you.

| Condition | Response |
|---|---|
| The grant lacks `messages:send` | `403 insufficient_scope` |
| The chat is outside the grant, not monitored, or does not exist | `403 chat_not_granted` |
| `text` missing or not a string; `reply_to` not a message id string | `400 invalid_request` with `details.field` |
| `text` empty or only whitespace | `400 invalid_request` with `details.field: "text"`, `details.reason: "empty"` |
| `text` over 4096 characters | `400 invalid_request` with `details.field: "text"`, `details.reason: "too_long"`, `details.max_length: 4096` |
| More than 20 sends in a minute from this token | `429 rate_limited` |
| Telegram asks the account to slow down (a flood wait) | `429 rate_limited`, with Telegram's wait in `retry_after` |
| The gateway is not signed in, or the connection to Telegram is down | `503 not_logged_in`, `503 telegram_unavailable` |
| Telegram refuses the message: the account may not write in the chat, is restricted, the reply target is invalid | `502 send_failed`; `details.reason` is Telegram's text (for example `CHAT_WRITE_FORBIDDEN`) and `details.telegram_code` its number |
| Telegram does not confirm within `30s` | `504 send_timeout` |

**After a timeout the message may still go out.** The gateway has handed it to Telegram and
cannot take it back. If it is sent later, it appears in the event stream as `message.new`.
Before sending again, check the stream for it, or you may post the same text twice.

The gateway does not retry a send, never marks the chat as read, and never makes the account
appear online to send. Telegram itself counts sending as activity of the account; how it
reflects that on the user's other devices has not been verified
([status.md](status.md)).

---

## Media

A message with a photo, video or file carries a **media object** with a `media_id`
([events.md](events.md#media-object)). The bytes are fetched from the gateway, which
downloads the file from Telegram on first request and caches it. Media ids are stable: the
same Telegram file referenced by two messages has the same `media_id`.

### `GET /v1/media/{media_id}`

Requires `media:read`. The media must belong to a message, or be the profile photo of a chat,
in the grant's `effective_chat_ids`.

| Situation | Response |
|---|---|
| The file is cached | `200` with the bytes. `Range` requests are honoured (`206`), so a large video can be streamed. |
| Not cached, and the download finishes within 30s | `200` as above. |
| Not cached, and the download takes longer | `202 Accepted` with `Retry-After: 5` and the body below. Request again; each request waits up to 30s. |
| Telegram can no longer supply the file | `410 media_gone` |
| Not cached, and the connection to Telegram is down | `503 telegram_unavailable` |
| A fifth concurrent uncached download for one token | `429 rate_limited` with `Retry-After: 5` |
| The media is outside the grant, or the id is unknown | `403 chat_not_granted` (never `404`) |

```json
{ "status": "downloading", "media_id": "med_…", "bytes_downloaded": 3145728, "size": 20971520 }
```

Headers on `200` and `206`:

| Header | Value |
|---|---|
| `Content-Type` | The media object's `mime`, or `application/octet-stream`. |
| `Content-Length` | The size in bytes. |
| `Content-Disposition` | `inline; filename="<file_name>"`, when the name is known. |
| `ETag` | `"<media_id>"` |
| `Cache-Control` | `private, max-age=31536000, immutable` |

`HEAD /v1/media/{media_id}` returns the headers without the body and does not start a
download. `Content-Length` is the size from the media object when known, and `X-TGW-Cached`
is `true` or `false`.

A chat's profile photo is served as `image/jpeg` at Telegram's "big" size, which the gateway
reports as 640×640 (Telegram does not supply the dimensions of chat photos).

### Cache

Cached files live inside the gateway's data directory. When the cache exceeds
`media_cache_max_bytes` (default 2 GiB), the gateway evicts the files served least recently.
An evicted file is downloaded again on the next request. Only the bytes are evicted; the
media object in the event log stays.

---

## Webhooks

A **webhook** is an HTTPS endpoint that an app runs. The gateway `POST`s events to it, so the
app needs no open connection to the gateway and can run on another machine. An app registers
a webhook in its access request (`webhook.url`) or later with `PUT /v1/me/webhook`.

For a webhook the gateway keeps the cursor: `cursor_seq` on the grant is the last `seq` the
app acknowledged.

### What the gateway sends

Deliveries are **batches** of events in `seq` order:

```
POST /tgw/events HTTP/1.1
Host: analytics.example.com
Content-Type: application/json; charset=utf-8
User-Agent: TelegramGateway/1
X-TGW-Delivery-Id: dlv_8Kp2mQ9xR4tV7wY1
X-TGW-Seq: 4812
X-TGW-Attempt: 1
X-TGW-Signature: sha256=5f1a9c…e3b0

{
  "v": 1,
  "delivery_id": "dlv_8Kp2mQ9xR4tV7wY1",
  "grant_id": "grant_Ab3dE5fG7hJ9kL1m",
  "sent_at": "2026-09-29T14:03:09.117Z",
  "events": [
    { "v": 1, "seq": 4810, "type": "message.new", … },
    { "v": 1, "seq": 4812, "type": "message.edited", … }
  ]
}
```

| Header | Meaning |
|---|---|
| `X-TGW-Delivery-Id` | Unique per delivery, and the same on every retry of that delivery. |
| `X-TGW-Seq` | The highest `seq` in the batch. |
| `X-TGW-Attempt` | `1` for the first try, incremented on each retry. |
| `X-TGW-Signature` | `sha256=` followed by the lowercase hex of HMAC-SHA256, keyed with the webhook secret, over the raw request body bytes exactly as sent. Verify it before parsing ([integrating.md](integrating.md#verify-webhook-signatures)). |

**Batching.** The gateway sends a delivery as soon as at least one event is pending and
either 100 events are pending or 500 ms have passed since the first pending event. A batch
never exceeds 100 events or 4 MiB of JSON. Media bytes are never in a webhook, only media
objects. Batches of one event are normal for quiet chats.

**The secret.** The gateway stores the webhook secret itself, since it needs it to sign.
This differs from tokens, of which it keeps only a hash.

### Success and failure

A delivery **succeeds** when the app answers any `2xx` within `10s` of the request being
sent. The response body is ignored. Everything else is a failure: a non-2xx status (redirects
are not followed and count as failures), a refused connection, a TLS error, a timeout.

Only one delivery is in flight per grant at a time, and the next batch is sent only after the
previous one succeeded. That is what guarantees order.

### Retry schedule

A failed delivery is retried with the same `delivery_id` and the same events, an incremented
`X-TGW-Attempt`, and `sent_at` set to the time of the new attempt:

| Attempt | Delay before it | Elapsed since first failure (approx.) |
|---|---|---|
| 2 | `10s` | `10s` |
| 3 | `30s` | `40s` |
| 4 | `01:00` | `01:40` |
| 5 | `02:00` | `03:40` |
| 6 | `05:00` | `08:40` |
| 7 | `10:00` | `18:40` |
| 8 | `30:00` | `48:40` |
| 9 | `1:00:00` | `1:48:40` |
| 10 … 31 | `1:00:00` each | up to `24:00:00` |

If, after a failed attempt, the next attempt would land more than `24:00:00` after the first
failure, the webhook enters state **`paused`** instead. Attempt 31 is the last one in the
table. A paused webhook makes no more attempts; its cursor is kept and events keep
accumulating in the log.

A paused webhook is resumed by the user in the menu bar app, or by the app itself with
`POST /v1/me/webhook/resume` or by replacing the URL with `PUT /v1/me/webhook`. Delivery
continues from the cursor, and no event is lost.

While a webhook is `retrying` or `paused`, new events queue behind the failing delivery. Once
it succeeds, the following batches drain the queue back to back, up to 100 events each.

State survives a restart of the gateway. A delivery whose result was unknown at the time of
the restart is sent again, which is one source of duplicates.

### Guarantees

- **In order**, per grant: an app never receives a `seq` lower than one it has already
  acknowledged with a `2xx`.
- **At least once**: if a `2xx` never reaches the gateway (the network drops after the app
  processed the batch), the same delivery is sent again. Deduplicate on `seq`
  ([integrating.md](integrating.md#deduplicate-on-seq)).
- **Independent of the WebSocket**: a grant may use both at once. They have separate cursors,
  and the same events appear on both.

### Consumer-side pause

An app that wants deliveries to stop (maintenance, a migration) answers `410 Gone`. The
gateway pauses the webhook at once instead of retrying for a day. It resumes as described
above.

---

## Health

### `GET /v1/health`

Unauthenticated and not rate-limited. It never reveals chat or grant data.

```json
{
  "status": "ok",
  "version": "0.1.0",
  "started_at": "2026-09-29T09:00:12.004Z",
  "time": "2026-09-29T14:03:37.001Z",
  "tdlib": {
    "auth_state": "ready",
    "connection_state": "ready"
  },
  "head_seq": 4812
}
```

The HTTP status is `200` for both values of `status`: the endpoint answers "is the gateway
running". Read the body for the rest.

| Field | Values |
|---|---|
| `status` | `ok`: signed in and connected. `degraded`: running, but `auth_state` or `connection_state` is not `ready`. |
| `tdlib.auth_state` | The state of the Telegram sign-in, below. |
| `tdlib.connection_state` | `waiting_for_network`, `connecting`, `updating` (connected and catching up on what was missed), `ready`. |
| `head_seq` | The newest `seq` in the event log. |

| `auth_state` | Meaning |
|---|---|
| `wait_phone_number` | Not signed in: never signed in, or signed out. |
| `wait_qr_confirmation` | A QR code is displayed and waiting to be scanned. |
| `wait_code` | Telegram sent a sign-in code by SMS or in-app message. |
| `wait_password` | The account's two-step verification password is needed. |
| `wait_email_address`, `wait_email_code` | The account signs in with a code sent by e-mail. |
| `wait_registration` | The phone number has no Telegram account. The gateway never creates one. |
| `ready` | Signed in. |
| `logging_out`, `closed` | The session is ending or has ended. |
| `unknown` | No `api_id` / `api_hash` is configured, or TDLib has not started. |

### `GET /v1/admin/status`

Admin. Everything in `/v1/health`, plus:

| Field | Meaning |
|---|---|
| `account` | `{ "user_id": "987654321", "display_name": "Ada Lovelace", "username": "ada", "phone_last4": "4567" }` when signed in, otherwise `null`. |
| `monitored_chat_count`, `grant_count` | Counts. |
| `webhooks` | `{ "active": 2, "retrying": 0, "paused": 1 }`: counts by state. |
| `events_last_hour`, `events_today` | Events recorded in the last hour, and since local midnight. |
| `oldest_seq` | The oldest retained `seq`, or `null` when the log is empty. |
| `media_cache_bytes` | Current size of the media cache. |
| `backfill` | `{ "in_progress": false, "chats_pending": 0 }`: whether the gateway is fetching messages it missed while offline. |
| `links` | The links to Volgenic and their state, as in [Admin: links to Volgenic](#admin-links-to-volgenic). An empty array when there are none. Absent when the request comes over a link. |

---

## Admin: login

The menu bar app and `tgw` sign the gateway in to Telegram through these endpoints. The
states are those of `tdlib.auth_state` above.

`GET /v1/admin/auth` returns the current state:

```json
{
  "auth_state": "wait_qr_confirmation",
  "qr_link": "tg://login?token=…",
  "phone_hint": null,
  "code_type": null,
  "password_hint": null
}
```

| Field | Present when | Meaning |
|---|---|---|
| `qr_link` | `wait_qr_confirmation` | Render it as a QR code for the user to scan with a phone that is already signed in to Telegram. The link changes about every 30s, so poll this endpoint every 2s while displaying it. |
| `phone_hint` | `wait_code` | The number the code was sent to. |
| `code_type` | `wait_code` | How the code was sent: `sms`, `call`, `telegram_message`, `flash_call`, `missed_call`, `fragment`, `firebase` or `unknown`. |
| `password_hint` | `wait_password` | The hint the user set for their password. |

Every `POST` below answers with this same object, describing the state after the step.

| Method and path | Body | Effect |
|---|---|---|
| `POST /v1/admin/auth/qr` | | Requests or refreshes a QR sign-in. Moves to `wait_qr_confirmation`. |
| `POST /v1/admin/auth/phone` | `{ "phone_number": "+15551234567" }` | Starts a sign-in by phone number. Moves to `wait_code`. |
| `POST /v1/admin/auth/code` | `{ "code": "12345" }` | Submits the code Telegram sent. Moves to `ready` or `wait_password`. |
| `POST /v1/admin/auth/password` | `{ "password": "…" }` | Submits the two-step verification password. Moves to `ready`. |
| `POST /v1/admin/auth/email` | `{ "email_address": "ada@example.com" }` | For accounts Telegram asks for an e-mail address (`wait_email_address`). Moves to `wait_email_code`. |
| `POST /v1/admin/auth/email_code` | `{ "code": "…" }` | Submits the code from the e-mail. Moves to `wait_password` or `ready`. |
| `POST /v1/admin/auth/logout` | | Ends the Telegram session on this Mac. The event log, grants and monitored set are kept; nothing new arrives until the next sign-in. |

| Failure | Response |
|---|---|
| Wrong code (SMS, in-app or e-mail) | `400 invalid_request` with `details.reason: "wrong_code"` |
| Wrong password | `400 invalid_request` with `details.reason: "wrong_password"` and `details.password_hint` |
| No `api_id` / `api_hash` configured | `503 not_logged_in` with `auth_state: "unknown"`, on every endpoint in this section |

The gateway passes the phone number, codes and password to TDLib and stores none of them.

---

## Admin: reload

`POST /v1/admin/reload` makes the gateway re-read `config.json` and bring its Telegram session
and its links to Volgenic in line with it, without a restart. The event log, grants, webhook cursors and open WebSocket
connections are untouched. The menu bar app calls it after saving `api_id` and `api_hash`;
`tgw daemon reload` calls it from the command line. There is no request body.

Response `200`:

```json
{
  "reloaded": true,
  "telegram": "started",
  "restart_required": [],
  "links": { "started": ["https://volgenic.com"], "restarted": [], "stopped": [], "unchanged": [] }
}
```

| Field | Meaning |
|---|---|
| `telegram` | What happened to the Telegram session, below. |
| `restart_required` | Keys that changed in `config.json` but take effect only when the gateway restarts: any of `port`, `secrets`, `events_retention_days` and `media_cache_max_bytes`. Empty when none changed. |
| `links` | What happened to the links, by base URL: `started` (new), `restarted` (a new token, or a link Volgenic had refused, tried again), `stopped` (removed, or its token is gone), `unchanged`. Each link's token is read from the secret store at this moment. |

| `telegram` | Meaning |
|---|---|
| `started` | There were no credentials and now there are. A session was created, and the sign-in flow is available: `GET /v1/admin/auth` reflects it at once. |
| `restarted` | The credentials changed. The old session was closed, and confirmed closed, before a new one was created; the gateway never runs two TDLib clients on its directory. |
| `unchanged` | The same credentials as before. Nothing was touched. |
| `disabled` | The file has no credentials. A session that existed was closed. |

A reload while signed in with unchanged credentials does nothing (`unchanged`), so it is safe
to call after every save.

| Failure | Response |
|---|---|
| The file cannot be read as configuration | `400 invalid_request` with `details.field: "config.json"` and the parse error in `details.reason`. The running session is left alone. |
| Another reload is still running | `409 reload_in_progress` |
| The old session did not confirm that it closed | `500 internal`. No new session is created; the gateway must be restarted. |
| App token | `403 admin_only` |

---

## Admin: links to Volgenic

A **link** is an outbound WebSocket from the gateway to a Volgenic server, over which that
Volgenic account drives the gateway with the admin token's powers, except anything to do
with secrets. [link.md](link.md) specifies the protocol. Links are added and removed with
`tgw link add` and `tgw link remove`, which edit `config.json` and the secret store and then
call `POST /v1/admin/reload`.

`GET /v1/admin/links` returns every configured link and its state:

```json
{
  "links": [
    {
      "base_url": "https://volgenic.com",
      "state": "connected",
      "connected": true,
      "since": "2026-10-26T14:03:07.412Z",
      "last_error": null,
      "last_error_at": null,
      "retry_at": null
    }
  ]
}
```

`state` is `connecting`, `connected`, `waiting` (to retry at `retry_at`), `unauthorized`
(Volgenic refused the token; no more attempts until the link is added again or the gateway
reloads), `no_token` (no token in the secret store) or `stopped`. `since` is when the link
entered that state; `last_error` is the most recent failure and stays after the link
recovers. A link cannot call this endpoint.

---

## Admin: pruning

`POST /v1/admin/events/prune` deletes events below a boundary, given as one of:

```json
{ "before_seq": 4000 }
```

```json
{ "older_than": "2026-06-01T00:00:00Z" }
```

Response `200`:

```json
{ "deleted": 3999, "oldest_seq": 4000 }
```

If a webhook has not yet delivered events below the boundary, the prune is refused with
`409 cursor_behind` and `details.grant_id`. Adding `"force": true` prunes anyway: that
webhook's cursor moves forward so that its next delivery starts at the oldest retained event,
and the gap is recorded in the webhook's `last_error`.

Setting `events_retention_days` in `config.json` makes the gateway run the equivalent of
`older_than` once an hour, without `force`.

An app whose cursor is below the boundary learns of the gap through `410 history_pruned`
([Retention](#retention)).

---

## Rate limits

Limits are per token (per source address for the unauthenticated endpoints) and generous,
since the API is local. They protect Telegram's own limits (history and media are read from
Telegram) and the gateway's database.

| What is limited | Limit |
|---|---|
| All requests, per token | 600 per minute |
| `GET /v1/chats/{chat_id}/messages` | 60 per minute |
| `POST /v1/chats/{chat_id}/messages` | 20 per minute |
| `GET /v1/media/{media_id}`, uncached | 4 concurrent downloads per token |
| `POST /v1/access-requests` | 10 per minute in total |
| `GET /v1/access-requests/{id}` | 1 per 2s per request id |
| WebSocket connections | 4 per token |

Exceeding a limit returns `429 rate_limited` with a `Retry-After` header (seconds) and
`details.retry_after`. Every authenticated response carries `X-RateLimit-Limit` and
`X-RateLimit-Remaining` for the per-token budget. The unauthenticated endpoints have no
per-token budget and carry neither header.

---

## Not supported

| Not supported | What happens instead |
|---|---|
| Acting on the account beyond sending text (marking as read, joining or leaving chats, appearing online, editing or deleting messages) | Not possible. The only action is [sending a text message](#sending-messages) with `messages:send`. |
| Sending photos, files, stickers or formatted text | Messages are plain text only. |
| Reaching the API from another machine | The gateway listens on `127.0.0.1` only. An app on another machine receives events through a [webhook](#webhooks); the WebSocket, history and media endpoints are reachable only from the Mac that runs the gateway. The one exception is a Volgenic server the user linked with `tgw link add`: the gateway dials it and carries its requests ([link.md](link.md)). |
| Calling the API from a web page | No CORS headers, and the WebSocket needs an `Authorization` header, which browsers cannot set. |
| More than one Telegram account | One gateway is signed in to one account. |
| Secret chats | They cannot be monitored and never appear. |
| Changing a grant's scopes or chat list in place | The user revokes the grant and the app requests access again. A folder-based grant does follow its folder ([grants.md](grants.md#folder-based-grants)). |
| Expiring or rotating an app token | Tokens do not expire. Access ends when the user revokes the grant. |
| Reactions, view counts, polls, text formatting, forum topics | Not part of the event format: see [events.md](events.md#not-supported). |
| Operating systems other than macOS | The gateway runs on macOS only. Apps can run anywhere a webhook can reach. |

---

## Endpoint index

| Auth | Method | Path | Scope | Purpose |
|---|---|---|---|---|
| none | GET | `/v1/health` | | Is the gateway running, and its Telegram state |
| none | POST | `/v1/access-requests` | | Ask for access |
| none | GET | `/v1/access-requests/{id}` | | Poll for approval |
| app | GET | `/v1/me` | any | The calling token's grant |
| app | GET | `/v1/me/webhook` | any | Webhook state |
| app | PUT | `/v1/me/webhook` | any | Set or replace the webhook URL (new secret) |
| app | DELETE | `/v1/me/webhook` | any | Remove the webhook |
| app | POST | `/v1/me/webhook/resume` | any | Resume a paused webhook |
| app | GET | `/v1/chats` | `chats:read` | Granted chats |
| app | GET | `/v1/chats/{chat_id}` | `chats:read` | One chat |
| app | GET | `/v1/events` | `messages:read` or `chats:read` | Paged backlog |
| app | GET | `/v1/events/stream` | `messages:read` or `chats:read` | WebSocket stream |
| app | GET | `/v1/chats/{chat_id}/messages` | `history:read` | History from Telegram |
| app | POST | `/v1/chats/{chat_id}/messages` | `messages:send` | Send a text message as the user |
| app | GET, HEAD | `/v1/media/{media_id}` | `media:read` | File bytes |
| admin | GET | `/v1/admin/status` | | Full status |
| admin | GET | `/v1/admin/auth` | | Sign-in state |
| admin | POST | `/v1/admin/auth/{qr,phone,code,password,email,email_code,logout}` | | Drive the sign-in |
| admin | POST | `/v1/admin/reload` | | Re-read `config.json`; apply a new `api_id` / `api_hash` and the links in place |
| admin | GET | `/v1/admin/links` | | Links to Volgenic and their state |
| admin | GET | `/v1/admin/access-requests` | | Pending requests |
| admin | POST | `/v1/admin/access-requests/{id}/approve` | | Approve, optionally narrowed |
| admin | POST | `/v1/admin/access-requests/{id}/deny` | | Deny |
| admin | GET | `/v1/admin/grants` | | All grants |
| admin | GET | `/v1/admin/grants/{id}` | | One grant with stats |
| admin | DELETE | `/v1/admin/grants/{id}` | | Revoke |
| admin | POST | `/v1/admin/grants/{id}/webhook/resume` | | Resume a paused webhook |
| admin | GET | `/v1/admin/grants/{id}/deliveries` | | Delivery log |
| admin | GET | `/v1/admin/chats` | | Monitored chats, or the whole chat list with `?all=true` |
| admin | GET | `/v1/admin/folders` | | Chat folders |
| admin | GET, PUT | `/v1/admin/monitored-chats` | | The monitored set |
| admin | POST | `/v1/admin/events/prune` | | Delete old events |

Rows marked "app" also accept the admin token, which behaves as a grant with every scope over
every monitored chat.
