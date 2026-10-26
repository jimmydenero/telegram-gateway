# Architecture

How Telegram Gateway is put together and why it has the shape it has. For building an app
against it, start with [integrating.md](integrating.md); for building and running the
gateway itself, [development.md](development.md).

Words used throughout: **the user** is the person who runs the gateway and whose Telegram
account it is logged in to. An **app** is a program that consumes messages from the gateway,
and may send messages through it if the user allows.
**The gateway** is the running service.

## What the gateway is for

Telegram Gateway gives any number of apps a reliable stream of messages from chosen chats,
as seen by a user account rather than a bot, with one login in one place. Bots cannot be
added to every channel and do not see what a member sees; a user account does, but logging
one in is sensitive and Telegram's client library keeps its state in files that only one
process can use. The gateway is that one process: it holds the login, watches the chats the
user picks, records every new, edited and deleted message as an event in its own format, and
hands those events to the apps the user has approved — over WebSocket, webhooks or plain
HTTP — so that no app has to integrate with Telegram or ever see the user's credentials.

## The pieces

![Inside the gateway, TDLib feeds the translator, which writes numbered events to the event log; delivery sends each app what its grant allows. Telegram connects to TDLib over MTProto. The menu bar app and tgw use the admin token and apps use app tokens, both on 127.0.0.1:41414.](images/architecture.png)

### The gateway service

`GatewayDaemon` is a background process run by **launchd**, the macOS service manager, as a
**LaunchAgent**: a service that runs as the logged-in user, starts at login and is restarted
if it exits. It runs as the user, not as a system daemon, because it needs the user's files
and, in a signed release, the user's login Keychain.

It is the only process that loads **TDLib**, Telegram's official client library. It:

- holds the Telegram login and answers the login steps (QR code, or phone number, code and
  two-step password) on behalf of whichever admin client is driving them;
- keeps the **monitored set**, the chats and chat folders the user chose to watch;
- translates each TDLib update for a monitored chat into an event in the gateway's own
  format ([events.md](events.md)) and appends it to the **event log**, a SQLite table in
  which every event gets the next **sequence number**;
- serves the HTTP and WebSocket API ([api.md](api.md)) on `127.0.0.1`, port 41414 by default;
- delivers webhooks to apps that registered one;
- keeps the links to Volgenic open, if the user made any (below);
- downloads media on request and caches it.

Apps never see TDLib's JSON. The event format belongs to the gateway, so upgrading TDLib
cannot break an app.

### The menu bar app

A SwiftUI application ([app.md](app.md)) and the normal way to operate the gateway. It is a
client of the API with the admin token and never loads TDLib itself. With it the user starts
the gateway, signs in to Telegram, picks the monitored chats, approves or denies apps'
access requests, revokes access, and sees what is being delivered. Quitting the app does not
stop a gateway that launchd runs.

### The tgw command-line tool

`tgw` does the same administration from a terminal, over the same API with the same admin
token: install the LaunchAgent, show health, change the monitored set, approve and revoke,
tail the event stream. Every capability exists here before it exists in the app, which keeps
the API complete and makes the gateway usable on a machine with no app installed.
[development.md](development.md) has the command reference.

### The link to Volgenic

**Volgenic** is a web application whose Messages tab works on top of a gateway. Volgenic runs
on the internet and the gateway listens only on `127.0.0.1`, so Volgenic cannot connect in.
Instead the user runs `tgw link add <base_url> <token>` with the command Volgenic shows, and
the gateway dials out: it opens one WebSocket to `<base_url>/messages/telegram/link` and
keeps it open, reconnecting after every drop. Over it Volgenic sends HTTP requests in
frames, which the gateway runs through its own router in the same process with the admin
token, exactly as `tgw` would, and subscribes to the event log from its own cursor. The
gateway also tells it when the sign-in state changes. [link.md](link.md) specifies the
protocol.

Each link is one actor in the `GatewayLink` module, independent of the others; the gateway
may have one per Volgenic server. Links are listed in `config.json` with their tokens in the
secret store, and a reload starts, restarts or closes them in place. A link can do whatever
the admin token can except reach secrets, tokens or other links, and Volgenic stops it for
good by revoking its token.

### The TDLib build

The repository builds `libtdjson.dylib` from the TDLib commit recorded in
`vendor/tdlib/COMMIT` for reproducible builds. OpenSSL is linked statically, so the library
depends on nothing outside macOS. TDLib's JSON interface is four C functions; Swift calls
them directly through a small C module, with no bridge process and no third-party binding.

The gateway identifies itself to Telegram with its own `api_id` and `api_hash`, a pair that
identifies a client program and is registered by the gateway operator. Configure a pair
registered for this client application.

## How a message travels

1. Someone posts in "Acme Product Updates", a channel the user monitors. Telegram pushes the
   message to TDLib, which hands the gateway an `updateNewMessage`.
2. The gateway checks the chat against the monitored set. A message in any other chat stops
   here: it is never written to the gateway's store.
3. The translator resolves the sender and the chat, converts ids, picks out text, entities
   and media, and produces a `message.new` event.
4. The event is appended to the event log and gets sequence number 4810. Only now is it
   eligible for delivery.
5. Every open WebSocket whose grant covers that chat receives the event. Every webhook whose
   grant covers it gets the event in its next batch. An app that was offline finds it later
   with `GET /v1/events?since=…`.

## How a message is sent

1. An app holding `messages:send` posts `{"text": "…"}` to
   `/v1/chats/-1001987654321/messages`. The gateway checks the scope, that the grant is still
   in force, that the chat is granted and monitored, the text and the app's sending rate.
2. It calls TDLib's `sendMessage`. TDLib answers at once with a temporary copy of the message,
   under a local id, marked as still being sent.
3. Telegram's servers store the message. TDLib reports `updateMessageSendSucceeded`, with the
   message's final id, or `updateMessageSendFailed` with Telegram's reason.
4. The monitor records the confirmed message as `message.new` with `is_outgoing: true`, as it
   does for messages the user sends from their phone. The temporary copy is never recorded.
5. The `MessageSender`, which sees the same update after the monitor, answers the app with
   `201` and the message, or with `502 send_failed`. With no verdict within `30s` it answers
   `504 send_timeout`; the message may still go out, and would then appear as `message.new`.

`tgw send` takes the same path with the admin token, and so does a send that Volgenic asks
for over a link.

## Why exactly one process owns TDLib

TDLib keeps its state in a directory, and that directory cannot be shared:

| Part of TDLib's directory | Shareable? |
|---|---|
| `td.binlog`, the append-only log that holds the login session | **No.** It is locked by the running instance; a second instance fails to start or corrupts it. |
| `db.sqlite`, TDLib's cache of chats and messages | **Not usefully.** It is encrypted, and its rows are TDLib's internal binary serialization, undocumented and different between versions. |
| `files/`, downloaded media | Yes, read-only. Plain files. |

So the gateway owns TDLib and everything else goes through the API. A lock file
(`daemon.lock`) enforces it on one machine: whoever opens TDLib holds the lock, and a second
gateway, or a `tgw` command that would open TDLib directly, refuses to start and says who
holds it. Media reaches apps as gateway URLs rather than file paths, so an app on another
machine works the same way as a local one.

## Data on disk

Everything lives in one directory, `~/Library/Application Support/TelegramGateway/` unless
`TGW_HOME` points elsewhere:

```
config.json      port, retention, media cache size, api_id / api_hash, secrets backend, links
secrets.json     the admin token, TDLib's database key and the link tokens (mode 0600)
gateway.sqlite   the gateway's store: monitored set, chat and folder cache, event log,
                 per-chat cursors, access requests, grants, webhook deliveries, media index
tdlib/           TDLib's own directory: td.binlog, db.sqlite (encrypted), files/
logs/            the gateway's log when launchd runs it
daemon.lock      held by the process that owns TDLib
```

The event log holds the full content of every message in a monitored chat, in the clear.
By default it is kept forever; `events_retention_days` in `config.json` or the prune
endpoint bounds it. Messages in chats that are not monitored exist only in TDLib's encrypted
cache.

## The access model

Two sets determine what an app receives, and [grants.md](grants.md) explains them fully.

- The **monitored set** is global: the chats the gateway watches at all. Only the user
  changes it.
- A **grant** is one app's access: a token, a set of **scopes** (kinds of data:
  `messages:read`, `history:read`, `media:read`, `chats:read`, and the one action,
  `messages:send`) and a set of chats, given either as a list or as a Telegram chat folder.

What an app can see at any moment is its granted chats intersected with the monitored set,
computed when it asks. Un-monitoring a chat removes it from every app at once; adding a chat
to a granted folder on the phone extends access without another approval.

An app obtains its grant by asking: it posts an **access request** with its name, a
description and the scopes it wants, the user approves it in the menu bar app (or with
`tgw`), narrowing chats and scopes as they see fit, and the app, polling, receives its
token. No browser, no redirect, and the app never handles Telegram credentials. Revoking a
grant takes effect immediately on HTTP, WebSocket and webhooks.

## Delivery guarantees

- **Stored before delivered.** An event is in the log, with its sequence number, before any
  app hears of it. Sequence numbers are positive, strictly increasing and never reused.
- **Resumable.** The sequence number is the app's cursor. An app that reconnects with
  `since=<last seq it processed>` receives everything after it, however long it was away, as
  long as the events have not been pruned. If they have, the gateway says so explicitly
  (`410 history_pruned`) rather than skipping silently.
- **Ordered.** Within what one app may see, events arrive in sequence order on every
  transport.
- **Backfill after gaps.** After the Mac sleeps or loses its connection, TDLib may not replay
  every message a busy chat received meanwhile. The gateway keeps, per monitored chat, the
  id of the last message it has seen, and when the connection returns it reads the chat's
  history from that point forward and records what it missed. Such events are late
  (`recorded_at` is after `occurred_at`), not lost.
- **Webhooks are at least once, in order.** One delivery per app is in flight at a time; a
  failed delivery is retried on a fixed schedule with the same delivery id, and the next
  batch is not sent until it succeeds. After `24:00:00` of failure the webhook pauses and
  keeps its cursor; resuming continues where it stopped. A success the gateway never hears
  about is sent again, so apps dedupe on sequence number.
- **WebSocket leaves the cursor to the app.** There is no acknowledgement; the app persists
  the last sequence number it processed and passes it back on reconnect.
- **History reaches further back.** Events exist from the moment a chat is monitored.
  Anything earlier is read from Telegram on demand through the history endpoint, which needs
  its own scope.

## What the gateway does not do

- **It sends messages only when asked.** The account is a real personal account, so sending
  is the one action the gateway takes, and only on request: from the user with `tgw send` or
  through the Volgenic account they linked, or from an app the user granted `messages:send`,
  always to a monitored chat. It sends plain
  text and nothing else, and never on its own initiative.
- **It does not mark anything as read and does not appear online.** It never calls the TDLib
  functions that count as viewing a chat, and it tells Telegram the account is offline. The
  user's own Telegram apps behave as if the gateway did not exist.
- **It does not join or leave chats**, and it never creates an account.
- **It does no analysis.** No classification, search or statistics: that is what apps are for.
- **It serves one Telegram account** per data directory.
- **It runs on macOS on Apple silicon only.**
- **It does not accept connections from other machines.** Apps elsewhere use webhooks. A
  link to Volgenic is a connection the gateway makes itself, to a server the user named.
- **It does not expose everything Telegram has.** Reactions, polls' contents, read state,
  forum topics and secret chats are outside the event format; [events.md](events.md) lists
  what is included.

## Security model

**Loopback only.** The API listens on `127.0.0.1` and never on another interface. There is
no TLS on the API because nothing leaves the machine except webhooks, which go to `https`
URLs the user saw when approving the app (plain `http` is accepted only for loopback URLs),
and the links to Volgenic, which the gateway opens itself. The API does
not provide Cross-Origin Resource Sharing (CORS) headers for browser clients. This is not
an authentication boundary; tokens and grants control access to protected endpoints.

**Every request carries a token**, except the health check and the two endpoints an app
uses to ask for access. Any local process can connect to the port; what it can do depends
on the token it holds.

- An **app token** can read what its grant allows and nothing else. It cannot list chats
  outside the grant, cannot tell an ungranted chat from a nonexistent one, and cannot widen
  itself.
- The **admin token** can do everything: drive the Telegram login and logout, change the
  monitored set, approve and revoke grants, and read every monitored chat's events, history
  and media, and send messages as the user to every monitored chat (`tgw send` does this).
  Treat it as equivalent to the user's own access to everything the gateway monitors. There is exactly one; the menu bar app and
  `tgw` read it from the secret store.

**Tokens are stored as SHA-256 hashes.** The gateway cannot show an app its token again. Two
narrow exceptions: an approved app's token sits in its access request for the `10:00`
during which the app may collect it, then is erased; and each webhook's signing secret is
stored as is, because the gateway must sign every delivery with it.

**Secrets live in a file by default, in the Keychain for a signed release.** The admin token
and the key that encrypts TDLib's database are kept in `secrets.json`, readable only by the
user's account (mode 0600). The macOS Keychain ties each item to the code signature of the
program that stored it, and a locally built, ad-hoc-signed binary has a new signature after
every rebuild, so every read would stop to ask for the login password. A release signed
with a stable identity does not have that problem and can opt in with
`"secrets": "keychain"` in `config.json`. Either way, the boundary is the user's macOS
account: a process running as the user can read the admin token, and with it everything the
gateway monitors.

**Links act as the admin.** A link to Volgenic carries requests that run with the admin
token, so whoever controls that Volgenic account can do what the admin token does: sign the
gateway in and out, change the monitored set, approve apps, read everything monitored and
send messages as the user. What it cannot do is reach secrets, the admin token or other
links: those paths are refused before any route runs ([link.md](link.md)). The link token
authenticates the gateway to Volgenic, and Volgenic keeps only its hash; the gateway keeps
it in the secret store. The connection to an `https://` base URL is TLS, checked against the
system's trust store.

**Webhooks are signed.** Each delivery carries an HMAC-SHA256 of the exact body under the
webhook's secret, so the receiving app can verify that it came from the gateway.

**Nothing unmonitored is stored or served.** The gateway's own database never contains a
message from a chat outside the monitored set, and no response, including error messages,
reveals that such a chat exists.
