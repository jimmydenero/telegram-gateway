# Status and roadmap

Telegram Gateway is pre-release software. It builds from source, its test suite passes, and
the gateway, the menu bar app and `tgw` run together on a Mac. The part that talks to
Telegram has been written against TDLib's schema and tested with a scripted stand-in; it has
not yet been verified against a live Telegram account. The unverified behavior and known
limitations below should inform deployment decisions.

## What works today

- **Actions**, new: sending formatted text and files (photos, videos, documents, voice
  notes, audio, animations, stickers), forwarding, editing and deleting the account's own
  messages, reactions, poll votes, pinning, archiving and muting chats, and starting a chat
  by username or phone number ([api.md](api.md#message-and-chat-actions)). Each works from
  the library, `tgw`, the HTTP API and the link to Volgenic, and all go through
  `MessageSender`'s checks. Tested with the scripted stand-in for TDLib only; see below.

- **Mirror fields**, new: read counts and receipts, manual unread markers, main-list pins
  and order, archive/mute state, reactions, formatting, forum topic ids, polls and common
  service-message text. Fake TDLib fixtures cover snapshots, updates, coalescing and API
  scope filtering. These additions are unverified against a live account.

- **Building from source**: TDLib at a pinned commit, the Swift package (`GatewayDaemon`,
  `tgw`), and the menu bar app. See [development.md](development.md) and [app.md](app.md).
- **The gateway service**: runs in the foreground or as a LaunchAgent, keeps its data in one
  directory, refuses to run twice on the same data, shuts down cleanly.
- **The whole API in [api.md](api.md)**: health, the access-request flow, grants and scopes,
  the monitored set and folders, paged events, the WebSocket stream with resume, history,
  sending and the other actions with `messages:send` and `chats:manage`, media with range requests, webhooks with signatures and retries, the login endpoints,
  pruning, rate limits.
- **The event log**: numbered events, resume from any sequence number, retention and pruning.
- **Webhook delivery**: ordered batches, HMAC signatures, the retry schedule, pause and
  resume, recovery of an interrupted delivery after a restart.
- **Administration** from the menu bar app and from `tgw`: install and inspect the
  LaunchAgent, reload the configuration in place, change the monitored set, approve, deny
  and revoke, follow the event stream, and act as yourself: `tgw send` (also with
  `--file`), `tgw forward`, `tgw edit`, `tgw delete`, `tgw react`, `tgw vote` and
  `tgw chat pin|archive|mute|start`, each asking first unless `--yes`.
- **Links to Volgenic** ([link.md](link.md)), new: `tgw link add/list/remove`, the outbound
  WebSocket with `hello`, requests run through the admin API in process, `subscribe` with
  backlog, live events and `gap`, `auth_state` pushes, reconnecting with backoff, and the stop
  when Volgenic refuses the token. Tested against a stand-in for Volgenic in the test process
  and run once by hand, with a real gateway (no Telegram credentials) against a stand-in
  server on `127.0.0.1`.
- **Tests**: the suite runs without a Telegram account and without network access, and
  covers everything above, including the translation of each TDLib update into the event
  format in [events.md](events.md).

## Not yet verified against a live Telegram account

The code on the TDLib side follows TDLib's published schema, and the tests feed it objects
built from that schema. The following behavior still requires live-account verification:

- Logging in through the gateway: the QR flow, phone number with code and two-step password,
  accounts that log in with an e-mail code, and logging out and in again without a restart.
- Whether Telegram pushes new messages promptly for large channels the account has joined
  but not opened recently, and whether the chat list must be loaded first.
- Edited messages: the order in which TDLib reports an edit's two updates, and that exactly
  one `message.edited` results.
- Backfill after sleep or a lost connection: reading history forward from the last message
  seen, in busy chats.
- Chat folders: reading a folder's chats, and following changes made on the phone.
- Member counts and how often Telegram reports them.
- Media: downloading on demand, progress while downloading, and eviction from the cache.
- Long-running behaviour: days of uptime, reconnects, Telegram's rate limits on history.
- Sending, which is new: that `sendMessage` followed by `updateMessageSendSucceeded` behaves
  as the tests assume, that the confirmed message becomes exactly one `message.new`, how
  Telegram's errors and flood waits look in practice, whether `30s` is the right time to
  wait, and whether Telegram, seeing the account send, marks the chat as read or shows the
  account as online on the user's other devices even though the gateway asks for neither.
- **The actions**, which are new. None has been run against Telegram. Unverified: that
  each TDLib request is accepted as the gateway builds it; how TDLib reports the results
  (in particular that a forwarded message, an edit, a deletion, a reaction, a vote and a
  pin, archive or mute each become exactly one event); which reactions and deletions
  Telegram refuses and with what text; whether TDLib fills in a voice note's duration and
  waveform when they are not given; whether uploads of 20 MiB finish within `30s`;
  whether `searchUserByPhoneNumber` finds people who are not contacts; and that reacting
  and voting work on a chat that is not open, without marking it read.
- **The link to Volgenic**, which is new. It has not been run against a real Volgenic server
  or with a signed-in account: not the TLS connection to `wss://volgenic.com`, Volgenic's
  `401` and `4401`, its pings, a sign-in driven from Volgenic, media of several megabytes in
  one frame, or a link held open for days through sleep and network changes.
- The menu bar app's **Can act as you** section (`messages:send` and `chats:manage`) has
  not been built or run: it was written without Xcode.

`tgw watch` exists to check the second item directly: it prints each message as TDLib
reports it, next to the message's own timestamp.

## Known limitations

- macOS on Apple silicon only, macOS 15 or later.
- One Telegram account per gateway.
- Actions cannot send several files as one album, schedule a message, send into a forum
  topic, join or leave a group or channel, or edit or delete other people's messages. A
  sent message cannot be told apart from one the user typed on their phone.
- An uploaded file waits in the data directory until Telegram answers. If the gateway stops
  first, the file stays until a start more than `24:00:00` later removes it.
- No packaged release. You build from source, which needs Xcode, cmake and a few minutes.
- You need your own `api_id` and `api_hash` from https://my.telegram.org.
- Apps on other machines can receive webhooks but cannot open the WebSocket or call the
  HTTP API: the gateway listens on `127.0.0.1` only.
- The event log stores message content unencrypted in the data directory, and keeps it
  forever unless you set a retention period or prune.
- Webhook signing secrets are stored unencrypted in the gateway's database, since the
  gateway signs with them. An approved app's token is stored unencrypted for the `10:00` in
  which the app may collect it.
- Secret chats, archive/folder pin order and structured topic metadata
  are not part of the event format. Mirroring still requires monitoring and granting chats;
  these additions do not automatically expand access.
- On the WebSocket, a bad token is reported with a close code after the upgrade, not with an
  HTTP `401`.
- A locally built menu bar app may fail to register the gateway to start at login; macOS
  reports it registered but does not start it. Installing the LaunchAgent with
  `tgw daemon install` works, as does letting the app run the gateway while it is open.
- A link to Volgenic has the admin token's powers except secrets, including sending messages
  as the user; there is no narrower link. The menu bar app does not show links yet: use
  `tgw link`.
- There are two ways to run the gateway at login (the app's and `tgw daemon install`). Use
  one; a second gateway on the same data directory refuses to start.

## Planned

- Verification against a live account, and fixes for whatever differs.
- The gateway bundled inside the menu bar app, so that installing the app is the whole
  installation and no command-line step is needed.
- A signed, notarized release, with secrets in the Keychain.
- Consumers on other machines holding a WebSocket, over a private network.
