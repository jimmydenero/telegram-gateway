import ArgumentParser
import Foundation
import GatewayCore
import GatewayLink
import GatewayServer
import Logging
import ServiceLifecycle
import TDLibClient

/// The gateway daemon (docs/architecture.md "The gateway service"): the one process that owns TDLib, the event log,
/// the HTTP + WebSocket API and webhook delivery. Started by launchd; `GatewayDaemon --verbose`
/// in a terminal for development.
@main
struct GatewayDaemonCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "GatewayDaemon",
        abstract: "Telegram Gateway daemon: owns TDLib, records events, serves the local API."
    )

    static let version = "0.1.0"

    @Flag(help: "Log at debug level.")
    var verbose = false

    @Option(help: "Data directory (default: TGW_HOME or ~/Library/Application Support/TelegramGateway).")
    var home: String?

    @Option(help: "Port to bind on 127.0.0.1 (default: TGW_PORT, then config.json, then 41414).")
    var port: Int?

    func run() async throws {
        let paths = home.map { Paths(home: URL(filePath: $0, directoryHint: .isDirectory)) } ?? Paths.resolve()
        try paths.prepare()
        var loaded = try Config.load(paths: paths)
        if let port { loaded.port = port }
        let config = loaded

        let level: Logger.Level = verbose ? .debug : .info
        LoggingSystem.bootstrap { label in
            var handler = StreamLogHandler.standardError(label: label)
            handler.logLevel = level
            return handler
        }
        let logger = Logger(label: "daemon")

        let lock: InstanceLock
        do {
            lock = try InstanceLock.acquire(paths: paths, role: "daemon")
        } catch let error as GatewayError {
            logger.error("cannot start: \(error.description)")
            throw ExitCode(1)
        }
        defer { withExtendedLifetime(lock) {} }

        let secrets = Secrets.resolve(config: config, paths: paths)
        let adminToken = try Secrets.adminToken(secrets)
        let store = try Store.open(paths: paths)
        let clock = SystemClock()
        let startedAt = clock.now

        // One stable handle on Telegram. It holds a TDLib session when config.json has an
        // api_id / api_hash, and none otherwise; `POST /v1/admin/reload` changes that while
        // the gateway runs. Without a session the store-backed API still works.
        let host = TelegramHost(logger: Logger(label: "telegram")) { credentials in
            let parameters = TDLibParameters(
                apiId: credentials.apiId, apiHash: credentials.apiHash, databaseDirectory: paths.tdlib.path,
                filesDirectory: paths.tdlibFiles.path, databaseEncryptionKey: try Secrets.databaseKey(secrets),
                applicationVersion: GatewayDaemonCommand.version
            )
            return TelegramSession(parameters: parameters, logger: Logger(label: "telegram"))
        }
        let telegram: any TelegramControl = host
        let tdlib: any TDLibRequesting = host

        let translator = Translator(tdlib: tdlib)
        let eventLog = EventLog(store: store, clock: clock)
        let grants = Grants(store: store, adminToken: adminToken, clock: clock)
        let accessRequests = AccessRequests(store: store, grants: grants, clock: clock)
        let monitor = Monitor(store: store, eventLog: eventLog, translator: translator, tdlib: tdlib, clock: clock, logger: Logger(label: "monitor"))
        let mediaCache = MediaCache(store: store, tdlib: tdlib, maxBytes: config.mediaCacheMaxBytes, clock: clock, logger: Logger(label: "media"))
        let dispatcher = WebhookDispatcher(store: store, eventLog: eventLog, grants: grants, http: URLSessionWebhookClient(), clock: clock, logger: Logger(label: "webhooks"))
        let rateLimiter = RateLimiter(clock: clock)
        let uploads = paths.home.appending(path: "uploads")
        MessageSender.removeStaleUploads(in: uploads, olderThan: clock.now.addingTimeInterval(-24 * 3600))
        let sender = MessageSender(grants: grants, translator: translator, telegram: telegram, rateLimiter: rateLimiter, clock: clock, uploadDirectory: uploads)
        let shutdown = ShutdownSignal()

        try await monitor.load()
        await dispatcher.start()
        // The monitor records each update first, so a message this gateway sent is in the log
        // as message.new by the time the sender learns it went through.
        let monitorTask = Task {
            for await update in host.updates {
                await monitor.handle(update: update)
                await sender.observe(update)
            }
        }
        if try await host.apply(TelegramCredentials(config: config)) == .disabled {
            logger.warning("no api_id / api_hash in \(paths.config.path); Telegram is disabled until they are added and the gateway is reloaded (`tgw daemon reload`)")
        }
        // Links to Volgenic (docs/link.md): URLs from config.json, tokens from the secret store.
        let links = LinkManager(secrets: secrets, eventLog: eventLog, telegram: telegram, version: GatewayDaemonCommand.version, logger: Logger(label: "link"))
        let reloader = ConfigReloader(paths: paths, running: config, host: host, links: links)
        let housekeeping = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3600))
                await Maintenance.sweep(accessRequests: accessRequests, grants: grants, rateLimiter: rateLimiter)
                if let days = config.eventsRetentionDays {
                    do {
                        let (deleted, oldest) = try await Maintenance.applyRetention(days: days, clock: clock, eventLog: eventLog, grants: grants)
                        if deleted > 0 { logger.info("retention: deleted \(deleted) events, oldest seq is now \(oldest)") }
                    } catch let error as APIError where error.code == "cursor_behind" {
                        logger.warning("retention skipped: \(error.message)")
                    } catch {
                        logger.error("retention failed: \(error)")
                    }
                }
            }
        }

        let deps = Dependencies(
            store: store, eventLog: eventLog, grants: grants, accessRequests: accessRequests, monitor: monitor,
            translator: translator, mediaCache: mediaCache, sender: sender, dispatcher: dispatcher, telegram: telegram,
            reloader: reloader, links: links, rateLimiter: rateLimiter, clock: clock, config: config, shutdown: shutdown, startedAt: startedAt,
            version: GatewayDaemonCommand.version, logger: Logger(label: "server")
        )
        let app = GatewayServer.buildApplication(deps: deps, port: config.port, logger: Logger(label: "http"))
        // Requests from Volgenic run through the same router, in process, as the admin.
        await links.setHandler(InProcessAPI(deps: deps, adminToken: adminToken))
        _ = await links.apply(config.links)
        let group = ServiceGroup(configuration: .init(services: [app], logger: logger))

        // SIGTERM / SIGINT: tell WebSocket clients we are going away (1001), then stop the
        // server, then close TDLib so its binlog is flushed.
        let signals = SignalWatcher(signals: [SIGTERM, SIGINT]) {
            logger.info("shutting down")
            Task {
                await links.shutdown()
                await shutdown.trigger()
                try? await Task.sleep(for: .milliseconds(300))
                await group.triggerGracefulShutdown()
            }
        }
        logger.info("Telegram Gateway \(GatewayDaemonCommand.version) listening on http://127.0.0.1:\(config.port), data in \(paths.home.path), secrets in \(secrets.description)")
        try await group.run()

        housekeeping.cancel()
        await dispatcher.shutdown()
        await host.shutdown()
        monitorTask.cancel()
        withExtendedLifetime(signals) {}
        logger.info("stopped")
    }
}

/// Keeps `DispatchSourceSignal`s alive for the life of the process.
final class SignalWatcher: Sendable {
    private let sources: [DispatchSourceSignal]

    init(signals: [Int32], handler: @escaping @Sendable () -> Void) {
        sources = signals.map { number in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler(handler: handler)
            source.resume()
            return source
        }
    }
}
