import Foundation

/// One outbound link to a Volgenic server (docs/link.md), as `config.json` lists it:
/// `"links": [{"base_url": "https://volgenic.com"}]`. The link token lives in the secret store
/// under `LinkSettings.secretAccount(for:)`.
public struct LinkConfig: Sendable, Equatable, Hashable {
    /// Normalised: lowercase `http` or `https` scheme and host, no trailing slash, no query.
    public var baseURL: String

    public init(baseURL: String) {
        self.baseURL = baseURL
    }

    public var json: JSONValue { ["base_url": .string(baseURL)] }

    /// Reads the `links` array of `config.json`. Each entry needs a valid `base_url`; two
    /// entries for the same base URL are one link.
    static func parse(_ raw: JSONValue) throws -> [LinkConfig] {
        guard let items = raw.arrayValue else { throw GatewayError.invalidConfig("links must be an array of {\"base_url\": …}") }
        var links: [LinkConfig] = []
        for item in items {
            guard let url = item["base_url"]?.stringValue else { throw GatewayError.invalidConfig("each entry of links needs a base_url string") }
            let link = LinkConfig(baseURL: try LinkSettings.normalize(url))
            if !links.contains(link) { links.append(link) }
        }
        return links
    }
}

/// Storage and validation of links: URLs in `config.json`, tokens in the secret store.
/// `tgw link add/remove` write through here; the gateway reads the same places on reload.
public enum LinkSettings {
    /// The path on the Volgenic server that the gateway dials.
    public static let endpointPath = "/messages/telegram/link"

    /// The secret-store account holding the token of the link to `baseURL`.
    public static func secretAccount(for baseURL: String) -> String { "link-token:" + baseURL }

    /// `vgl_` followed by 43 base64url characters (32 random bytes), as Volgenic issues them.
    public static func isValidToken(_ token: String) -> Bool {
        guard token.hasPrefix("vgl_"), token.count == 47 else { return false }
        return token.dropFirst(4).allSatisfy { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" || $0 == "_" }
    }

    /// Canonical form of a base URL: `http` or `https`, a host, an optional port and path, no
    /// query, fragment or credentials, no trailing slash, scheme and host in lowercase.
    public static func normalize(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed), let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            throw GatewayError.invalid("\(raw) is not an http:// or https:// URL")
        }
        guard let host = components.host, !host.isEmpty else { throw GatewayError.invalid("\(raw) has no host") }
        guard components.user == nil, components.password == nil else { throw GatewayError.invalid("\(raw) must not contain a user name or password") }
        guard components.query == nil, components.fragment == nil else { throw GatewayError.invalid("\(raw) must not have a query or fragment") }
        components.scheme = scheme
        components.host = host.lowercased()
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        components.path = path
        guard let url = components.string else { throw GatewayError.invalid("\(raw) is not a valid URL") }
        return url
    }

    /// The WebSocket URL for a base URL: `ws://` for `http://`, `wss://` for `https://`, with
    /// `/messages/telegram/link` appended to the base path.
    public static func endpoint(for baseURL: String) throws -> URL {
        guard var components = URLComponents(string: try normalize(baseURL)) else { throw GatewayError.invalid("\(baseURL) is not a valid URL") }
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.path += endpointPath
        guard let url = components.url else { throw GatewayError.invalid("\(baseURL) is not a valid URL") }
        return url
    }

    /// The token of a link, or nil if the secret store has none.
    public static func token(for baseURL: String, secrets: any SecretStore) throws -> String? {
        guard let data = try secrets.read(secretAccount(for: baseURL)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Adds the link, or replaces the token of an existing one. The token is stored first, so
    /// a gateway reloading in between never sees a link without one. Returns the normalised
    /// URL and whether the link already existed.
    @discardableResult
    public static func add(baseURL: String, token: String, paths: Paths, secrets: any SecretStore) throws -> (baseURL: String, replaced: Bool) {
        let url = try normalize(baseURL)
        guard isValidToken(token) else {
            throw GatewayError.invalid("that is not a Volgenic link token: it starts with vgl_ followed by 43 letters, digits, - or _")
        }
        try secrets.write(secretAccount(for: url), Data(token.utf8))
        var links = try Config.load(paths: paths, environment: [:]).links
        let replaced = links.contains(LinkConfig(baseURL: url))
        if !replaced {
            links.append(LinkConfig(baseURL: url))
            try writeLinks(links, paths: paths)
        }
        return (url, replaced)
    }

    /// Removes the link and its token. Returns false if there was no such link.
    @discardableResult
    public static func remove(baseURL: String, paths: Paths, secrets: any SecretStore) throws -> Bool {
        let url = try normalize(baseURL)
        var links = try Config.load(paths: paths, environment: [:]).links
        let existed = links.contains(LinkConfig(baseURL: url))
        links.removeAll { $0.baseURL == url }
        if existed { try writeLinks(links, paths: paths) }
        try secrets.delete(secretAccount(for: url))
        return existed
    }

    /// Rewrites the `links` key of `config.json`, keeping every other key as it was.
    public static func writeLinks(_ links: [LinkConfig], paths: Paths) throws {
        var object = JSONObjectValue()
        if let data = try? Data(contentsOf: paths.config) {
            guard case .object(let existing) = try JSONValue.parse(data) else {
                throw GatewayError.invalidConfig("\(paths.config.path) is not a JSON object")
            }
            object = existing
        }
        object["links"] = .array(links.map(\.json))
        try FileManager.default.createDirectory(at: paths.home, withIntermediateDirectories: true)
        guard let data = (JSONValue.object(object).pretty() + "\n").data(using: .utf8) else { return }
        try data.write(to: paths.config, options: [.atomic])
    }
}

/// What a reload did to the links (`POST /v1/admin/reload`, `links` in the response).
public struct LinkReloadSummary: Sendable, Equatable {
    /// Links that were not running and now are.
    public var started: [String]
    /// Links whose token changed, or that had stopped after a refusal, and were reconnected.
    public var restarted: [String]
    /// Links no longer in `config.json`, now closed.
    public var stopped: [String]
    public var unchanged: [String]

    public init(started: [String] = [], restarted: [String] = [], stopped: [String] = [], unchanged: [String] = []) {
        self.started = started
        self.restarted = restarted
        self.stopped = stopped
        self.unchanged = unchanged
    }

    public var json: JSONValue {
        [
            "started": .array(started.map { .string($0) }),
            "restarted": .array(restarted.map { .string($0) }),
            "stopped": .array(stopped.map { .string($0) }),
            "unchanged": .array(unchanged.map { .string($0) }),
        ]
    }
}

/// Whatever runs the links; `ConfigReloader` hands it the links of a freshly read
/// `config.json`.
public protocol LinkReloading: Sendable {
    func apply(_ links: [LinkConfig]) async -> LinkReloadSummary
}
