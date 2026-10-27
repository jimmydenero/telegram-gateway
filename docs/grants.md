# Grants: the access model

Telegram Gateway separates account access from application permissions. The account owner
chooses which chats are monitored and grants each application a subset of chats and scopes.
This document defines those boundaries, token handling, and revocation behavior for
integration developers and gateway operators.

Three parties appear throughout:

- **The user** is the person who runs the gateway. The Telegram account is theirs, and every
  choice about access is theirs.
- An **app** is a program that reads Telegram messages through the gateway and, if the user
  allows it, sends messages and acts on them as the user.
- "You" are the developer of an app.

The endpoints behind everything described here are in [api.md](api.md). The format of what
an app receives is in [events.md](events.md).

## Contents

- [What an app can and cannot see](#what-an-app-can-and-cannot-see)
- [Scopes](#scopes)
- [Folder-based grants](#folder-based-grants)
- [What the user sees when approving](#what-the-user-sees-when-approving)
- [Tokens](#tokens)
- [What revoking does](#what-revoking-does)
- [Storing the token](#storing-the-token)
- [What the gateway guarantees](#what-the-gateway-guarantees)
- [Not supported](#not-supported)

---

## What an app can and cannot see

Two sets of chats determine what an app receives. (A **chat** is any Telegram conversation: a
channel, a group, or a private conversation.)

**Monitored chats** are the chats the gateway watches at all. The user picks them in the
gateway's menu bar app. Only messages in monitored chats are written to the gateway's event
log. Unmonitored messages are excluded from that log and app delivery, although TDLib
maintains its own encrypted cache. The monitored set is global across applications.

**Granted chats** are, for one app, the chats that app may read. A **grant** is the record of
one app's access: its name, its scopes, its chats and its token. The user creates a grant by
approving the app's access request.

One rule ties the two together:

> **Effective access never exceeds the monitored set.** What an app can see at any moment is
> `granted chats ∩ monitored chats`, computed each time the app asks.

The API calls that intersection `effective_chat_ids`. It is in the grant object returned by
`GET /v1/me`.

![Two overlapping sets within the chats visible to the Telegram account: monitored chats
chosen by the user and chats granted to one app. The highlighted intersection is what the
app can read, subject to its scopes. Unmonitored messages are never stored in the gateway
event log or delivered.](images/grants.png)

| An app can | An app cannot |
|---|---|
| Read messages in chats that are both granted to it and monitored, if it holds `messages:read`. This includes messages the user sends in those chats. | Read any other chat: private conversations, unmonitored groups and channels, or chats granted to a different app. |
| See who sent each message: display name, username and numeric id, plus read counts, receipts and mute state in its chat summary. | See the user's phone number or contacts. |
| Read the earlier timeline of a granted chat, back before the gateway monitored it, if it holds `history:read`. | Read the history of any chat outside its grant. |
| Download photos and files from messages in granted chats, if it holds `media:read`. | Download a file that belongs to a chat outside its grant, even with the file's id. |
| Learn the titles, usernames and member counts of its granted chats, if it holds `chats:read`. | List the user's chats, or find out whether a chat it was not granted exists. |
| Ask for access again, or for more. | Approve itself, widen its own grant, or see other apps' grants. |
| Send messages and files as the user, forward messages, edit and delete the user's own messages, react and vote in polls, in chats that are both granted to it and monitored, if it holds `messages:send`. | Do any of that in another chat, or edit or delete someone else's message. |
| Pin, archive and mute its granted chats, and look up a chat by username or phone number, if it holds `chats:manage`. | Add a chat to its grant by looking it up: a chat found that way must already be granted. |
| Mark its granted chats read as the user when a person using it read them, if it holds `messages:mark_read`. The senders then see read receipts. | Mark any other chat read. |
| | Make the account appear online, show "typing…", join or leave groups and channels, or act on the account in any other way. |

Three consequences of the rule:

- When the user stops monitoring a chat, every grant that includes it loses it at once, and
  the apps that had it receive a `monitoring.stopped` event. The grant still lists the chat,
  so if the user monitors it again, access resumes without a new approval.
- A request cannot be approved for a chat that is not monitored (`400 chat_not_monitored`).
  The menu bar app offers to start monitoring the chat as part of approving, so the user
  makes one decision.
- An app cannot tell a chat it was not granted from a chat that does not exist. Both answer
  `403 chat_not_granted`.

---

## Scopes

A **scope** names a kind of access. A grant holds one or more. Scopes determine what kind of
data; the chat set determines from which chats. Both apply to every request.

| Scope | Shown to the user as | Allows | Endpoints and events |
|---|---|---|---|
| `messages:read` | New messages | Receiving messages as they arrive, and reading the stored backlog. | `message.new`, `message.edited`, `message.deleted`, `message.reactions` and `poll.updated` events, from `GET /v1/events`, the WebSocket and webhooks. |
| `history:read` | Past messages | Reading a chat's timeline from Telegram, back before the gateway monitored it. | `GET /v1/chats/{chat_id}/messages` |
| `media:read` | Photos and files | Downloading the files attached to messages, and chat photos. Without it, messages still describe their media (kind, size, file name); only the bytes are withheld. | `GET /v1/media/{media_id}` |
| `chats:read` | Chat names and details | Listing granted chats with title, username, member count, read state, position and mute state, and learning when coverage changes. | `GET /v1/chats`, and the `chat.updated`, `chat.read`, `chat.position`, `monitoring.started` and `monitoring.stopped` events. |
| `messages:send` | Send and react | Acting on messages **as the user** in the granted chats: sending text and files, optionally formatted or as a reply; forwarding (both chats must be granted); editing and deleting the user's own messages; reacting; voting in polls. Everyone in the chat sees these as the user's. | `POST /v1/chats/{chat_id}/messages` and the [message actions](api.md#message-and-chat-actions) |
| `messages:mark_read` | Mark as read | Marking the granted chats read **as the user**, up to a message or the newest, and optionally clearing unread mentions. The people who wrote the messages see read receipts, and the unread badges clear on the user's other devices. Granted only if the app asked for it. | `POST /v1/chats/{chat_id}/read` |
| `chats:manage` | Manage chats | Pinning, archiving and muting the granted chats, which changes how they appear in the user's own Telegram apps, and looking up a chat by username or phone number. | `PATCH /v1/chats/{chat_id}`, `POST /v1/chats` |

Until this version `messages:send` allowed sending plain text only. A grant approved then
keeps the scope and so can now also forward, edit, delete, react and vote; the user who does
not want that revokes the grant, and the app asks again. `chats:manage` and `messages:mark_read` are
new, so no existing grant holds them.

`GET /v1/me` and the endpoints under `/v1/me/webhook` need no particular scope: any valid app
token can inspect its own grant and manage its own webhook.

Typical combinations:

| App | Scopes |
|---|---|
| Support Triage: alerts on new messages | `messages:read`, `chats:read` |
| Community Analytics: counts topics, with past months as a baseline | `messages:read`, `history:read`, `chats:read` |
| Archive: keeps messages with their attachments | `messages:read`, `history:read`, `media:read`, `chats:read` |
| Inbox: shows conversations and replies to them | `messages:read`, `history:read`, `chats:read`, `messages:send` |

Ask for the least you need. The user sees the scopes when approving, and a request for
"Photos and files" from an app that only counts hashtags looks wrong. Ask for
`messages:send` only if a person using your app decides what is sent: the user is lending
the app their name in every granted chat. Ask for `chats:manage` only if a person using your
app pins, archives or mutes chats in it, and for `messages:mark_read` only if your app marks
a chat read when a person opens it, never on its own: the user's contacts see the receipts.

---

## Folder-based grants

A Telegram **folder** is a named collection of chats that the user maintains in Telegram's
own apps, where folders appear as tabs above the chat list: "Work", "Product". The gateway
reads the user's folders from Telegram.

A grant's chats are either a fixed **list** of chat ids or a **folder**. A folder grant
covers whatever the folder contains at the moment of each request. When the user adds a
channel to the "Product" folder on their phone, every app granted "Product" gains that
channel without another approval. When a chat is removed from the folder, access to it ends.

The monitored set can follow a folder too. The usual arrangement is that the user monitors
the "Product" folder and grants apps the "Product" folder. Adding a channel to the folder on
the phone then extends both monitoring and access.

The rule above still holds for folders. A folder grant reaches only those chats of the
folder that are monitored, and a folder can be granted only if it is monitored
(`400 folder_not_monitored`).

An app cannot ask for a folder. It asks for specific chats or for `"any"`, and the user may
choose to answer with a folder. The app sees which it got in `GET /v1/me`:

```json
"chats": { "mode": "folder", "folder_id": "3", "folder_title": "Product" }
```

---

## What the user sees when approving

An app asks with `POST /v1/access-requests`: a name, a one-sentence description, the scopes
it wants, optionally the chats it would like, and optionally a webhook URL
([api.md](api.md#access-requests)). The request stays pending for `15:00`.

The request appears in the menu bar app's window under **Apps**, and a dot on the menu bar
icon signals that it is waiting. The user sees the app's own words, how long the request has
left before it expires, and three facts:

```
Community Analytics                                          Wants access
"Classifies messages in product channels and counts topics per day."

Wants      New messages, past messages, chat names and details
In         Acme Product Updates
           Acme Support                          not monitored yet
Sends to   analytics.example.com

                                                 [ Deny ]   [ Review… ]
```

**Sends to** is the host of the webhook URL: the place outside the Mac where the app will
receive events. It is absent when the app uses the WebSocket only.

**Review…** opens the sheet where the user sets what the grant holds:

```
Give Community Analytics access

Chats
  [x] Acme Product Updates
  [x] Acme Support        Not monitored yet — approving starts monitoring it
  Show 6 other monitored chats
  Follow a folder instead

Can read
  [x] New messages             Every message as it arrives, with edits and deletions
  [x] Past messages            Messages from before the app was connected
  [x] Chat names and details   Titles, usernames and member counts

Can act as you
  [x] Send and react           Sends messages and files as you, forwards, edits and
                               deletes what you sent, reacts and votes; people see it as you
  [x] Mark as read             Mark messages read as you: senders see read receipts

2 chats · 4 permissions                          [ Cancel ]   [ Approve ]
```

**Can act as you** appears only when the app asked for `messages:send`, `messages:mark_read`
or `chats:manage` ("Manage chats: pins, archives and mutes these chats, and finds chats by
username or phone number"). Each is ticked like the other permissions the app asked for, and kept apart from
them so that it is never mistaken for one more kind of reading. Unticking one gives the app
everything else it asked for, without it. This wording is in the menu bar app's source but
the app has not been built or run with it.

The user can untick scopes, untick chats, add other monitored chats, or switch the grant to a
folder. Scopes can only be removed, never added beyond what the app asked for. What the user
approves is what the grant holds, so read your grant (in the approved poll response, and
later from `GET /v1/me`) instead of assuming your request was granted as written.

The name and description are supplied by the app, and the gateway does not verify them. They
are the app's claim about itself; the scopes, the chats and the webhook host are what the
gateway enforces.

Only the user can approve. No API call lets an app approve itself or widen its grant, and
approving requires the admin token, which only the menu bar app and the `tgw` command-line
tool on the user's Mac hold. An app that needs more sends a new access request, which the
user sees as a new request. The menu bar app is described in [app.md](app.md).

---

## Tokens

A **token** is the string `tgw_` followed by 43 characters (32 random bytes, base64url). It
is the only thing an app presents. It identifies the grant and proves possession.

The gateway keeps a SHA-256 hash of the token on the grant. The token itself is held only
inside the access request, for the `10:00` hand-out window after approval, and is erased with
it. The app therefore has `10:00` to collect the token from the approved poll response;
after that, nobody can read it back, including the user.

There is one **admin token**, held by the menu bar app and `tgw`. It is not tied to a grant
and can do everything, including approving and revoking. Apps never receive it. The gateway
keeps it in a file only the user's macOS account can read
(`~/Library/Application Support/TelegramGateway/secrets.json`, mode 0600), or in the login
Keychain when configured to ([api.md](api.md#authentication)).

Tokens do not expire. Access ends when the user revokes the grant.

---

## What revoking does

The user revokes a grant in the menu bar app with **Revoke access…**, behind a confirmation.
The effects are immediate and permanent:

| Channel | Effect |
|---|---|
| HTTP requests | `401 token_revoked`, with `details.revoked_at`. |
| Open WebSockets | Closed with code `4499`. A new connection with the token receives an error frame `token_revoked` and is closed with `4401`. |
| Webhook | No further deliveries. Pending deliveries and the cursor are dropped. A delivery already in flight is not cancelled, so one more batch may arrive. |
| Media downloads in progress | Aborted. |
| The event log | Untouched. The gateway keeps its own record. |

Revoking stops the flow; it does not reach into the app. Whatever an app already received,
it still has. That is the reason to grant narrowly in the first place.

A revoked grant cannot be restored. The app requests access again, the user approves again,
and a new grant with a new token is created. A new webhook's cursor starts at the head of
the log, so an app that is approved again reads what it missed with
`GET /v1/events?since=<its last seq>`, if those events are still retained, or through
`history:read`.

The user can also reduce access without revoking: stopping the monitoring of a chat removes
it from every grant at once, as described above.

---

## Storing the token

Advice for your app:

- **Store the token the moment the poll returns `approved`.** The gateway hands it out for
  `10:00` and never again. Write it down before doing anything else with it.
- **Store it as a secret**: a secrets manager, an environment variable set from one, or a
  file with mode `0600` outside your repository. The token gives read access to chats the
  user chose; a leaked token is the user's data leaking.
- **Store the webhook secret beside it.** Without it you cannot verify deliveries. The only
  way to get a new one is `PUT /v1/me/webhook`, which invalidates the old one.
- **Store your cursor** (the `seq` of the last event successfully processed) with them.
  It allows the app to resume retained events after a restart
  ([integrating.md](integrating.md#connect-and-resume-with-since)).
- **On `401 token_revoked`, stop retrying** and tell a person. Only the user can restore
  access.
- **Never log the token.** Log `X-TGW-Request-Id` and `error.code` instead.
- **Use one grant per deployment.** Two copies of an app that share a token share a grant.
  Each keeps its own WebSocket cursor (the gateway allows 4 connections per token), but a
  webhook cursor is per grant, so two copies that each need a webhook need two grants.

---

## What the gateway guarantees

These hold by construction. None of them is a setting.

1. **Nothing unmonitored leaves the gateway.** The gateway never writes messages from
   unmonitored chats to its own store, and they never appear in an API response or an error
   message. (Telegram's library keeps its own encrypted cache of the account, which no other
   process can open.)
2. **Every app sees only its grant.** An app token cannot list the user's chats or probe
   whether a chat exists, and media access is checked against the grant's chats on every
   request, so one app cannot fetch another app's files by id.
3. **The gateway acts as the user only when told to.** A message is sent, forwarded,
   edited or deleted, a reaction or vote given, or a chat pinned, archived or muted, only
   on a request from the user (`tgw`, with the admin token) or from an app holding the
   scope for it, in a monitored chat in its grant. Nothing is done on the gateway's own
   initiative, and nothing is retried. It marks messages read only on such a request, for
   `tgw read` or an app holding `messages:mark_read`, when a person read the chat. It never
   opens chats in a way Telegram counts as viewing, sets the account online, shows
   "typing…", or joins or leaves groups and channels.
4. **The user sees who has what.** Every grant is visible in the menu bar app with its
   scopes, its chats, where it delivers, and when access began.
5. **Approval is a person's act.** Nothing automated can create or widen a grant.
6. **Revocation is total and immediate**, as described above.
7. **Local by default.** The API listens on `127.0.0.1` only. The only data that leaves the
   Mac is a webhook the user approved, sent to a URL whose host the user saw when approving,
   and signed so that the receiver can verify where it came from.

Two things the gateway does not guarantee, because it cannot:

- **What an app does with data it has received.** The gateway controls delivery, not use.
- **Isolation from other software on the Mac.** Any local process can call the two
  unauthenticated endpoints: `GET /v1/health`, which reveals whether the gateway is running
  and signed in but no chat data, and `POST /v1/access-requests`, which grants nothing until
  the user approves. A process running as the user's macOS account that reads the admin
  token's file holds the user's own authority over the gateway.

---

## Not supported

| Not supported | Instead |
|---|---|
| Any action on the account beyond those in [api.md](api.md#message-and-chat-actions) | Not possible. In particular, nothing joins a group or channel, edits or deletes another person's message, or marks a chat read on its own initiative. |
| Changing a grant's scopes or chat list after approval | The user revokes, and the app requests access again. A folder grant follows its folder without this. |
| Restoring a revoked grant | The app requests access again and receives a new token. |
| Token expiry or rotation | Tokens are valid until the grant is revoked. |
| An app asking for a folder by name | The app asks for chats or `"any"`; the user may answer with a folder. |
| Per-chat scopes | A grant's scopes apply to all of its chats. An app that needs different scopes for different chats uses two grants. |
| Monitoring secret chats | End-to-end encrypted chats are never monitored, so they can never be granted. |

The limits of the API as a whole are listed in [api.md](api.md#not-supported).
