# Integrating an app

This guide covers requesting access, consuming ordered events, persisting a resume cursor,
and handling duplicate deliveries. It is intended for developers building applications
against an existing Telegram Gateway installation.

**The integration provides:** a scoped app token, a WebSocket or webhook consumer, and a
persisted sequence number for resuming retained events. Optional permissions allow access
to earlier message history and media files.

**Prerequisites:**

- A running gateway that is signed in to Telegram, with at least one chat monitored. Setting
  one up is covered in the [README](../README.md).
- Access to the person who runs it, because they approve your app.
- For the examples here: Node 22 or Python 3.12. Any language with an HTTP client works.

In this guide "you" are the developer of an **app**, a program that consumes the gateway.
**The user** is the person who runs the gateway and whose Telegram account it is signed in
to. The developer and account owner may be the same person. Examples use fictional data;
replace sample request IDs and tokens with the values returned by the gateway.

The exact contract is in [api.md](api.md) (endpoints), [events.md](events.md) (what an event
looks like) and [grants.md](grants.md) (what your app may see). This guide links into them.

Durations are written `mm:ss` (or `h:mm:ss`); values under a minute are in seconds.

## Contents

1. [How it works](#how-it-works)
2. [Request access](#request-access)
3. [Poll for approval](#poll-for-approval)
4. [Choose WebSocket or webhooks](#choose-websocket-or-webhooks)
5. [Connect and resume with `since`](#connect-and-resume-with-since)
6. [Handle heartbeats and reconnect](#handle-heartbeats-and-reconnect)
7. [Verify webhook signatures](#verify-webhook-signatures)
8. [Deduplicate on `seq`](#deduplicate-on-seq)
9. [Read history to backfill](#read-history-to-backfill)
10. [Fetch media](#fetch-media)
11. [A complete WebSocket consumer](#a-complete-websocket-consumer)
12. [Checklist](#checklist)
13. [Not supported](#not-supported)

---

## How it works

The **gateway** is a background service on the user's Mac, signed in to Telegram as the
user's own account (not a bot). It watches the chats the user chose, the **monitored chats**,
and turns each message in them into an **event** in its own JSON format. It gives every event
a **sequence number** (`seq`), an integer that only ever increases, and stores the event
before delivering it.

Your app never talks to Telegram. It talks to the gateway at

```
http://127.0.0.1:41414
```

with a **token** the user granted it. It reads events in one of two ways:

- over a **WebSocket**, a persistent connection your app opens to the gateway, or
- at a **webhook**, an HTTPS URL of yours that the gateway posts events to.

Each event has a `seq`. Persist the last successfully processed sequence number as the
app's **cursor** and pass it when reconnecting. Replay is available while the events remain
retained; a pruned cursor returns `410 history_pruned`. Consumers must also deduplicate
deliveries, particularly when a webhook acknowledgement is lost.

Other terms you will meet:

| Term | Meaning |
|---|---|
| **Chat** | Any Telegram conversation: a channel (a broadcast feed), a group, or a private conversation. |
| **Chat id** | Telegram's number for a chat. Always a string in this API, for example `"-1001234567890"`. |
| **Scope** | A kind of access, such as `messages:read`. |
| **Grant** | Your app's approved access: its scopes, its chats and its token. |

All of them are defined in [api.md](api.md#conventions) and [grants.md](grants.md).

Check that the gateway is up before anything else:

```
GET http://127.0.0.1:41414/v1/health
```

`"status": "ok"` means it is signed in and connected. `"degraded"` with a `tdlib.auth_state`
other than `ready` means the user has not signed in to Telegram yet: stored events can still
be read, but nothing new arrives.

---

## Request access

Choose the scopes you need from the table in [grants.md](grants.md#scopes), and ask for the
fewest that will do. Then:

```http
POST /v1/access-requests
Content-Type: application/json

{
  "name": "Community Analytics",
  "description": "Classifies messages in product channels and counts topics per day.",
  "scopes": ["messages:read", "history:read", "chats:read"],
  "requested_chats": "any"
}
```

The response contains `request_id` and `poll_url`.

- The user now sees your request in the gateway's menu bar app, with your name and
  description. Write the description for them: one sentence that says what your app does
  with the messages.
- `requested_chats` is a suggestion. If you know the chat ids you want, list them, and the
  user sees them by title. Otherwise send `"any"` and the user picks.
- Add `"webhook": { "url": "https://…" }` if you will use a webhook (see
  [Choose WebSocket or webhooks](#choose-websocket-or-webhooks)).

The API listens only on the Mac that runs the gateway. If your app runs elsewhere, make this
request and the polling below from that Mac, for example with `curl`:

```sh
curl -s http://127.0.0.1:41414/v1/access-requests \
  -H 'Content-Type: application/json' \
  -d '{"name":"Community Analytics","description":"Classifies messages in product channels and counts topics per day.","scopes":["messages:read","chats:read"],"webhook":{"url":"https://analytics.example.com/tgw/events"}}'
```

---

## Poll for approval

```http
GET /v1/access-requests/{request_id}
```

Poll every 3s, and no faster than once per 2s, until `status` is no longer `pending`. A
request expires after `15:00`. If you get `expired`, create a new request.

On `approved`, the response contains:

- `token`: your app token.
- `grant`: what you were given. It may be less than you asked for, so read `grant.scopes`
  and `grant.effective_chat_ids`.
- `webhook.secret`, if you registered a webhook.

**Store `token` and `webhook.secret` immediately.** They are shown for `10:00` after
approval and never again ([Storing the token](grants.md#storing-the-token)).

From now on, every request carries:

```
Authorization: Bearer tgw_…
```

Confirm with `GET /v1/me`, which returns your grant, and with `GET /v1/chats` (needs
`chats:read`), which lists your chats by title.

---

## Choose WebSocket or webhooks

| | WebSocket (`GET /v1/events/stream`) | Webhook (the gateway posts to you) |
|---|---|---|
| Where your app runs | On the same Mac as the gateway. The API is reachable only there. | Anywhere the Mac can reach over HTTPS. |
| Who keeps the cursor | **You.** Pass `since` when connecting; store it after processing. | **The gateway.** It advances when you answer `2xx`. |
| Latency | Lowest: events are pushed as they are recorded. | Up to 500 ms of batching, plus your HTTP round trip. |
| When your app is down | Nothing happens. You replay from `since` when you are back. | The gateway retries for `24:00:00`, then pauses the webhook until it is resumed. |
| Ordering | In `seq` order per connection. | In `seq` order per grant, one delivery at a time. |
| Duplicates arise | When you reconnect before storing the cursor. | When your `2xx` is lost, and when the gateway restarts mid-delivery. |
| You build | A reconnect loop and a stored cursor. | An HTTPS endpoint, signature verification, idempotent handling. |
| Older events | Connect with an earlier `since`. | The cursor starts at the head of the log when the webhook is created. Read older events once with `GET /v1/events`, from the Mac. |
| History and media endpoints | Available. | Available only from the Mac. An app on another machine receives events, including media descriptions, but cannot call the API for past messages or file bytes. |
| Suits | Local services and command-line tools; development. | Servers elsewhere, serverless functions, anything that should not hold a socket open. |

In short: on the Mac, use the WebSocket; anywhere else, use a webhook.

Both deliver **at least once, in order**, so deduplicate on `seq` either way. One grant can
use both at once; their cursors are independent.

---

## Connect and resume with `since`

`since` is exclusive: you receive events with a `seq` **greater than** it. Store the `seq` of
the last event you fully processed. That is exactly the value to send next time.

On the first run you have no cursor. Choose one:

| You want | Connect with | What happens |
|---|---|---|
| Only new events | no `since` | The first frame is `caught_up` with the current head of the log. Store that `seq` as your cursor. |
| Everything the gateway holds | `since=0` | The backlog is streamed in order, which can take a while, and then `caught_up` follows. |
| To continue from a known point | `since=<seq>` | Events after that point, then `caught_up`. |

**Webhooks have no `since`.** The gateway starts your cursor at the head of the log when the
webhook is registered. To read older events, call `GET /v1/events?since=0&limit=1000` in a
loop, following `next_since` while `has_more` is true. Doing this before or after
registering is equally safe, because deduplicating on `seq` absorbs the overlap.

**If the events you ask for are gone.** The user can prune old events. When `since` points
below the oldest retained event you get `410 history_pruned` (HTTP), or an error frame
followed by close code `4410` (WebSocket), with `details.oldest_seq`. Record the gap, set
your cursor to `oldest_seq - 1` so that the oldest retained event is the next one you
receive, and if the gap matters, fill it from history
([Read history to backfill](#read-history-to-backfill)).

**Paged reads, for batch jobs** that do not hold a socket:

```http
GET /v1/events?since=4700&limit=1000
```

```json
{ "events": [ … ], "has_more": true, "next_since": 5700, "head_seq": 9100 }
```

Repeat with `since=<next_since>` until `has_more` is false. `head_seq - next_since` bounds
how far behind you are.

---

## Handle heartbeats and reconnect

The WebSocket carries four kinds of frame ([api.md](api.md#get-v1eventsstream-websocket)):

```json
{ "type": "event", "event": { "seq": 4810, … } }
{ "type": "caught_up", "seq": 4812 }
{ "type": "heartbeat", "seq": 4812, "time": "2026-09-29T14:03:37.001Z" }
{ "type": "error", "code": "history_pruned", "message": "…", "details": { "oldest_seq": 4000 } }
```

**Liveness.** The gateway sends a heartbeat after every 30s of silence. If no frame of any
kind arrives for `01:30`, the connection is dead: close it and reconnect with your stored
cursor as `since`.

**Backoff.** Wait 1s, then 2s, then 4s, doubling up to 30s, with random jitter. A restart
of the gateway (close code `1001`) disconnects every local app at the same moment, and
jitter keeps them from all returning at once.

**Close codes.** Most mean "reconnect". These do not:

| Code | Meaning | What to do |
|---|---|---|
| `4499` | Your grant was revoked while you were connected. | Stop, and tell a person. Only the user can restore access. |
| `4401` | The token is missing, invalid or revoked. An error frame names which. | Stop. Reconnecting cannot succeed. |
| `4403` | Your grant has neither `messages:read` nor `chats:read`. | Stop. There is nothing to stream. |
| `4400` | Your query string is invalid. An error frame says why. | Stop, and fix the request. |
| `4409` | Too many connections for this token (the limit is 4). | Stop. Your app is leaking connections. |
| `4410` | The events after your `since` were pruned. | Move your cursor to `oldest_seq - 1`, then reconnect. |

The full list is in [api.md](api.md#close-codes).

**Unknown frames and events.** Ignore frames whose `type` you do not know, and events whose
`event.type` you do not know. The format grows by addition
([events.md](events.md#versioning)).

---

## Verify webhook signatures

Every delivery carries `X-TGW-Signature: sha256=<hex>`: the HMAC-SHA256 of the **raw request
body bytes**, keyed with your webhook secret. Verify it before parsing the JSON, over the
exact bytes received rather than a re-serialisation, with a constant-time comparison. On a
mismatch, answer `401` and do not process the body.

TypeScript (Node 22, built-in `crypto`):

```ts
import { createHmac, timingSafeEqual } from "node:crypto";

export function verifyTgwSignature(rawBody: Buffer, header: string | undefined, secret: string): boolean {
  if (!header?.startsWith("sha256=")) return false;
  const expected = createHmac("sha256", secret).update(rawBody).digest();
  const given = Buffer.from(header.slice("sha256=".length), "hex");
  return given.length === expected.length && timingSafeEqual(given, expected);
}
```

Python 3.12:

```python
import hmac, hashlib

def verify_tgw_signature(raw_body: bytes, header: str | None, secret: str) -> bool:
    if not header or not header.startswith("sha256="):
        return False
    expected = hmac.new(secret.encode(), raw_body, hashlib.sha256).hexdigest()
    return hmac.compare_digest(header[len("sha256="):], expected)
```

Make sure your framework hands you the raw body. In Express, use
`express.raw({ type: "application/json" })` on that route, not `express.json()`. In FastAPI,
use `await request.body()`.

Then process the batch, `body.events`, in order, and answer `2xx` **within 10s**. If
processing can take longer, store the batch and answer `200` first: the gateway needs to know
only that you accepted it. A failed or late answer is retried on the schedule in
[api.md](api.md#retry-schedule).

To make the gateway stop sending, for maintenance or a migration, answer `410`. The webhook
pauses at once and stays paused until it is resumed with `POST /v1/me/webhook/resume` or by
the user.

---

## Deduplicate on `seq`

Both the WebSocket and webhooks deliver at least once. Every event's `seq` is unique, and
the events you receive arrive in increasing `seq`, so deduplication is one comparison:

```
if event.seq <= cursor: skip
else: process(event); cursor = event.seq; store(cursor)
```

Store the cursor **after** processing, so that a crash between the two replays the event
instead of losing it.

If processing is not idempotent, for example it increments a counter, make the two steps
atomic: write the counter and the cursor in one transaction, or key the counter by `seq` so
that a repeated write changes nothing.

`seq` is numbered across the whole gateway, so your app sees gaps. A gap is not a lost event.
Only a `seq` you have already processed arriving again is a duplicate.

---

## Read history to backfill

Events begin when the user started monitoring a chat. For anything earlier, such as last
quarter's messages for an analytics baseline, use history. It reads the chat's timeline from
Telegram itself and needs the `history:read` scope.

```http
GET /v1/chats/-1001234567890/messages?limit=100
```

This returns the 100 newest messages, newest first, each in the same
[message object](events.md#message-object) shape as in `message.new`, together with
`next_before`. To walk backwards:

```
before = None
while True:
    page = GET /v1/chats/{id}/messages?limit=100[&before=before]
    for m in page.messages: upsert(m)      # keyed by (chat_id, id)
    if not page.has_more: break
    before = page.next_before
    # stay under 60 requests per minute
```

- Stop when you reach the date you care about. `has_more` is true whenever a full page came
  back, so the very last request may return an empty page.
- Key your storage by `(chat_id, message.id)`, not by `seq`: history has no `seq`. Let
  `message.new` and `message.edited` events upsert into the same table, and the two sources
  merge cleanly.
- Backfill once per chat and record that you did. Do it again for a chat when you receive
  `monitoring.started` for it.

---

## Fetch media

If a message has media, `media[0].media_id` identifies the file. With the `media:read`
scope:

```http
GET /v1/media/med_3fK9pQ2mR7tV1wX5yZ8aB4cD6eF0gH2j
```

| Response | Meaning | What to do |
|---|---|---|
| `200` | The bytes, with `Content-Type` and `Content-Disposition`. | Store them under your own key. The response is immutable, so you never need the same `media_id` twice. |
| `202` with `Retry-After: 5` | The gateway is still downloading the file from Telegram. | Wait and request again. Each request waits up to 30s while the download runs. |
| `410 media_gone` | Telegram no longer supplies the file. | Record that and move on. |
| `403 chat_not_granted` | The media belongs to a chat outside your grant. | Do not retry. |
| `429 rate_limited` | More than 4 uncached downloads are running for your token. | Queue, and retry after `Retry-After`. |

Fetch lazily, and only the kinds you use (`kind` in the
[media object](events.md#media-object)). Photos in a busy channel add up.

---

## A complete WebSocket consumer

Node 22 and TypeScript, with one dependency (`ws`). It stores its cursor in a file, resumes
with `since`, reconnects with backoff, treats `01:30` of silence as a dead connection,
deduplicates on `seq`, and stops when reconnecting cannot succeed. It reads `TGW_TOKEN` from
the environment; `TGW_URL` and `TGW_CURSOR_FILE` are optional.

```ts
// consumer.ts — run with: pnpm add ws @types/ws && pnpm dlx tsx consumer.ts
import WebSocket from "ws";
import { readFile, writeFile, rename } from "node:fs/promises";

const BASE = process.env.TGW_URL ?? "http://127.0.0.1:41414";
const TOKEN = process.env.TGW_TOKEN ?? (() => { throw new Error("TGW_TOKEN is required"); })();
const CURSOR_FILE = process.env.TGW_CURSOR_FILE ?? "./tgw.cursor";
const DEAD_AFTER_MS = 90_000; // 01:30 without any frame

// Close codes after which reconnecting cannot succeed (docs/api.md, "Close codes").
const STOP_CODES: Record<number, string> = {
  4400: "the query string is invalid",
  4401: "the token is missing, invalid or revoked",
  4403: "the grant has neither messages:read nor chats:read",
  4409: "too many connections for this token",
  4499: "the grant was revoked",
};

type GatewayEvent = { v: number; seq: number; type: string; [k: string]: unknown };
type EventFrame = { type: "event"; event: GatewayEvent };
type Frame =
  | EventFrame
  | { type: "caught_up"; seq: number }
  | { type: "heartbeat"; seq: number; time: string }
  | { type: "error"; code: string; message: string; details?: { oldest_seq?: number } };
// Frames of a type not listed here reach the `default` branch below and are ignored.

async function loadCursor(): Promise<number | null> {
  try { return Number(await readFile(CURSOR_FILE, "utf8")) || null; } catch { return null; }
}

async function saveCursor(seq: number): Promise<void> {
  await writeFile(`${CURSOR_FILE}.tmp`, String(seq), "utf8");
  await rename(`${CURSOR_FILE}.tmp`, CURSOR_FILE); // atomic replace
}

// Replace with your own work. Must be safe to call twice with the same event.
async function handle(frame: EventFrame): Promise<void> {
  const e = frame.event;
  if (e.type === "message.new") {
    const msg = e.message as { chat_id: string; id: string; text: string };
    console.log(`#${e.seq} ${msg.chat_id}/${msg.id}: ${msg.text.slice(0, 80)}`);
  }
  // Unknown event types are ignored on purpose: the format grows by addition.
}

function connectOnce(cursor: number | null): Promise<"reconnect" | "stop"> {
  return new Promise((resolve) => {
    const url = new URL("/v1/events/stream", BASE.replace(/^http/, "ws"));
    if (cursor !== null) url.searchParams.set("since", String(cursor));

    const ws = new WebSocket(url, { headers: { Authorization: `Bearer ${TOKEN}` } });
    let last = cursor ?? 0;
    let queue: Promise<void> = Promise.resolve(); // process frames strictly in order
    let deadTimer: NodeJS.Timeout | undefined;
    const alive = () => {
      clearTimeout(deadTimer);
      deadTimer = setTimeout(() => { console.error("no frames for 01:30, reconnecting"); ws.terminate(); }, DEAD_AFTER_MS);
    };

    ws.on("open", () => { console.error(`connected, since=${cursor ?? "(live)"}`); alive(); });

    ws.on("message", (data) => {
      alive();
      const frame = JSON.parse(data.toString()) as Frame;
      queue = queue.then(async () => {
        switch (frame.type) {
          case "event":
            if (frame.event.seq <= last) return;      // duplicate after a reconnect
            await handle(frame);
            last = frame.event.seq;
            await saveCursor(last);                   // store AFTER processing
            return;
          case "caught_up":
            if (cursor === null) { last = frame.seq; await saveCursor(last); } // live-only start
            console.error(`caught up at seq ${frame.seq}`);
            return;
          case "heartbeat":
            return;
          case "error":
            console.error(`gateway error ${frame.code}: ${frame.message}`);
            if (frame.code === "history_pruned" && frame.details?.oldest_seq) {
              // Accept the gap: `since` is exclusive, so the oldest retained event comes next.
              last = frame.details.oldest_seq - 1;
              await saveCursor(last);
            }
            return;
          default:
            return; // unknown frame type: ignore
        }
      }).catch((err) => { console.error("handler failed, reconnecting", err); ws.terminate(); });
    });

    ws.on("close", (code) => {
      clearTimeout(deadTimer);
      queue.finally(() => {
        const reason = STOP_CODES[code];
        if (reason) { console.error(`closed (${code}): ${reason}; stopping`); resolve("stop"); return; }
        console.error(`closed (${code})`);
        resolve("reconnect");
      });
    });

    ws.on("error", (err) => console.error("socket error", err.message));
  });
}

async function main(): Promise<void> {
  let backoffMs = 1000;
  for (;;) {
    const cursor = await loadCursor();
    const startedAt = Date.now();
    const outcome = await connectOnce(cursor);
    if (outcome === "stop") process.exit(1);
    if (Date.now() - startedAt > 60_000) backoffMs = 1000; // it was healthy for a while
    const jitter = Math.random() * backoffMs;
    await new Promise((r) => setTimeout(r, backoffMs + jitter));
    backoffMs = Math.min(backoffMs * 2, 30_000);
  }
}

main().catch((err) => { console.error(err); process.exit(1); });
```

Two things it leaves to you:

- Call `GET /v1/me` at start and after each `monitoring.*` event, to know which chats you
  currently cover.
- Handle `SIGTERM` by letting the handler in progress finish before exiting. A hard kill is
  still safe, because the cursor is written only after a handler completes, so the event is
  replayed.

---

## Checklist

Your integration is correct when:

- [ ] It requests only the scopes it uses, with a description the user can understand.
- [ ] It stores the token and the webhook secret the instant it sees `status: "approved"`.
- [ ] It reads `grant.effective_chat_ids` and `grant.scopes` from the gateway instead of
      assuming it got what it asked for.
- [ ] It stores the last processed `seq` after processing, atomically with any side effect
      that is not idempotent, and sends it as `since` when connecting.
- [ ] Killing it at any moment and restarting it loses no event and counts none twice.
- [ ] It ignores any `seq` it has already processed, on the WebSocket and on the webhook.
- [ ] It treats `01:30` without a frame as a dead connection and reconnects with backoff
      and jitter.
- [ ] It stops and alerts a person on close codes `4499` and `4401` and on
      `401 token_revoked`.
- [ ] It handles `history_pruned` by moving its cursor to `oldest_seq - 1`, and backfills
      from history if the gap matters.
- [ ] Its webhook endpoint verifies `X-TGW-Signature` over the raw body with a constant-time
      comparison, answers `2xx` within 10s, and is idempotent per `seq`.
- [ ] It ignores unknown fields, unknown event types and unknown enumeration values.
- [ ] It compares ids as strings and never parses them as numbers.
- [ ] It treats entity offsets as UTF-16 code units.
- [ ] Its history backfill is keyed by `(chat_id, message.id)` and merges with live events.
- [ ] It fetches each `media_id` at most once, and handles `202` and `410`.
- [ ] It calls `GET /v1/me` again after `monitoring.started` and `monitoring.stopped`, and
      backfills a newly covered chat if it needs the past.
- [ ] Nothing it logs contains the token or the webhook secret.

---

## Not supported

| You cannot | Because |
|---|---|
| Show "typing…", join or leave groups and channels, or edit or delete other people's messages | The gateway does none of these. Marking a chat read when your user opens it needs `messages:mark_read` ([api.md](api.md#marking-as-read)), and only then. What an app can do as the user is listed in [api.md](api.md#message-and-chat-actions): send text and files, forward, edit and delete the user's own messages, react and vote with `messages:send`, and pin, archive, mute and start chats with `chats:manage`. |
| Open the WebSocket, or call history and media endpoints, from another machine | The API listens on `127.0.0.1` only. Apps elsewhere receive events through a webhook. |
| Call the API from a web page | The gateway sends no CORS headers, and browsers cannot set the `Authorization` header on a WebSocket. |
| Receive view counts | They are not in the event format ([events.md](events.md#not-supported)). |
| Change your grant's scopes or chats | The user revokes it, and you request access again. |

The complete list is in [api.md](api.md#not-supported).
