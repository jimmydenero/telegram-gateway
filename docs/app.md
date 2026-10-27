# The menu bar app

The Telegram Gateway menu bar app administers the background gateway service. It provides
Telegram sign-in, monitored-chat selection, application approval, and service controls.
A gateway managed by a **LaunchAgent**, a service macOS runs at login, continues running
after the menu bar app quits. A gateway started with **Run inside this app** stops with the app.

In this document, an **app** is a program that consumes the gateway API and requests access
to monitored chats. The program described here is "the menu bar app" or "Telegram Gateway".

It has two surfaces:

- **The menu bar popover** opens from the paper-plane icon. It is for a glance: how things
  are going, whether anything needs you, and a button to open the window. A dot on the icon
  means an app is waiting for your decision.
- **The window** is for everything else: first-run setup, and then four sections —
  **Overview**, **Chats**, **Apps** and **Gateway**.

## Contents

- [First run](#first-run)
- [Everyday use](#everyday-use)
- [How the gateway is started and kept running](#how-the-gateway-is-started-and-kept-running)
- [Troubleshooting](#troubleshooting)
- [For contributors](#for-contributors)

---

## First run

On first launch, the setup window presents three numbered steps: connect, sign in, and
choose chats.

### Before you start: an API ID and hash

Telegram asks every program that connects to it to identify itself with an **API ID** (a
number) and an **API hash** (32 characters, digits and the letters a–f). Together they are
client-application credentials, separate from the account's login session.

1. Go to https://my.telegram.org and log in with your phone number.
2. Open **API development tools** and create an application. Any name works; choose the
   platform **Desktop**.
3. Keep the page open: you need the **App api_id** and **App api_hash** it shows.

Use an API ID and hash registered for this client application.

### Step 1: Connect

The window shows **Connect to Telegram** with two fields, **API ID** and **API hash**, and a
link to my.telegram.org. Paste both values and click **Continue**.

Continue saves the key and makes the gateway use it. If a gateway is already running — for
example one you installed from the command line with `tgw daemon install` — it is told to
reload its settings; otherwise the menu bar app starts one. See
[How the gateway is started and kept running](#how-the-gateway-is-started-and-kept-running).
The window moves on to sign-in once the gateway has started its Telegram client, which
takes a few seconds.

macOS may show a notification that Telegram Gateway added an item that can run in the
background. That is the gateway; setup continues without waiting for you to act on it.

If it goes wrong:

- **A red line under a field** means the value cannot be right: the API ID must be a number,
  and the API hash must be exactly 32 characters.
- **A red card "The gateway didn't start"** gives the reason in one line and a **Show log**
  link. The button becomes **Try again**. The card also appears when the gateway itself is
  running but Telegram did not start in it, because signing in would not work then. The
  usual reasons are in [Troubleshooting](#troubleshooting).

### Step 2: Sign in

The window shows **Scan to sign in** with a QR code. On your phone:

1. Open Telegram.
2. Go to Settings → Devices → Link Desktop Device.
3. Point the camera at the code.

The code renews itself about every 30s; you do not need to do anything. If your account has
**two-step verification** (an extra password you set in Telegram under Settings → Privacy and
Security), the window then asks for that password and shows your hint under the field.

If you cannot scan, click **Use phone number instead**. You type your number with its country
code, Telegram sends a login code to your other devices or by SMS, and you type the code.
Two-step verification, if you have it, comes next as above.

If it goes wrong:

- **"Couldn't get a code"** replaces the QR code when the gateway could not obtain one. The
  reason is underneath, and **Refresh** tries again. "Telegram doesn't recognise the API ID
  and hash" means the key from step 1 is wrong: click **Change the Telegram key…** at the
  bottom of the window.
- **"That code isn't right."** or **"That password isn't right."** appears under the field;
  type it again. **Back** and **Start over** return to the beginning of sign-in.
- **"No Telegram account for this number"**: the gateway only signs in to an account that
  already exists. It never creates one.

### Step 3: Choose chats

Once you are signed in, the window shows its sidebar with **Chats** selected and a card:
"Pick the chats to monitor. Nothing else leaves the gateway."

Tick the chats and folders you want and click **Save**. Only messages in monitored chats are
stored and passed on; everything else in your account stays where it is. You can change the
set at any time. See [Chats](#chats) for the details.

---

## Everyday use

### The popover

Click the paper-plane icon in the menu bar. From top to bottom:

- **The state line.** When all is well it reads, for example, "Monitoring 3 chats" with
  "37 messages in the last hour · 4,812 total" beneath. When something is wrong the card
  turns amber or red and says what: "Not set up yet", "Not signed in", "Reconnecting…",
  "Not monitoring any chats", "Gateway not running", "Can't control the gateway".
- **Needs you.** Shown only when there is something for you to do: an app waiting for a
  decision ("Community Analytics wants access"), a delivery that stopped ("Archive: delivery
  paused"), or whatever keeps the gateway from working ("Sign in to Telegram", "Start the
  gateway", "Choose chats to monitor"). Clicking a row opens the window at the place where
  you deal with it.
- **Open Telegram Gateway…** opens the window (or brings it to the front).
- **Restart gateway** restarts the gateway, whichever way it was started, and waits for it
  to answer again.
- **Quit** quits the menu bar app. The line beneath says whether the gateway keeps running
  (the normal case) or stops too (see [the in-app fallback](#in-plain-terms)).

Colour always means state: green is fine, amber is waiting or needs you, red has failed.

### Overview

The first section of the window answers three questions.

- **Is it working?** The same state line as the popover, across the top. When something is
  wrong the card carries the one action that fixes it: **Choose chats**, **Start gateway**,
  **Try again**, **Restart gateway**. "Reconnecting…" has no action; the gateway catches up
  on missed messages by itself when Telegram is reachable again.
- **Does anything need me?** A **Needs you** card appears only when it has something in it:
  pending requests (**Review…**) and deliveries that stopped or are failing (**Resume**).
- **Which apps are connected?** One row per app with access and its state: a green dot with
  how long ago it last received something ("1m ago"), or amber "Paused" or "Failing".

A line at the bottom shows the gateway's version and how long it has been running.

### Chats

A table of every chat and folder in your account, with a checkbox for what the gateway
monitors.

| Column | Shows |
|---|---|
| Monitored | The checkbox. |
| Chat | An icon for the kind of chat, and its title. |
| Type | Folder, Channel (only admins post), Group, or Person (a one-to-one chat). |
| Members | The member count, or the number of chats in a folder. |
| Username | The public handle, such as @acmeupdates, when the chat has one. |

Click a column header to sort. The control in the toolbar switches between **Monitored**,
**Folders** and **All**, and the search field filters by title or username. Unsorted,
monitored rows come first.

**Folders.** A folder is one of the tabs you made in Telegram to group chats ("Product",
"News"). Ticking a folder monitors whatever is in it: when you add a channel to the folder on
your phone, the gateway starts monitoring it without another visit here, and when you remove
one it stops. A chat that is covered by a ticked folder is shown ticked and locked, with
"via Product folder" under its title.

**Saving.** Ticks are a draft until you save. The bar at the bottom reads "3 monitored" until
you change something, then "2 unsaved changes" with **Revert** and **Save** (Cmd-S). Saving
replaces the whole monitored set at once. The gateway starts watching newly ticked chats
within a few seconds. Messages sent before a chat was monitored are not collected
retroactively; apps with the *Past messages* permission can still read them from Telegram.

When you stop monitoring a chat, every app that could read it loses it at once. If you
monitor it again later, those apps get it back without a new approval.

### Apps

An app gets access by asking the gateway for it; you approve or deny here. Nothing an app
does on its own can give it access or widen what it has. The full model is in
[grants.md](grants.md).

The section has a list on the left and the selected item on the right.

**The list.** **Wants access** comes first: each pending request with an amber dot and the
time it has left ("13 min left"; a request expires 15:00 after it was made, and the app can
simply ask again). **Has access** lists the apps you approved, each with its state and one
line such as "2 chats · new messages, chat names".

**Reviewing a request.** Select it to see who is asking and for what:

- the app's name and its own description of what it does with your messages;
- **Wants** — the permissions it asked for;
- **In** — the chats it asked for, with an amber "not monitored yet" on any the gateway does
  not monitor;
- **Sends to** — if the app receives messages by webhook (the gateway calls a web address
  the app runs), the host of that address.

**Deny** refuses the request. **Review…** opens a sheet, "Give Community Analytics access",
where you decide exactly what it gets:

- **Chats.** The chats it asked for, ticked. Untick any you do not want to share. A chat
  marked "Not monitored yet — approving starts monitoring it" is added to the monitored set
  when you approve with it ticked. "Show 1 other monitored chat" lists the rest of what you
  monitor, in case you want to give more than was asked. **Follow a folder instead** grants
  one of your monitored folders: the app then sees whatever is in the folder, including chats
  you add later.
- **Can read.** One checkbox per permission it asked for. You can remove permissions; you
  cannot add ones it did not ask for.
- **Can act as you.** Only when the app asked to act on your account: a checkbox for each
  of "Send and react" and "Manage chats" it asked for. Untick one to let the app do the rest
  without it. (This section is written but has not yet been built or run.)

The bar at the bottom summarises the decision ("3 chats · 3 permissions"). **Approve** gives
the app its access; **Cancel** leaves the request pending.

**What each permission means.** The identifier is what the app's developer sees in
[api.md](api.md).

| On screen | Identifier | The app can |
|---|---|---|
| New messages | `messages:read` | Receive every message in its chats as it arrives, with edits and deletions. |
| Past messages | `history:read` | Read messages from before it was connected, as far back as your account can see. |
| Photos and files | `media:read` | Download what is attached to those messages. Without it, the app sees that a message has a photo, not the photo. |
| Chat names and details | `chats:read` | See the titles, usernames and member counts of its chats. |
| Send and react | `messages:send` | Act on messages **as you** in its chats: send messages and files, forward, edit and delete what you sent, react, and vote in polls. People in those chats see it as you. Shown under its own heading, **Can act as you**, when approving and in the app's detail. |
| Manage chats | `chats:manage` | Pin, archive and mute its chats, which changes how they appear in your own Telegram apps, and look up a chat by username or phone number. Also under **Can act as you**. |

An app only ever sees chats that are both granted to it and currently monitored.

**An app's detail.** Select an app under **Has access** to see what it can read, whether it
can act as you (under **Can act as you**), which chats
it has (a chat you no longer monitor says so in amber), and how it receives messages:
**Sends to** with the host and the last delivery for a webhook, or "Directly to the gateway"
with when it was last connected.

**A paused delivery.** If an app's webhook stops answering, the gateway keeps retrying for
24:00:00 and then pauses. The app's row turns amber ("Paused"), it appears under Needs you,
and its detail shows a card with the reason and how many messages are waiting. None are lost:
**Resume** continues from where it stopped. While the gateway is still retrying, the row
reads "Failing".

**Revoking.** **Revoke access…** at the bottom of an app's detail ends its access after a
confirmation. It takes effect immediately and cannot be undone: the app has to ask again and
you approve again.

### Gateway

Everything about how the gateway itself runs. No other screen shows any of this.

- **Gateway**: whether it is running, its local address (`127.0.0.1:41414` by default), its
  version, when it started and for how long it has been up, and whether it starts at login.
- **Controls**:
  - **Restart** restarts the gateway that is running: the one inside the menu bar app, the
    one the menu bar app registered to start at login, or one installed from the command line
    with `tgw daemon install`. If there is none, it says so.
  - **Start at login** — **Turn on** registers the gateway with macOS so it starts when you
    log in and keeps running after the menu bar app quits. **Turn off** stops it and removes
    the registration.
  - **Allow at login** appears when macOS is waiting for your permission; **Open settings**
    takes you to the right place in System Settings.
  - **Run inside this app** runs the gateway as part of the menu bar app instead. It stops
    when the menu bar app quits.
  - **Log** — **Show log** opens the gateway's log file.
- **Telegram**: the account you are signed in as (for example Ada Lovelace, @ada) with
  **Sign out…**, and the API ID and hash with **Edit…**.
  - Signing out ends the Telegram session on this Mac. Your monitored chats, the apps you
    approved and the messages already collected are kept; nothing new arrives until you sign
    in again.
  - Edit… reopens step 1 so you can paste a different key. Continue makes the running
    gateway reload it, and returns here once Telegram is up with the new key.
- **Files**: where the gateway program, its settings file and its log are.

---

## How the gateway is started and kept running

### In plain terms

The gateway is a separate background program. Telegram Gateway (the menu bar app) starts it
for you and you never have to choose how.

- **The normal way: start at login.** The menu bar app registers the gateway with macOS as a
  **login item** — something macOS starts when you log in and restarts if it stops. Once
  registered, the gateway runs whether or not the menu bar app is open. macOS lists it under
  System Settings → General → Login Items & Extensions → Allow in the Background, and may
  ask you to allow it the first time.
- **The fallback: run inside the app.** If macOS has not allowed the login item yet, or
  registering fails, the menu bar app runs the gateway itself so that setup is never blocked.
  A gateway run this way stops when you quit the menu bar app. The **Gateway** section shows
  which way is in use ("Starts at login: Yes", "No, runs inside this app", or "Waiting for
  your approval") and has the switch to change it.

A gateway you installed yourself from the command line (`tgw daemon install`, see
[development.md](development.md)) is a login item too, under its own name. The menu bar app
works with it as it is: it does not start a second gateway, Continue asks it to reload its
settings, and Restart gateway restarts it.

To move from the fallback to the normal way: allow Telegram Gateway in System Settings
(**Allow at login → Open settings**), then in the Gateway section click **Run inside this app
→ Stop** and **Start at login → Turn on**.

### The technical detail

A **LaunchAgent** is a service that launchd, the macOS service manager, runs as the logged-in
user. The menu bar app carries one inside its bundle and registers it with Apple's
`SMAppService` API, which is what makes it appear under Login Items.

- The agent's property list is at `Contents/Library/LaunchAgents/
  local.telegram-gateway.daemon.plist` in the app bundle. `RunAtLoad` and
  `KeepAlive` are true, so launchd starts the gateway on registration and at every login and
  restarts it if it exits (at most once every 10s).
- Its program is `Contents/Resources/gateway-launcher`, a shell script that finds the gateway
  binary (`GatewayDaemon`), creates `~/Library/Logs/TelegramGateway/`, and replaces itself
  with the gateway, appending its output to `~/Library/Logs/TelegramGateway/daemon.log`.
- The script looks for the binary in this order: the `TGW_DAEMON_PATH` environment variable;
  `daemon_path` in `~/Library/Application Support/TelegramGateway/config.json` (written by
  the menu bar app when it starts the gateway); `Contents/MacOS/GatewayDaemon` in the bundle.

What **Continue**, **Start gateway** and **Try again** do:

1. **If a gateway already answers on its port**, ask it to reload: `POST /v1/admin/reload`.
   The gateway reads `config.json` again and starts, or recreates, its Telegram session in
   place, without restarting. It does not matter who started that gateway.
   - If the reload reports that Telegram is still disabled, the gateway read a configuration
     without a key: show the failure with that reason.
   - If the gateway is too old to have the endpoint (it answers 404), or reports that a
     setting needs a full restart (`restart_required`, for example a changed `port`), restart
     it as described under "Restart gateway" below and wait up to 8s for it to answer again.
2. **Otherwise start one.** Register the LaunchAgent and wait up to 8s for the gateway to
   answer `GET /v1/health`. If it does not — macOS wants approval first, registration failed,
   or the gateway stayed silent — run it as a child process of the menu bar app and wait up
   to 8s again. A registered agent that stayed silent is unregistered first, so only one
   gateway ever runs. The child's output goes to
   `~/Library/Logs/TelegramGateway/daemon-foreground.log`.
3. **Wait for Telegram.** A gateway that answers is not enough. For up to 8s, wait until
   `tdlib.auth_state` in `GET /v1/health` is something other than `unknown` (which is what a
   gateway without a Telegram session reports). Only then does setup move on to sign-in.
4. If any of this fails, show "The gateway didn't start" with the reason: the last line of
   the log, "It didn't answer on port 41414.", "The gateway is running without the Telegram
   key…", or "The gateway is running, but Telegram didn't start in it."

What **Restart gateway** does: it restarts whichever gateway is running and then waits for it
to answer.

1. The child process, if the menu bar app is running the gateway itself: stop it and start
   it again.
2. Otherwise the menu bar app's own LaunchAgent, if it is registered:
   `launchctl kickstart -k gui/<uid>/local.telegram-gateway.daemon`.
3. Otherwise the LaunchAgent that `tgw daemon install` registers:
   `launchctl kickstart -k gui/<uid>/local.telegram-gateway`.
4. If none of these exists: "No running gateway was found to restart."

| You do | The menu bar app does | launchd does |
|---|---|---|
| Continue, Start gateway, Try again | reloads a running gateway, or starts one as above | for a new registration: loads the agent and runs it now and at every login |
| Start at login → Turn on | writes `daemon_path`, registers the agent | the same |
| Start at login → Turn off | unregisters the agent | stops the gateway and forgets the agent |
| Run inside this app → Run / Stop | starts or stops a child process | nothing |
| Restart gateway | restarts the child, or `launchctl kickstart -k` for the registered label | restarts the gateway |
| Quit | quits, stopping a child-process gateway | nothing: a registered gateway keeps running |

The menu bar app talks to the gateway over its local HTTP API ([api.md](api.md)) with the
gateway's **admin token**, the one credential allowed to call the administrative endpoints.
The gateway writes it to `~/Library/Application Support/TelegramGateway/secrets.json`
(readable only by you) on its first start, and the menu bar app reads it from there. Why the
gateway is a separate process at all is explained in [architecture.md](architecture.md).

---

## Troubleshooting

**"Gateway not running", or "The gateway didn't start".** The menu bar app asks the gateway
how it is every few seconds and got no answer.

- Read the one-line reason on the red card, then **Show log**.
- "The gateway program is missing": the gateway binary is not where the menu bar app looks.
  In a development checkout, build it with `swift build` ([development.md](development.md)).
  Gateway → Files → Program shows the path in use.
- "It didn't answer on port 41414": something else may be using the port (the log says
  "Address already in use"), or `port` in
  `~/Library/Application Support/TelegramGateway/config.json` is not the port you expect.
- `launchctl print gui/$(id -u)/local.telegram-gateway.daemon` shows launchd's
  view. `state = not running` with a non-zero `last exit code` means the gateway stops right
  after starting; the log says why.
- Gateway shows "Starts at login: Needs setting up again": the menu bar app was moved since
  it registered the gateway. Click **Start at login → Turn on**.

**"The gateway is running, but Telegram didn't start in it".** The gateway answers, but its
Telegram connection stayed off after it was given the key.

- **Show log**: the gateway logs why its Telegram session could not start.
- **Try again** repeats the reload. If it keeps failing, **Restart gateway** (in the popover)
  starts the gateway afresh.

**"The gateway is running without the Telegram key".** The gateway that answered read a
settings file with no API ID and hash in it, although you just saved them. It is probably
using a different data directory than the menu bar app: a gateway started with `TGW_HOME` or
`--home` reads `config.json` there. Start the gateway without that setting, or launch the
menu bar app with the same `TGW_HOME`.

**"No running gateway was found to restart".** Restart gateway looks for the gateway inside
the menu bar app, then the one it registered to start at login, then one installed with
`tgw daemon install`. A gateway started by hand in a terminal is none of these; stop it there
and start it again.

**"Can't control the gateway".** The gateway is running but the menu bar app cannot read its
access key (the admin token in `secrets.json`).

- If the gateway only just started, click **Check again**.
- **Restart gateway** makes the gateway write a new key.
- The line under the message names the problem when the file exists but cannot be read.

**The QR code does not scan, or the phone says it expired.** Keep the window open while you
scan; the code is renewed about every 30s and redrawn within 2s. If nothing happens after a
successful scan, your account probably has two-step verification and the window is already
asking for the password.

**"Telegram doesn't recognise the API ID and hash".** The key from step 1 is wrong. Click
**Change the Telegram key…** on the sign-in screen, or Gateway → Telegram → **Edit…**, and
paste the values from my.telegram.org again.

**The gateway stops when I quit Telegram Gateway.** It is running inside the app rather than
as a login item. See [In plain terms](#in-plain-terms) for how to switch.

**"Starts at login: Waiting for your approval".** Open System Settings → General → Login
Items & Extensions and switch on **Telegram Gateway** under **Allow in the Background**, then
click **Start at login → Turn on** in the Gateway section.

**An app says it receives nothing.** Check, in this order: the chat is ticked in Chats; the
chat is in the app's list in Apps (an unmonitored one is marked in amber); the app's state is
not "Paused"; the state line does not say "Reconnecting…" or "Not signed in".

**I quit the menu bar app and want to stop the gateway too.** Gateway → **Start at login →
Turn off** stops it and keeps it from starting again. From a terminal:
`launchctl bootout gui/$(id -u)/local.telegram-gateway.daemon`.

**The window does not open.** It opens from **Open Telegram Gateway…** in the popover, from a
Needs you row, and by itself when setup or sign-in is needed. If the paper-plane icon is
missing from the menu bar, the menu bar app is not running; launch it again.

---

## For contributors

Everything above describes what a person running the gateway sees. This section is for
people working on the code in `App/`.

### Project layout

```
App/
  TelegramGateway.xcodeproj    Xcode project (synchronized folders: no file lists to maintain)
  project.yml                  XcodeGen description of the same project
  run.sh                       build and launch; --test runs the unit tests
  snapshot.sh                  renders every screen state to PNG
  Support/Info.plist           LSUIElement; TGWRepositoryRoot (development only)
  Support/gateway-launcher     the script launchd runs
  Support/LaunchAgents/…plist  the LaunchAgent
  TelegramGateway/
    TelegramGatewayApp.swift   the two scenes (MenuBarExtra, Window), commands, menu bar icon
    API/                       APIClient protocol, HTTPAPIClient, FakeAPIClient, models
    Services/                  GatewayConfig, AdminToken, DaemonManager, QRCodeImage, Wording
    State/AppModel.swift       all state and decisions; views only render it
    Views/Design.swift         type scale, cards, rows, shared styles
    Views/Popover/             the popover
    Views/Window/              MainWindow, SetupFlow, and one file per section
    Debug/SnapshotRunner.swift --snapshot mode (Debug builds only)
  TelegramGatewayTests/        unit tests (Swift Testing)
```

The app targets macOS 15, uses Swift 6 with strict concurrency, and has no third-party
dependencies. It is ad-hoc signed, not sandboxed (it runs `launchctl` and, in development,
the gateway binary).

### Building and testing

Requirements: Xcode 26. For anything past step 1 you also need the gateway binary:
`swift build` in the repository root ([development.md](development.md)).

```
# Build (Debug):
xcodebuild -project App/TelegramGateway.xcodeproj -scheme TelegramGateway -configuration Debug build

# Build into App/.derived and launch, replacing a running copy:
App/run.sh

# Unit tests (about 1s; no gateway, no Telegram account, no windows):
App/run.sh --test
```

`App/TelegramGateway.xcodeproj` is checked in and builds from a clean checkout.
`App/project.yml` describes the same project for [XcodeGen](https://github.com/yonaskolb/XcodeGen);
if you change the project's structure, keep the two in step.

### The API client and the fake gateway

Every call the menu bar app makes to the gateway goes through the `APIClient` protocol
(`API/APIClient.swift`), whose methods mirror the administrative endpoints in
[api.md](api.md).

- `HTTPAPIClient` is the real one: JSON over HTTP to `127.0.0.1` on the configured port, with
  the admin token read on every request.
- `FakeAPIClient` is an in-memory gateway with the same behaviour where it matters: the
  sign-in state machine (QR, phone, code, password), chats and folders, the monitored set,
  requests turning into grants, revocation, a paused delivery, and reloading its
  configuration (including a gateway without the endpoint). It starts in a named `Scenario`
  (`.loggedOut`, `.waitingForQR`, `.loggedIn`, `.reconnecting`, `.telegramDisabled`,
  `.unreachable`, …).

`AppModel.preview(_:)` builds a model over the fake. Previews, unit tests and snapshots all
use it, so none of them needs a gateway, reads `secrets.json`, registers anything with
launchd, or writes `config.json`. The unit tests cover decoding of the examples in api.md,
the QR link handling, the wording table, and every flow in `AppModel`.

`AppModel` decides; views render. Which screen is shown (`screen`), the state line (`hero`),
what needs attention (`needsYou`), the monitored-set draft and the approval draft are all
computed or held there, which is what makes them testable without a view.

Words shown on screen come from one place, `Services/Wording.swift`: permission names,
relative times, the chat subtitle, and the translation of Telegram's error codes. Identifiers
from the API appear on screen only as tooltips.

### The visual system

`Views/Design.swift` defines the pieces every screen is built from:

- a type scale (screen title 15 semibold, row title 13 medium, body 13, secondary 11, section
  label 11 semibold, and the 20 semibold state line);
- inset rounded cards, with dividers only between rows inside a card;
- at most one prominent button per screen;
- colour for state only: green fine, amber waiting or needs attention, red failed.

The window uses native controls. The popover draws its one prominent button itself
(`PrimaryButtonStyle`), because a menu bar popover is not always the key window and AppKit
greys prominent buttons in an inactive one.

### Checking screens with snapshots

Debug builds provide snapshot mode for rendering screen states as PNG files in light and
dark appearances:

```
App/run.sh --no-launch                # or any Debug build
App/snapshot.sh /tmp/shots            # every state
App/snapshot.sh /tmp/shots --only w2  # a subset, by file-name prefix
```

Files named `p…` are popover states, `w…` window states (the review sheet included). The app
steps through the states with the fake gateway. It renders popover and sheet states itself;
for window states it shows a real window and the script photographs it with
`screencapture -l`, because an in-process render cannot see the sidebar. The terminal needs
Screen Recording permission for that.

Published screenshots belong in `docs/screenshots/` so documentation viewers can load them
without accessing a parent directory. Capture them with the fake gateway, without `--live`.
Use the sample account and chats in `FakeAPIClient`; the sign-in QR code must also come from
the fake client's fixture tokens. Before publishing, inspect both appearances for account
names, phone numbers, credentials, local usernames, notifications, and image metadata.
Keep the light and dark variants paired in the documentation's `<picture>` elements.

Windows that are not frontmost are drawn by macOS with grey controls. That is fine for
checking layout. `--key` brings each window to the front so controls show their real colours;
it takes keyboard focus for the whole run (about 01:40), so use it only when nobody is
working at the machine.

When you review snapshots, ask of each screen: can the main question be answered in two
seconds; does each region hold one kind of information; are routine states quiet and
exceptions visible; is there at most one prominent button; does any text merely narrate.

`TelegramGateway --snapshot <directory> --live` instead drives the real `HTTPAPIClient`
through a scripted sign-in, chats and apps flow against whatever answers on the configured
port. Set `TGW_HOME` to a scratch directory and `TGW_PORT` to a second gateway's port so it
stays away from your real data.

### Window behaviour

The app is an `LSUIElement` application: on launch it has no Dock icon, only the menu bar
icon.

- There is exactly one main window (a SwiftUI `Window` scene, 820×560 by default, 700×460 at
  least). Every way of opening it goes through `AppModel.requestWindow()`; the menu bar label
  view observes the request and calls `openWindow` and `WindowCoordinator.focus()`. Asking
  again re-focuses the window; there is no New Window command, and Cmd-, re-focuses it too.
- The window opens by itself when setup or sign-in becomes necessary, once per occurrence.
  Launching the app when everything is fine opens nothing (`.defaultLaunchBehavior(.suppressed)`).
- While the window is open the app is a regular app (`.regular` activation policy): Dock
  icon, Cmd-Tab, and Edit and Window menus, so paste, Cmd-W and Return work. When the window
  closes it goes back to `.accessory`. Closing the window never quits the app.

### Configuration and secrets

The menu bar app and the gateway share `~/Library/Application Support/TelegramGateway/`
(`TGW_HOME` overrides the directory, `TGW_PORT` the port).

- `config.json` holds `api_id`, `api_hash`, `port` and `daemon_path`. The menu bar app merges
  its keys into the file and leaves every other key untouched.
- `secrets.json` holds the admin token. Setting `"secrets": "keychain"` in `config.json`
  makes both programs use the login Keychain instead. That is meant for a build signed with a
  stable identity: an ad-hoc-signed development build is a new program to the Keychain after
  every rebuild, and each read would ask for your password.

### Not yet bundled

The gateway binary and its Telegram library are not inside the app bundle yet. A development
build finds `<repository>/.build/debug/GatewayDaemon` through `TGWRepositoryRoot` in its
Info.plist (set from the project's location at build time) or by walking up from the app's
own location to the repository. A distributable build needs a build phase that copies the
release binary and its library into `Contents/MacOS/` — the launcher script already looks
there — and a stable signing identity. [status.md](status.md) tracks what is done.
