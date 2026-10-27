import Foundation
import GatewayCore

/// One API call Volgenic asked for in a `request` frame, ready to run against the gateway's
/// own API with the admin token.
public struct LinkHTTPRequest: Sendable, Equatable {
    public var method: String
    /// Starts with `/v1/`; no query (that is in `query`).
    public var path: String
    /// `name=value` pairs in order; a name may repeat (`chat_id`).
    public var query: [(String, String)]
    /// The JSON body, already serialised; nil for none.
    public var body: Data?

    public init(method: String, path: String, query: [(String, String)] = [], body: Data? = nil) {
        self.method = method
        self.path = path
        self.query = query
        self.body = body
    }

    /// The path with the query string, percent-encoded.
    public var target: String {
        guard !query.isEmpty else { return path }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?#")
        let pairs = query.map { name, value in
            (name.addingPercentEncoding(withAllowedCharacters: allowed) ?? name) + "=" + (value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)
        }
        return path + "?" + pairs.joined(separator: "&")
    }

    public static func == (lhs: LinkHTTPRequest, rhs: LinkHTTPRequest) -> Bool {
        lhs.method == rhs.method && lhs.path == rhs.path && lhs.body == rhs.body
            && lhs.query.map { [$0.0, $0.1] } == rhs.query.map { [$0.0, $0.1] }
    }
}

/// The gateway's answer to a `LinkHTTPRequest`.
public struct LinkHTTPResponse: Sendable, Equatable {
    public var status: Int
    /// The `Content-Type` header, if any.
    public var contentType: String?
    public var body: Data

    public init(status: Int, contentType: String?, body: Data) {
        self.status = status
        self.contentType = contentType
        self.body = body
    }

    /// The response for a body over the size limit (docs/link.md: `413 too_large`).
    public static func tooLarge(limit: Int) -> LinkHTTPResponse {
        let error = APIError(status: 413, code: "too_large", message: "The response is larger than \(limit) bytes, the most a link frame carries.")
        return LinkHTTPResponse(status: 413, contentType: "application/json; charset=utf-8", body: error.json.serialized())
    }

    public static func error(_ error: APIError) -> LinkHTTPResponse {
        LinkHTTPResponse(status: error.status, contentType: "application/json; charset=utf-8", body: error.json.serialized())
    }
}

/// Runs a request against the gateway's API as the admin. The daemon uses the in-process
/// router (`InProcessAPI` in GatewayServer); tests may use anything.
public protocol LinkRequestHandling: Sendable {
    /// Never throws: every failure is an HTTP status and an error body. A body larger than
    /// `maxBodyBytes` answers `LinkHTTPResponse.tooLarge`.
    func perform(_ request: LinkHTTPRequest, maxBodyBytes: Int) async -> LinkHTTPResponse
}

/// What a link may and may not reach (docs/link.md "Requests").
public enum LinkPolicy {
    /// The largest response body a `response` frame carries, before base64.
    public static let maxBodyBytes = 20 * 1024 * 1024

    static let methods: Set<String> = ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE"]

    /// Paths that reveal or change the admin token or other secrets, or other links.
    static let forbiddenPrefixes = ["/v1/admin/secrets", "/v1/admin/tokens", "/v1/admin/links"]

    /// Nil when the path may be called over the link; otherwise the error to answer with.
    public static func check(method: String, path: String) -> APIError? {
        guard methods.contains(method) else {
            return APIError.invalidRequest("method", "must be one of \(methods.sorted().joined(separator: ", "))")
        }
        let decoded = (path.removingPercentEncoding ?? path).lowercased()
        let forbidden = APIError(status: 403, code: "forbidden_over_link", message: "This path cannot be called over the link to Volgenic.")
        guard path.hasPrefix("/v1/"), decoded.hasPrefix("/v1/") else { return forbidden }
        // Nothing that could walk out of /v1/ or smuggle a query past `query`.
        guard !decoded.contains("?"), !decoded.contains("#"), !decoded.contains("//"), !decoded.contains("\\") else { return forbidden }
        let segments = decoded.split(separator: "/", omittingEmptySubsequences: false)
        guard !segments.contains(where: { $0 == "." || $0 == ".." }) else { return forbidden }
        for prefix in forbiddenPrefixes where decoded.hasPrefix(prefix) {
            return forbidden
        }
        if decoded == "/v1/events/stream" {
            return APIError.invalidRequest("path", "the event stream is a WebSocket; send a subscribe frame instead")
        }
        return nil
    }
}

/// Frames the gateway sends (docs/link.md "Frames").
enum LinkFrames {
    static let protocolVersion = 1

    static func account(_ info: AccountInfo?) -> JSONValue {
        guard let info else { return .null }
        return [
            "id": .id(info.userId), "name": .string(info.displayName),
            "username": .optional(info.username), "phone": .optional(info.phoneNumber),
        ]
    }

    static func hello(version: String, authState: String, account: AccountInfo?, headSeq: Int64) -> JSONValue {
        [
            "type": "hello", "protocol": .number(Double(protocolVersion)), "gateway_version": .string(version),
            "auth_state": .string(authState), "account": LinkFrames.account(account), "head_seq": .number(Double(headSeq)),
        ]
    }

    static func authState(_ state: String, account: AccountInfo?) -> JSONValue {
        ["type": "auth_state", "auth_state": .string(state), "account": LinkFrames.account(account)]
    }

    static func event(_ event: Event) -> JSONValue {
        ["type": "event", "event": event.json()]
    }

    static func gap(oldestSeq: Int64) -> JSONValue {
        ["type": "gap", "oldest_seq": .number(Double(oldestSeq))]
    }

    /// A frame the gateway could not act on (docs/link.md: an addition to protocol 1).
    static func error(code: String, message: String, id: String? = nil) -> JSONValue {
        ["type": "error", "code": .string(code), "message": .string(message), "id": .optional(id)]
    }

    /// The `response` frame for an API answer: JSON bodies inline, anything else in base64.
    static func response(id: String, _ response: LinkHTTPResponse) -> JSONValue {
        var object: JSONObjectValue = ["type": "response", "id": .string(id), "status": .number(Double(response.status))]
        let type = response.contentType?.lowercased() ?? ""
        if response.body.isEmpty {
            object["body"] = .null
        } else if type.hasPrefix("application/json"), let json = try? JSONValue.parse(response.body) {
            object["body"] = json
        } else {
            object["content_type"] = .string(response.contentType ?? "application/octet-stream")
            object["body_base64"] = .string(response.body.base64EncodedString())
        }
        return .object(object)
    }

    /// Parses a `request` frame into a call, or the error to answer with.
    static func request(_ frame: JSONValue) -> Result<LinkHTTPRequest, APIError> {
        guard let method = frame["method"]?.stringValue?.uppercased() else {
            return .failure(APIError.invalidRequest("method", "is required"))
        }
        guard let path = frame["path"]?.stringValue else { return .failure(APIError.invalidRequest("path", "is required")) }
        if let error = LinkPolicy.check(method: method, path: path) { return .failure(error) }
        var query: [(String, String)] = []
        if let raw = frame["query"], raw != .null {
            guard let object = raw.objectValue else { return .failure(APIError.invalidRequest("query", "must be an object of strings")) }
            for (name, value) in object {
                switch value {
                case .string(let s): query.append((name, s))
                case .number, .bool: query.append((name, value.serializedString()))
                case .array(let items):
                    for item in items {
                        guard let s = item.stringValue ?? (item.doubleValue != nil ? item.serializedString() : nil) else {
                            return .failure(APIError.invalidRequest("query", "\(name) must be a string or an array of strings"))
                        }
                        query.append((name, s))
                    }
                default: return .failure(APIError.invalidRequest("query", "\(name) must be a string or an array of strings"))
                }
            }
        }
        var body: Data?
        if let raw = frame["body"], raw != .null {
            body = raw.serialized()
            if (body?.count ?? 0) > ActionInput.maxUploadBodyBytes { return .failure(APIError.payloadTooLarge) }
        }
        return .success(LinkHTTPRequest(method: method, path: path, query: query, body: body))
    }
}
