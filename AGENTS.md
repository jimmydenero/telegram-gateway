# Working in this repository

Instructions for coding agents and human contributors alike.

Read `README.md` first, then `docs/architecture.md`. `docs/getting-started.md` is the
walkthrough for someone setting it up. To build, test and run:
`docs/development.md`. The contract apps rely on is `docs/api.md`, `docs/events.md` and
`docs/grants.md`. `docs/status.md` says what works and what is planned.

## Rules

- **Capability before UI.** A feature exists as a library function first, then as a `tgw`
  command, then as an API endpoint, and only then in the menu bar app. Never build UI for
  something that does not work from the command line.
- **Only the gateway loads TDLib.** TDLib is Telegram's client library; its data directory
  can be open in one process at a time. Nothing else opens that directory, and two TDLib
  instances never run on it. See "Why exactly one process owns TDLib" in
  `docs/architecture.md`.
- **Apps never see TDLib's JSON.** Everything that crosses the API is in the format defined
  in `docs/events.md` and `docs/api.md`. If you change the format, change the document in
  the same commit.
- **Send only through `MessageSender`, and only when a person asked.** The gateway runs on a
  real personal Telegram account. A message is sent only for an app holding an approved
  `messages:send` grant for that chat, or for the owner's own `tgw send`; both go through
  `MessageSender`, the one caller of `sendMessage`. Never send from tests, fakes, scripts or
  debugging tools against a real account: tests use `FakeTDLib`, which sends nothing.
- **Never mark anything as read or make the account appear online**, from any code path,
  including tests and debugging tools. That means no `viewMessages` or `openChat`, and the
  `online` option stays false.
- **Never commit secrets or build artifacts**: no `api_id` or `api_hash`, no tokens, nothing
  from `~/Library/Application Support/TelegramGateway/`, and not the built TDLib library.
- **Use the pinned TDLib commit** in `vendor/tdlib/COMMIT`. Changing it is a deliberate
  change of its own, with the translator's fixtures checked against the new schema.
- **Swift 6 with strict concurrency.** Anything that holds SQLite or TDLib state is an actor.
  No force-unwrapping of data that comes from outside the process.
- **`swift build` and `swift test` pass before you hand work back.** New behaviour comes with
  tests. Tests need no Telegram account and no network: TDLib sits behind the
  `TDLibRequesting` protocol and time behind `GatewayClock`, so use the fakes in
  `Sources/GatewayTestSupport`.
- **Development builds and tests must not read the macOS Keychain.** A binary from
  `swift build` is ad-hoc signed and looks like a new program to the Keychain after every
  rebuild, so each read stops and asks the person at the keyboard for their login password.
  Secrets go through `SecretStore`: the file store by default, `InMemorySecretStore` in
  tests. Never construct `KeychainSecretStore` in a test, and never run a command in
  Keychain mode while developing.
- **Documentation lives in `docs/` and changes with the code.** Write for a reader who has
  never used Telegram's API: define each term the first time it appears, describe how the
  system works now, and give durations of a minute or more as `mm:ss`.
- **Commit messages** have a subject and a body, and no attribution trailers.
