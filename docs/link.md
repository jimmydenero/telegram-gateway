# The link to Volgenic

The gateway listens only on `127.0.0.1`, so a service on the internet cannot reach it. A
**link** turns the connection around: the gateway dials out to a Volgenic server and keeps
one WebSocket open, and over it that Volgenic account drives the gateway as the menu bar app
does: it signs in to Telegram, lists chats, chooses the monitored set, reads history and
media, sends messages, and receives the gateway's events. **Volgenic** is a web application
with a Messages tab built on this protocol; one link belongs to one Volgenic person.

This document is the protocol (version 1) and how the gateway implements it. Terms used
below: an **event** and its **sequence number** (`seq`) are defined in
[events.md](events.md) and [api.md](api.md#events); the **admin token** is the gateway's
all-powerful token ([api.md](api.md#authentication)); the **secret store** is where the
gateway keeps secrets ([development.md](development.md#secrets)).

Durations are written `mm:ss`; values under a minute in seconds, for example `30s`.

## What a link can do

A link acts with the admin token, so it can do everything the menu bar app can, except see
or change secrets: sign in and out of Telegram, change the monitored set, approve and revoke
apps, read every monitored chat's events, history and media, and **send messages as the
user to every monitored chat**. Link only to a Volgenic account that is yours. The gateway
still never marks anything as read and never makes the account appear online, whoever asks.

## Pairing

1. In Volgenic (Messages › Connections › Telegram) the person asks to link a gateway.
   Volgenic creates a **link token**: `vgl_` followed by 43 base64url characters (32 random
   bytes). It stores only the token's SHA-256 hash, shows the token once, and shows the
   command to run on the Mac:

   ```
   tgw link add https://volgenic.com vgl_…
   ```

2. `tgw link add <base_url> <token>` stores the link, the URL in `config.json` and the token
   in the secret store, and tells the running gateway to reload, which connects the link
   at once. Adding a link for a base URL that already has one replaces its token.
   `tgw link list` shows the links and their state; `tgw link remove <base_url>` closes a
   link and deletes its token. There is at most one link per base URL; links to different
   base URLs run independently.

3. Revoking the link in Volgenic deletes the hash and closes the socket with code `4401`.

```
$ tgw link add https://volgenic.com vgl_q3Jf…
added link to https://volgenic.com
state     connected since 2026-10-26T14:03:07.412Z

$ tgw link list
base_url              connected  state      since                     last error
https://volgenic.com  yes        connected  2026-10-26T14:03:07.412Z  -

$ tgw link remove https://volgenic.com
removed link to https://volgenic.com
```

## Connection

The gateway connects to `<base_url>/messages/telegram/link`, with the scheme `wss://` for
an `https://` base URL and `ws://` for an `http://` one (`http://localhost:4100` in
development), and sends the token on the upgrade request:

```
GET /messages/telegram/link HTTP/1.1
Host: volgenic.com
Upgrade: websocket
Authorization: Bearer vgl_…
```

| What happens | What the gateway does |
|---|---|
| Volgenic answers the upgrade with `401` (unknown or revoked token) | Stops trying. The link shows `unauthorized` in `tgw link list` and in the log. |
| The open socket is closed with code `4401` (revoked) | The same. |
| Anything else fails: no network, DNS, TLS, another HTTP status, a dropped connection | Tries again after a delay that starts at `1s` and doubles up to `01:00`, each randomised by up to 20% either way. A connection that stayed open for `30s` resets the delay to `1s`. |
| `tgw link add` for the link, or any reload (`tgw daemon reload`) | A link stopped at `unauthorized` tries again; a running link whose token did not change is left alone. |
| `tgw link remove`, or the gateway shutting down | The socket is closed with code `1001`. |

**Keepalive.** Volgenic pings every `30s`, and the gateway answers each ping with a pong.
The gateway also pings every `30s` itself, and drops the connection (then reconnects) when
nothing, neither a frame nor a pong, has arrived for `01:30`. Volgenic does the same on its
side.

## Frames

Every frame is a JSON text frame holding one object with a `type`. Ignore fields and frame
types you do not know; a receiver that sees an unknown `type` drops the frame.

### `hello` (gateway → Volgenic)

The first frame on every connection:

```json
{"type": "hello", "protocol": 1, "gateway_version": "0.1.0", "auth_state": "ready",
 "account": {"id": "123456789", "name": "Ada Lovelace", "username": "ada", "phone": "+15551234567"},
 "head_seq": 4812}
```

| Field | Meaning |
|---|---|
| `protocol` | `1`, this document. |
| `gateway_version` | The gateway's version. |
| `auth_state` | The Telegram sign-in state, as `GET /v1/admin/auth` reports it ([api.md](api.md#health) lists the values). `unknown` when the gateway has no `api_id` / `api_hash`. |
| `account` | `null` unless `auth_state` is `ready`. `id` is the Telegram user id as a string, `name` the first and last name, `username` without `@` (or `null`), `phone` in international form with `+`. |
| `head_seq` | The newest `seq` in the event log, `0` when it is empty. |

### `request` (Volgenic → gateway) and `response`

Volgenic calls the gateway's HTTP API ([api.md](api.md)):

```json
{"type": "request", "id": "r-17", "method": "POST", "path": "/v1/admin/auth/phone",
 "query": {"limit": "50"}, "body": {"phone_number": "+15551234567"}}
```

| Field | Rules |
|---|---|
| `id` | Any string (a number is accepted too); echoed in the response. |
| `method` | `GET`, `HEAD`, `POST`, `PUT`, `PATCH` or `DELETE`. |
| `path` | Starts with `/v1/`. No query string in it: that goes in `query`. |
| `query` | Optional. An object whose values are strings, or arrays of strings for a parameter that repeats (`{"chat_id": ["-100…", "-100…"]}`). Numbers and booleans are sent as written. |
| `body` | Optional. Any JSON value; it becomes the request body with `Content-Type: application/json`. |

The gateway runs the call against its own API in its own process, with the admin token,
through the same authentication, rate limits and error handling that `tgw` meets over
`127.0.0.1`. It answers with the status and the JSON body:

```json
{"type": "response", "id": "r-17", "status": 200, "body": {"auth_state": "wait_code", …}}
```

- An error is an ordinary response with its status and the error body from
  [api.md](api.md#errors): `{"type": "response", "id": "…", "status": 503, "body": {"error": {"code": "not_logged_in", …}}}`.
- A response with no body (`204`, or `HEAD`) has `"body": null`.
- A body that is not JSON (media: `GET /v1/media/{media_id}`) comes as base64, with its
  content type and without `body`:
  `{"type": "response", "id": "…", "status": 200, "content_type": "image/jpeg", "body_base64": "…"}`.
  At most 20 MB (20 971 520 bytes) before base64; a larger file answers `413` with
  `{"error": {"code": "too_large", "message": "…", "details": {}}}`. `Range` requests are not
  available over the link. A media file that is still downloading answers `202` with a JSON
  body, as on the local API: ask again.
- Requests run concurrently and responses arrive in any order; `id` correlates them. The
  gateway never gives up on a request itself (sending waits up to `30s` for Telegram, media
  up to `30s` for the download); a request unanswered after `01:00` is Volgenic's to time
  out.

**What a link may not call.** These answer `403` with
`{"error": {"code": "forbidden_over_link", …}}`, and nothing runs:

- a path that does not start with `/v1/`;
- `/v1/admin/secrets…`, `/v1/admin/tokens…`, or anything else that would reveal or change
  the admin token or another secret;
- `/v1/admin/links…`, the state of this gateway's links, which may include links to other
  Volgenic servers;
- a path with `.` or `..` segments, `//`, a backslash, or a `?` or `#` (also when
  percent-encoded).

`/v1/events/stream` answers `400 invalid_request`: it is a WebSocket, and the link has
`subscribe` for it. An unknown `method` answers `400 invalid_request` too.

### What Volgenic calls

All existing endpoints, specified in [api.md](api.md):

| For | Endpoints |
|---|---|
| Sign-in | `GET /v1/admin/auth`, `POST /v1/admin/auth/{qr,phone,code,password,email,email_code,logout}` |
| Chats and the monitored set | `GET /v1/admin/chats` (with `?all=true` the whole chat list), `GET /v1/admin/folders`, `GET` and `PUT /v1/admin/monitored-chats` |
| History | `GET /v1/chats/{chat_id}/messages?before=…&limit=…` |
| Media | `GET /v1/media/{media_id}` |
| Sending | `POST /v1/chats/{chat_id}/messages` with `{"text", "reply_to"}`: the admin token may send to any monitored chat |
| State | `GET /v1/admin/status`, `GET /v1/health` |

### `subscribe` (Volgenic → gateway) and `event`

```json
{"type": "subscribe", "since": 4700}
```

The gateway sends every event in the event log with `seq > since`, the same events in the
same order as `GET /v1/events/stream` with the admin token, in the format of
[events.md](events.md): first the backlog, then each new event as it is recorded.

```json
{"type": "event", "event": {"v": 1, "seq": 4701, "type": "message.new", …}}
```

- `since` is required, a whole number of `0` or more. `0` means from the oldest event the
  gateway still has.
- If `since` is older than the retained log (events below it were pruned,
  [api.md](api.md#retention)), the gateway first sends
  `{"type": "gap", "oldest_seq": 4750}` and continues from the oldest event it has. The
  missing messages can be read with the history endpoint.
- A new `subscribe` on the same connection replaces the previous one, from its own `since`.
- Subscriptions end with the connection. Volgenic stores the last `seq` it processed and
  subscribes from it after every reconnect; it may receive an event it already processed and
  deduplicates on `seq`.
- There is no `caught_up` or heartbeat frame on the link: compare with `head_seq` from
  `hello`.

### `auth_state` (gateway → Volgenic)

Whenever the sign-in state or the signed-in account changes, so that Volgenic's connect
screen follows it without polling:

```json
{"type": "auth_state", "auth_state": "wait_code", "account": null}
```

`account` has the shape of the one in `hello`. The gateway checks the state every second, so
a change shows within about `1s`. The details of a step (the QR link, where the code was
sent, the password hint) come from `GET /v1/admin/auth`.

### `error` (gateway → Volgenic)

A frame the gateway cannot act on is answered with an `error` frame and otherwise ignored;
the connection stays open:

```json
{"type": "error", "code": "invalid_request", "message": "subscribe needs since, a non-negative integer.", "id": null}
```

This happens for a frame that is not a JSON object, a `request` without an `id` (one with an
`id` is answered with a `response` instead), and a `subscribe` without a valid `since`.

## Link state

`tgw link list`, `tgw health` and the gateway's admin API show each link:

`GET /v1/admin/links` (admin token; not over a link):

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

| `state` | Meaning |
|---|---|
| `connecting` | Opening the WebSocket. |
| `connected` | Open; `hello` was sent. |
| `waiting` | The last attempt failed; the next one is at `retry_at`. |
| `unauthorized` | Volgenic refused the token (`401` or `4401`). No more attempts until `tgw link add` or a reload. |
| `no_token` | `config.json` lists the link but the secret store has no token for it. |
| `stopped` | Closed by the gateway. |

`since` is when the link entered its state. `last_error` is the most recent failure, kept
after the link recovers, with its time in `last_error_at`. `GET /v1/admin/status` carries
the same list under `links`.

## Storage

```json
{"links": [{"base_url": "https://volgenic.com"}]}
```

in `config.json`, and the token in the secret store under the key
`link-token:<base_url>` (`secrets.json` by default, never the Keychain while developing).
The base URL is kept in a canonical form: scheme and host in lowercase, no trailing slash,
no query. Editing `config.json` by hand and running `tgw daemon reload` has the same effect
as `tgw link add` and `remove`, as long as the token is in the secret store.

## Implementation

The `GatewayLink` module holds one `GatewayLinkClient` actor per link and a `LinkManager`
actor that starts, replaces and stops them on reload. The WebSocket client is Foundation's
`URLSessionWebSocketTask`: it needs no new dependency, uses the system's TLS trust store and
proxy settings, sends the `Authorization` header on the upgrade, reports the HTTP status of
a refused upgrade and the close code of a closed socket, and answers Volgenic's pings by
itself. Requests run through `InProcessAPI` in `GatewayServer`, which hands each one to the
gateway's own router with the admin token. Tests replace Volgenic with a WebSocket server on
`127.0.0.1` inside the test process.
