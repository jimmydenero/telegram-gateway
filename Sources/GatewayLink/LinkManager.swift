import Foundation
import GatewayCore
import Logging

/// The gateway's links to Volgenic servers, one `GatewayLinkClient` per base URL, each
/// independent of the others. `apply` brings them in line with `config.json` and the secret
/// store; the daemon calls it at start and `ConfigReloader` on every reload.
public actor LinkManager: LinkReloading {
    public typealias ClientFactory = @Sendable (_ baseURL: String, _ token: String, _ handler: any LinkRequestHandling) throws -> GatewayLinkClient

    private let secrets: any SecretStore
    private let factory: ClientFactory
    private let clock: any GatewayClock
    private let logger: Logger
    private var handler: (any LinkRequestHandling)?
    private var clients: [String: GatewayLinkClient] = [:]
    /// Links in config.json that cannot run: no token in the secret store, or a bad URL.
    private var broken: [String: LinkStatus] = [:]
    /// Order of the links as configured.
    private var order: [String] = []
    private var stopped = false

    public init(secrets: any SecretStore, clock: any GatewayClock = SystemClock(), logger: Logger = Logger(label: "link"), factory: @escaping ClientFactory) {
        self.secrets = secrets
        self.clock = clock
        self.logger = logger
        self.factory = factory
    }

    /// The links' clients as the daemon builds them: URLSession, the event log, the
    /// Telegram handle.
    public init(
        secrets: any SecretStore, eventLog: EventLog, telegram: any TelegramControl, version: String,
        transport: any LinkTransport = URLSessionLinkTransport(), timing: LinkTiming = .standard,
        clock: any GatewayClock = SystemClock(), logger: Logger = Logger(label: "link")
    ) {
        self.init(secrets: secrets, clock: clock, logger: logger) { baseURL, token, handler in
            try GatewayLinkClient(
                baseURL: baseURL, token: token, transport: transport, handler: handler, eventLog: eventLog,
                telegram: telegram, version: version, timing: timing, clock: clock, logger: logger
            )
        }
    }

    /// How requests from Volgenic reach the API. Must be set before the first `apply`.
    public func setHandler(_ handler: any LinkRequestHandling) {
        self.handler = handler
    }

    public func apply(_ links: [LinkConfig]) async -> LinkReloadSummary {
        var summary = LinkReloadSummary()
        guard !stopped else { return summary }
        guard let handler else {
            logger.error("links not started: no request handler")
            return summary
        }
        let wanted = links.map(\.baseURL)
        for (url, client) in clients where !wanted.contains(url) {
            await client.stop()
            clients[url] = nil
            summary.stopped.append(url)
            logger.info("link to \(url) removed")
        }
        for url in broken.keys where !wanted.contains(url) { broken[url] = nil }
        order = wanted

        for url in wanted {
            let token: String?
            do {
                token = try LinkSettings.token(for: url, secrets: secrets)
            } catch {
                token = nil
                logger.error("link to \(url): cannot read its token from \(secrets.description): \(error)")
            }
            guard let token, LinkSettings.isValidToken(token) else {
                if let old = clients.removeValue(forKey: url) {
                    await old.stop()
                    summary.stopped.append(url)
                }
                broken[url] = LinkStatus(
                    baseURL: url, state: .noToken, since: broken[url]?.since ?? clock.now,
                    lastError: "no link token for \(url) in \(secrets.description); run tgw link add \(url) <token>", lastErrorAt: clock.now
                )
                continue
            }
            broken[url] = nil
            if let existing = clients[url] {
                let state = await existing.currentStatus().state
                if existing.token == token, state != .unauthorized {
                    summary.unchanged.append(url)
                    continue
                }
                await existing.stop()
                clients[url] = nil
                if await start(url, token: token, handler: handler) { summary.restarted.append(url) }
            } else if await start(url, token: token, handler: handler) {
                summary.started.append(url)
            }
        }
        return summary
    }

    private func start(_ url: String, token: String, handler: any LinkRequestHandling) async -> Bool {
        do {
            let client = try factory(url, token, handler)
            clients[url] = client
            await client.start()
            logger.info("link to \(url) started")
            return true
        } catch {
            broken[url] = LinkStatus(baseURL: url, state: .stopped, since: clock.now, lastError: "\(error)", lastErrorAt: clock.now)
            return false
        }
    }

    /// Every configured link's state, in `config.json` order.
    public func statuses() async -> [LinkStatus] {
        var result: [LinkStatus] = []
        for url in order {
            if let client = clients[url] {
                result.append(await client.currentStatus())
            } else if let status = broken[url] {
                result.append(status)
            }
        }
        return result
    }

    /// Closes every link (gateway shutdown).
    public func shutdown() async {
        stopped = true
        for (_, client) in clients { await client.stop() }
        clients.removeAll()
    }
}
