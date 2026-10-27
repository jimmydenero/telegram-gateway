# Development

How to build, test and run the gateway from source, and how to administer it with `tgw`.
Everything here is for macOS on Apple silicon. Durations are written `mm:ss`; values under a
minute as seconds. [architecture.md](architecture.md) explains how the parts fit together.

## Terms

- **TDLib** — Telegram's official client library (C++). It speaks Telegram's protocol, keeps
  the login and a local cache of chats and messages, and exposes a JSON interface of four C
  functions. This repository builds it from source as `libtdjson.dylib`.
- **api_id / api_hash** — the identity of a client program with Telegram: a number and a hex
  string. They identify the software, not an account, and you register your own pair.
- **binlog** — `td.binlog`, TDLib's append-only log in its data directory. It holds the login
  session. Only one process may have it open.
- **launchd** — the macOS service manager. A **LaunchAgent** is a launchd service that runs
  as the logged-in user, starts at login and is restarted if it exits.
- **The gateway** — the running service, the executable `GatewayDaemon`. It owns TDLib,
  records events and serves the API in [api.md](api.md).
- **tgw** — the command-line tool. Most of its commands administer a running gateway over
  the API; a few open TDLib directly for debugging and refuse to run while the gateway is up.
- **TGW_HOME** — the data directory, `~/Library/Application Support/TelegramGateway` unless
  the environment variable of that name says otherwise.
- **Link** — an outbound WebSocket from the gateway to a Volgenic server, over which that
  Volgenic account drives the gateway ([link.md](link.md)). Managed with `tgw link`.

## Prerequisites

| What | How to get it |
|---|---|
| Xcode 26 (Swift 6.3) | App Store or developer.apple.com |
| cmake, gperf | `brew install cmake gperf` |
| OpenSSL 3 | `brew install openssl@3` (needed at build time only; linked statically) |

The package targets macOS 15 or later. Its Swift dependencies are fetched by SwiftPM:
Hummingbird 2 (HTTP and WebSocket), GRDB 7 (SQLite), swift-argument-parser, swift-log and
swift-service-lifecycle.

## Build TDLib

```
./vendor/tdlib/build.sh
```

The script clones `tdlib/td` at the commit in `vendor/tdlib/COMMIT` into `vendor/tdlib/src`,
builds the `tdjson` target for arm64 in Release mode, installs it into `vendor/tdlib/lib`
and `vendor/tdlib/include`, and prints the path of the dylib. All of those directories are
git-ignored.

- OpenSSL is linked statically, so the dylib depends only on libraries in `/usr/lib`. The
  script checks this with `otool -L` and fails if anything under `/opt/homebrew` is
  referenced.
- The dylib's install name is its absolute path, so the binaries `swift build` produces find
  it without `DYLD_LIBRARY_PATH`. If you move the repository, run the script again.
- Re-running is cheap: an existing checkout at the right commit and an existing build tree
  are reused. Delete `vendor/tdlib/build` to rebuild, `vendor/tdlib/src` to clone again.
- It uses 18 parallel jobs by default; `JOBS=8 ./vendor/tdlib/build.sh` changes that.

A clean TDLib build takes approximately 02:00 on recent Apple silicon; timings vary by
hardware. An unchanged build reuses the existing outputs.

## Build and test

```
swift build              # debug: .build/debug/GatewayDaemon and .build/debug/tgw
swift build -c release   # .build/release/…
swift test
```

No environment variables are needed. If `swift build` fails with
`'td/telegram/td_json_client.h' file not found`, build TDLib first. The first build also
compiles the Swift dependencies, about 03:00; later builds take seconds.

The tests need no Telegram account and no network. They run in under a second once built
(`swift test` itself takes a few seconds to start). They cover the store and its migrations,
the event log (paging, pruning, the `410` rule), grants (the intersection with the monitored
set, scope checks, revocation), access requests (expiry, approval, purge), the translation of
every TDLib update the gateway handles, monitoring (folders, member-count coalescing,
backfill after a gap), webhook delivery (batching, signatures, the retry schedule), the media
cache, the secret store, every HTTP route and WebSocket close code, and the link to Volgenic
(hello, requests through the admin API, refused paths, subscribe with backlog, live events
and `gap`, `auth_state`, the stop on `401` and `4401`, reconnecting, and reloading links).

The link tests start a stand-in for Volgenic inside the test process: a WebSocket server on
`127.0.0.1` at a port the system picks, plus a plain server that answers every request with
`401`. They use loopback only, never the network.

Two things make that possible, and new code should keep to them:

- Everything above the TDLib client talks to TDLib through the one-method protocol
  `TDLibRequesting`. Tests substitute `FakeTDLib`, which answers from fixtures written from
  TDLib's schema (`vendor/tdlib/src/td/generate/scheme/td_api.tl`).
- Time goes through `GatewayClock`. Tests use `ManualClock` to move through expiries,
  batching delays and retry schedules without waiting. The link's reconnect delays are in
  `LinkTiming`, which the link tests shorten to milliseconds.

Run one suite with `swift test --filter GatewayCoreTests.MonitorTests`.

## Telegram API credentials

1. Go to https://my.telegram.org and log in with your phone number.
2. Open "API development tools" and create an application (any name; platform "Desktop").
3. Note the **App api_id** (a number) and **App api_hash** (32 hex characters).

Put them in `config.json` in the data directory:

```json
{"api_id": 12345, "api_hash": "0123abcd…"}
```

The menu bar app asks for them during setup and writes this file for you. A gateway that is
already running picks them up on `tgw daemon reload` (or `POST /v1/admin/reload`), whichever
way it was started; the app does this itself after saving. Never commit these values, and
never use another program's pair.

## Run the gateway

### In the foreground

```
$ .build/debug/GatewayDaemon --verbose
… info daemon: Telegram Gateway 0.1.0 listening on http://127.0.0.1:41414, data in /Users/you/Library/Application Support/TelegramGateway, secrets in /Users/you/Library/Application Support/TelegramGateway/secrets.json
… info http: Server started and listening on 127.0.0.1:41414
```

Logs go to stderr. Ctrl-C or SIGTERM stops it cleanly: open WebSockets are closed with code
`1001`, the HTTP server drains, and TDLib is closed and given time to flush its binlog. On
first run the gateway creates the admin token in the secret store.

To run a second, isolated gateway for experiments, give it its own directory and port:

```
TGW_HOME=/tmp/tgw-dev TGW_PORT=41499 .build/debug/GatewayDaemon --verbose
```

### As a LaunchAgent

```
$ swift build -c release
$ .build/release/tgw daemon install
installed /Users/you/Library/LaunchAgents/local.telegram-gateway.plist
binary    /Users/you/code/telegram-gateway/.build/release/GatewayDaemon
data      /Users/you/Library/Application Support/TelegramGateway
logs      /Users/you/Library/Application Support/TelegramGateway/logs/daemon.err.log
The daemon starts now and at every login. `tgw health` to check it.
```

`tgw daemon install` fills in the template in `launchd/` with the path of the
`GatewayDaemon` next to the `tgw` you ran (or `--binary <path>`), the data directory and the
log paths, writes it to `~/Library/LaunchAgents/`, and loads it. The gateway then starts at
every login and is restarted if it exits.

```
$ tgw daemon status
plist     /Users/you/Library/LaunchAgents/local.telegram-gateway.plist
launchd   state = running, pid = 61192
lock      held by pid 61192 (daemon)
health    ok auth=ready head_seq=4812 on port 41414

$ tgw daemon reload            # re-read config.json: api_id / api_hash and links take effect now
reloaded  telegram started
link      started https://volgenic.com
$ tgw daemon restart           # launchctl kickstart: applies every setting, including port
restarted local.telegram-gateway
$ tgw daemon logs -n 50        # add -f to follow
$ tgw daemon uninstall         # stops the gateway and removes the plist; data is kept
```

`tgw daemon restart` only knows the agent that `tgw daemon install` created. A gateway
started by the menu bar app or in a terminal is restarted there; `reload` works for all of
them.

Rebuilding in place is fine; stop and start the agent to pick up the new binary. If you move
the binary, install again. The menu bar app can also run the gateway, through its own
LaunchAgent ([app.md](app.md)); use one or the other, since two gateways cannot share a data
directory and the second refuses to start.

### Log in

Log in through the gateway: the menu bar app does it for you, or drive the endpoints under
`/v1/admin/auth` in [api.md](api.md) yourself. `POST /v1/admin/auth/qr` starts a QR login
and `GET /v1/admin/auth` returns the `tg://login?token=…` link to show as a QR code; scan it
in Telegram on your phone under Settings → Devices → Link Desktop Device.

### Without credentials

With no `api_id`/`api_hash` the gateway still starts. `GET /v1/health` reports
`auth_state: unknown`; events, grants and access requests work from the store; anything that
needs Telegram (login, history, media, the chat list, monitoring a chat the gateway has never
seen) answers `503 not_logged_in`.

## Configuration reference

`config.json` in the data directory. Every key is optional; unknown keys are ignored.

| Key | Default | Meaning |
|---|---|---|
| `port` | `41414` | Port on `127.0.0.1`. |
| `api_id`, `api_hash` | none | Your Telegram API credentials. Without them Telegram is disabled. |
| `events_retention_days` | `null` | `null` keeps every event. A number makes the gateway delete older events once an hour. |
| `media_cache_max_bytes` | `2147483648` | Size at which the least recently served media files are evicted. |
| `secrets` | `"file"` | `"file"` or `"keychain"`; see [Secrets](#secrets). |
| `daemon_path` | none | Written by the menu bar app for its launcher; the gateway ignores it. |
| `links` | `[]` | Links to Volgenic, `[{"base_url": "https://volgenic.com"}]`. Written by `tgw link`; see [tgw link](#tgw-link). |

Environment variables, read by the gateway and by `tgw`:

| Variable | Meaning |
|---|---|
| `TGW_HOME` | The data directory. |
| `TGW_PORT` | Overrides `port`. |
| `TGW_API_ID`, `TGW_API_HASH` | Override `api_id` and `api_hash`. |

`GatewayDaemon` flags:

| Flag | Meaning |
|---|---|
| `--verbose` | Log at debug level (every request, every delivery attempt). |
| `--home <dir>` | The data directory, like `TGW_HOME`. |
| `--port <n>` | The port, like `TGW_PORT`. |

Flags win over environment variables, which win over the file.

Changes to `api_id`, `api_hash` and `links` take effect on reload: `tgw daemon reload` (or
`POST /v1/admin/reload` with the admin token) makes the running gateway re-read
`config.json`, start, replace or drop its Telegram session in place, and start, restart or
close its links, without touching the event log, grants or open connections. Every other key needs a restart; the reload response
lists the ones that changed under `restart_required`.

## Where data lives

```
~/Library/Application Support/TelegramGateway/
  config.json      see above
  secrets.json     the admin token, TDLib's database key and the link tokens (mode 0600)
  gateway.sqlite   the gateway's store: monitored set, chat and folder cache, event log,
                   per-chat cursors, access requests, grants, webhook deliveries, media index
  tdlib/           TDLib's directory: td.binlog, db.sqlite (encrypted), files/ (downloads)
  logs/            daemon.out.log and daemon.err.log when run by `tgw daemon install`
  daemon.lock      held by the process that owns TDLib
```

Only one process may open `tdlib/`. The gateway holds `daemon.lock` while it runs, and so
does any `tgw` command that opens TDLib directly; whoever finds the lock held refuses to
start and names the holder. The lock is released when the process exits, however it exits.

To start over, stop the gateway and delete the directory. To log the account out but keep
everything else, use the menu bar app or `POST /v1/admin/auth/logout`.

## Secrets

The gateway has these secrets:

| Key | What it is | Created |
|---|---|---|
| `admin-token` | The token (`tgw_…`) that may call `/v1/admin/*`. `tgw` and the menu bar app send it. | By the gateway on first run. |
| `tdlib-db-key` | 32 random bytes with which TDLib encrypts `db.sqlite`. Without it the local database is unreadable and you log in again. | When TDLib is first opened. |
| `link-token:<base_url>` | The token (`vgl_…`) of the link to that Volgenic server, one per link ([link.md](link.md)). | By `tgw link add`; deleted by `tgw link remove`. |

They are kept in a secret store chosen by `secrets` in `config.json`:

- **`"file"`, the default.** `secrets.json` in the data directory: a JSON object mapping each
  key to the base64 of its value, mode 0600, written atomically.
- **`"keychain"`.** Generic passwords in your login Keychain, service `TelegramGateway`,
  accounts named as above.

The file is the default because of how the Keychain identifies programs. macOS ties each
Keychain item to the code signature of the program that stored it. `swift build` signs
binaries ad hoc, which gives every rebuilt binary a new signature, and `tgw` and
`GatewayDaemon` different signatures from each other. Each read of an item that a
"different" program stored stops and asks for your login password. With the Keychain, a
development session would prompt after every rebuild. The Keychain store exists for releases
signed with a stable identity, where that does not happen.

What follows from this when you work on the code:

- Tests never touch the Keychain. They use `InMemorySecretStore`, or a `FileSecretStore` in a
  temporary directory.
- Development builds never read the Keychain unless `config.json` asks for it. Leave
  `secrets` unset.
- Nothing migrates between the stores. If you switch, the gateway creates a new admin token
  and you log in to Telegram again.

`tgw secrets` shows which store is in use and which keys exist, never their values.
`tgw link add` writes a link token to the same store as the admin token, so while developing
it goes to `secrets.json` and never to the Keychain.
`tgw secrets regenerate-admin-token` replaces the admin token; restart the gateway
afterwards.

## tgw command reference

Most commands talk to the running gateway over the API with the admin token and never touch
TDLib. Each accepts `--json` to print the gateway's reply instead of a table. `tgw --help`
and `tgw <command> --help` list every option.

### `tgw health`

```
$ tgw health
status        ok   version 0.1.0   port 41414
telegram      auth=ready  connection=ready
account       Ada Lovelace (@ada) id=123456789 phone=…4567
events        head_seq=4812  oldest_seq=1  last_hour=37
monitored     2 chats   grants 1   webhooks active=1 retrying=0 paused=0
backfill      in_progress=false chats_pending=0   media_cache=184320 bytes
link          https://volgenic.com  connected since 2026-09-29T09:00:13.120Z
started       2026-09-29T09:00:12.004Z
```

Without an admin token it prints only what the unauthenticated health check returns. Each
link to Volgenic gets a `link` line with its state, and its last error when it is not
connected.

### `tgw monitor`

The monitored set: the chats, and the chat folders, the gateway watches.

```
$ tgw monitor list --archive      # archived chats; implies --all
$ tgw monitor list --all          # main-list chats; needs a logged-in gateway
id               type        monitored  title
-1001234567890   channel     yes        Acme Product Updates
-1001987654321   channel                Acme Support
-1009876543210   supergroup             Open Source Weekly
123456789        private                Ada Lovelace

$ tgw monitor add -1001987654321 folder:3
chat_ids       -1001234567890,-1001987654321
folder_ids     3
effective      3 chats
id               type     members  title
-1001987654321   channel  880      Acme Support
-1001555000111   channel  51200    Industry News
-1001234567890   channel  12840    Acme Product Updates

$ tgw monitor remove folder:3
$ tgw monitor folders
id  monitored  chats  title
3              2      Product
$ tgw monitor list                # the current set
```

A source is a chat id or `folder:<id>`. Each chat that enters or leaves the effective set
produces a `monitoring.started` or `monitoring.stopped` event.

### `tgw requests`

Access requests from apps.

```
$ tgw requests
req_7Hs2kQm9vL4pX1nB8cR3tY6wZ0aD5eF2gJ4iK7lM9oP   pending   expires 2026-09-29T14:18:07Z
  Community Analytics — Classifies messages in product channels and counts topics per day.
  scopes: chats:read history:read messages:read
  chat -1001234567890  Acme Product Updates  monitored
  chat -1001987654321  Acme Support  NOT monitored
  webhook: https://analytics.example.com/tgw/events

$ tgw requests approve req_7Hs2… --chats -1001234567890 --scopes messages:read chats:read
approved: grant grant_Ab3dE5fG7hJ9kL1m for Community Analytics
scopes    chats:read messages:read
effective -1001234567890
The app receives its token on its next poll (within 10:00).

$ tgw requests approve req_… --folder 3
$ tgw requests deny req_… --reason "Not now."
$ tgw requests list --all         # include resolved requests still retained
```

A chat must be monitored before it can be granted. `--scopes` may only narrow what the app
asked for.

### `tgw grants`

```
$ tgw grants
id                      app                  scopes                    chats    effective  webhook             last seen             revoked
grant_Ab3dE5fG7hJ9kL1m  Community Analytics  chats:read,messages:read  1 chats  1          active (0 pending)  2026-09-29T14:07:12Z  -

$ tgw grants show grant_Ab3dE5fG7hJ9kL1m     # the grant, its stats, recent webhook deliveries
$ tgw grants revoke grant_Ab3dE5fG7hJ9kL1m
revoked grant_Ab3dE5fG7hJ9kL1m
$ tgw grants resume-webhook grant_Ab3dE5fG7hJ9kL1m
$ tgw grants list --all           # include revoked grants
```

Revoking is immediate and permanent; the app has to request access again.

### `tgw send`

Sends a text message as you, through the running gateway, to a monitored chat. It shows the
chat, the account and the text, and asks before sending; `--yes` skips the question.

```
$ tgw send -1001987654321 "Thanks, this is fixed in 2.4.1." --reply-to 1522
To      Acme Support (-1001987654321)
Reply   to message 1522
From    Ada Lovelace, your Telegram account
Text    Thanks, this is fixed in 2.4.1.
Send this message? [y/N] y
sent: message 1530 in chat -1001987654321
```

It calls `POST /v1/chats/{chat_id}/messages` with the admin token
([api.md](api.md#sending-messages)), so it needs a running, signed-in gateway and sends only
to monitored chats. The message reaches everyone in the chat. Never point it at a real chat
while developing or testing: tests use the fake TDLib and send nothing.

### `tgw link`

Links to Volgenic ([link.md](link.md)): the gateway dials out to a Volgenic server and that
Volgenic account drives it, with the admin token's powers except secrets, including sending
messages as you. Volgenic shows the `add` command, with its token, when you link a gateway.

```
$ tgw link add https://volgenic.com vgl_q3Jf…
added link to https://volgenic.com
state     connected since 2026-10-26T14:03:07.412Z

$ tgw link list
base_url               connected  state         since                     last error
https://volgenic.com   yes        connected     2026-10-26T14:03:07.412Z  -
http://localhost:4100  no         unauthorized  2026-10-26T14:05:40.003Z  Volgenic refused the link token (HTTP 401); add the link again with a new token

$ tgw link remove http://localhost:4100
removed link to http://localhost:4100
```

`add` stores the URL in `config.json` and the token in the secret store, then reloads the
running gateway, which connects at once; for a base URL that already has a link it replaces
the token. `remove` deletes both and closes the link. `list` asks the running gateway for
each link's state (`connecting`, `connected`, `waiting`, `unauthorized`, `no_token`,
`stopped`), when it entered it, and the last error. A link Volgenic refused stays
`unauthorized` until you run `add` again or reload. With the gateway stopped, `add` and
`remove` only change the files, and the gateway applies them when it starts.

The token is an argument, so it lands in your shell history; it is worthless once the link
is revoked in Volgenic.

To try a link while developing, run a second gateway (`TGW_HOME=/tmp/tgw-dev TGW_PORT=41499`)
and point it at Volgenic's development server with
`tgw link add http://localhost:4100 vgl_…` in the same environment.

### `tgw events`

```
$ tgw events tail --since 4800
4801  2026-09-29T14:03:07Z  message.new  -1001234567890 "Acme Product Updates"  msg=412 from=Acme Product Updates [photo] v2.4 is out.
4802  2026-09-29T14:05:02Z  message.edited  -1009876543210 "Open Source Weekly"  msg=1523 from=Ada Lovelace the export in v2.3 fails on …
caught up at seq 4812; live
4813  2026-09-29T14:06:41.900Z  message.deleted  -1009876543210 "Open Source Weekly"  ids=1520,1521
```

`tail` holds the WebSocket stream with the admin token, so it sees every monitored chat.
`--since` replays from a sequence number before going live, `--types` and `--chat` filter,
`--json` prints the raw frames. `tgw events page --since N --limit M` fetches one page over
HTTP.

### `tgw daemon`

`install`, `uninstall`, `status`, `reload`, `restart` and `logs`, described under
[As a LaunchAgent](#as-a-launchagent).

### `tgw secrets`

`show` (the default) and `regenerate-admin-token`, described under [Secrets](#secrets).

### Commands that open TDLib directly

`tgw login`, `whoami`, `chats`, `watch` and `logout` do not use the gateway. Each opens TDLib
itself, does its work and closes TDLib cleanly, also on Ctrl-C. They are for debugging TDLib
behaviour with the gateway stopped, and they stop at once while it is running:

```
$ tgw whoami
Error: the gateway daemon (pid 61192) is running and owns TDLib. Direct TDLib commands cannot run at the same time; use the daemon-backed equivalents (`tgw health`, `tgw monitor`, `tgw requests`, `tgw grants`, `tgw events tail`) or stop the daemon first (…)
```

They take the credentials from `config.json`, from `TGW_API_ID` / `TGW_API_HASH`, or from
`--api-id` / `--api-hash`. They use the same `tdlib/` directory and database key as the
gateway, so a login made either way is seen by both.

- `tgw login` logs in by QR code drawn in the terminal (`--large-qr` if it does not scan),
  or with `--phone +15551234567` by code and two-step password. It never creates an account.

  ```
  $ tgw login

  Scan this with Telegram on your phone: Settings → Devices → Link Desktop Device
  …
  Link: tg://login?token=AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA
  Waiting for confirmation… (Ctrl-C to abort)
  Two-step verification password (hint: pet):

  Logged in as Ada Lovelace (@ada) id=123456789 phone=+1555…
  Data: /Users/you/Library/Application Support/TelegramGateway/tdlib
  ```

- `tgw whoami` prints the logged-in account.
- `tgw chats [--limit N]` lists the main chat list: id, type, unread count, title.
- `tgw watch <chat-id>… [--all]` prints each new, edited and deleted message as TDLib
  reports it, with the time received next to the message's own date, which shows how
  promptly updates arrive. It never marks anything as read and keeps the account offline.
- `tgw logout` ends the session on Telegram's side; TDLib deletes its local database.

## Code layout

```
Sources/CTDLib/             C module over TDLib's td_json_client.h
Sources/TDLibClient/        actor TDLibClient: request/response correlation, updates, login states
Sources/QRCode/             QR encoder and terminal rendering
Sources/GatewayCore/        the domain, testable without an account:
    Paths, Config, SecretStore, InstanceLock, Identifiers, Clock, JSONValue, Models, APIError
    Store (SQLite through GRDB), EventLog, Grants, AccessRequests
    TDLibRequesting, Translator (TDLib JSON → the event format)
    Monitor (updates → event log, cursors, folders, backfill)
    MessageSender (sendMessage, waiting for Telegram's verdict)
    WebhookDispatcher, MediaCache, RateLimiter, TelegramSession, Maintenance, GatewayClient
    LinkSettings (links in config.json, their tokens in the secret store)
Sources/GatewayLink/        the links to Volgenic: GatewayLinkClient (one per link),
                            LinkManager, the URLSession WebSocket transport, the frames
Sources/GatewayServer/      the HTTP and WebSocket API on Hummingbird; InProcessAPI runs a
                            link's requests through the same router
Sources/GatewayDaemon/      the executable: wiring, lock, signals, housekeeping
Sources/GatewayTestSupport/ FakeTDLib, TDLib fixtures, fake webhook client, fake Telegram session
Sources/tgw/                the command-line tool
Tests/                      swift-testing suites
launchd/                    the LaunchAgent template
App/                        the menu bar app (see app.md)
vendor/tdlib/               the TDLib build script and pinned commit
```

`TDLibClient` is one actor per TDLib client. A single thread calls `td_receive`, which
returns objects for every client, and routes each by its `@client_id`. Every request carries
a unique `@extra` that TDLib echoes on the response, which is how a request finds its
answer; objects with no pending `@extra` are updates.

The `Translator` is the boundary to TDLib's JSON: untyped dictionaries go in, typed models
come out, and nothing untyped crosses it. The API layer renders those models as `JSONValue`,
a typed tree that keeps key order and writes explicit `null`s, which is also what makes a
webhook body byte-exact for signing.

## Troubleshooting

- **`'td/telegram/td_json_client.h' file not found`** — TDLib is not built. Run
  `./vendor/tdlib/build.sh`.
- **`dyld: Library not loaded: …/libtdjson.dylib`** — the repository moved after TDLib was
  built; its install name is an absolute path. Run the build script again.
- **The gateway refuses to start, "another gateway daemon (pid …) is already running"** —
  one is, for this data directory. `tgw daemon status` shows who holds the lock.
- **`tgw` says there is no admin token** — the gateway has not run yet for this data
  directory, or `tgw` and the gateway disagree on `TGW_HOME` or on `secrets`.
- **`tgw daemon status` says "daemon not answering on port 41414"** while a gateway is
  running — it runs on another port. Set the same `TGW_PORT` (or `port` in `config.json`)
  for `tgw`.
- **macOS asks for your login password when a binary starts** — `config.json` has
  `"secrets": "keychain"` and the binary is ad-hoc signed. Remove the key to use the file
  store; see [Secrets](#secrets).
- **`503 not_logged_in` from history, media or the chat list** — no `api_id`/`api_hash`, or
  not logged in yet. `tgw health` shows `auth=…`. If you just added the credentials to
  `config.json`, run `tgw daemon reload`.
- **A WebSocket client sees the connection close instead of an HTTP 401** — by design: the
  stream endpoint always accepts the upgrade and reports a bad token with an error frame and
  close code `4401` ([api.md](api.md)).
- **cmake 4 rejects a TDLib sub-project** — `build.sh` passes
  `-DCMAKE_POLICY_VERSION_MINIMUM=3.5` for this; make sure you run the script rather than
  cmake directly.
- **The linker warns that the dylib was built for a newer macOS** — build TDLib with the
  script, which sets the deployment target to match `Package.swift`.
- **`swift test` hangs without output** — a test is waiting on something that never
  finishes. Run suites one at a time with `--filter` to find it.

Notes for working on the code:

- TDLib does nothing for a new client until it receives a request; the gateway sends
  `getOption version` to get the first authorization state.
- TDLib's message ids are the public ids (the number in a `t.me` link) shifted left by 20
  bits. Cursors in the store are TDLib's ids; everything on the API is public ids. A
  supergroup or channel with id S is chat `-1000000000000 - S`; a basic group B is chat `-B`.
- TDLib's JSON objects are `[String: Any]`, which is not `Sendable`. They cross isolation
  boundaries wrapped in `JSONBox`, which is safe because the decoded values are immutable.
- A WebSocket's inbound stream can be iterated once. In tests, make one iterator per
  connection and pass it around.
- A task group waits for all its children, including ones that cannot be cancelled. Do not
  race a TDLib request against a timer in a group; poll on the clock instead, as `MediaCache`
  does.
- Changing a dylib's install name invalidates its signature, and Apple silicon refuses
  unsigned code; `build.sh` signs it again.

### Owner action commands

`tgw` acts on the account through the running gateway's API, with the admin token, like
`tgw send`. Every command shows what it will do and asks first unless given `--yes`. None
of them loads TDLib. While developing, run them only against your own gateway (its own
`TGW_HOME` and `TGW_PORT`, without Telegram credentials), never the one signed in to your
account: they then stop at `403 chat_not_granted` or `503 not_logged_in`, and the tests
cover the rest with `FakeTDLib`.

```sh
tgw send <chat> [caption] --file <path> [--kind photo] [--mime-type image/jpeg] [--silent]
tgw forward <to-chat> <from-chat> <message> [message ...] [--send-copy]
tgw edit <chat> <message> 'Corrected text'
tgw delete <chat> <message> [message ...] [--for-everyone]
tgw react <chat> <message> '👍' [--remove] [--custom] [--big]
tgw vote <chat> <message> [option ...]        # options count from 0; none takes the vote back
tgw chat pin <chat> [--undo]
tgw chat archive <chat> [--undo]
tgw chat mute <chat> [--for 8:00:00] [--undo]
tgw chat start <username> [--phone]
tgw read <chat> [--up-to <message>] [--mentions]   # senders see read receipts
```

`send --file` sends a document unless `--kind` says otherwise, and guesses the MIME type
from the file name unless `--mime-type` gives it. `--custom` reads the reaction as a custom
emoji id. `--for` takes `mm:ss` or `h:mm:ss`.
