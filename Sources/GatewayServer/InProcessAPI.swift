import Foundation
import GatewayCore
import GatewayLink
import HTTPTypes
import Hummingbird
import Logging
import NIOCore
import Synchronization

/// Runs requests from a link to Volgenic through the gateway's own router, in this process,
/// with the admin token: the same middleware (authentication, rate limit, errors) and the
/// same routes that `tgw` reaches over 127.0.0.1, without a socket.
public struct InProcessAPI: LinkRequestHandling {
    private let responder: RouterResponder<GatewayRequestContext>
    private let adminToken: String
    private let logger: Logger

    public init(deps: Dependencies, adminToken: String) {
        responder = GatewayServer.buildRouter(deps: deps).buildResponder()
        self.adminToken = adminToken
        logger = deps.logger
    }

    public func perform(_ request: LinkHTTPRequest, maxBodyBytes: Int) async -> LinkHTTPResponse {
        var headers = HTTPFields()
        headers[.authorization] = "Bearer \(adminToken)"
        headers[.userAgent] = "TelegramGateway-Link/1"
        let body = request.body ?? Data()
        if !body.isEmpty { headers[.contentType] = "application/json; charset=utf-8" }
        headers[.contentLength] = String(body.count)
        let head = HTTPRequest(method: HTTPRequest.Method(request.method) ?? .get, scheme: "http", authority: "127.0.0.1", path: request.target, headerFields: headers)
        let hbRequest = Request(head: head, body: RequestBody(buffer: ByteBuffer(bytes: body)))
        let context = GatewayRequestContext(linkLogger: logger)

        let response: Response
        do {
            response = try await responder.respond(to: hbRequest, context: context)
        } catch {
            logger.error("link request \(request.method) \(request.path) failed: \(error)")
            return .error(.internalError("Unexpected error; report with X-TGW-Request-Id \(context.requestId)."))
        }
        let contentType = response.headers[.contentType]
        if let length = response.headers[.contentLength].flatMap(Int.init), length > maxBodyBytes {
            return .tooLarge(limit: maxBodyBytes)
        }
        let collector = BodyCollector(limit: maxBodyBytes)
        do {
            try await response.body.write(collector)
        } catch is BodyCollector.TooLarge {
            return .tooLarge(limit: maxBodyBytes)
        } catch {
            logger.error("link request \(request.method) \(request.path): reading the response failed: \(error)")
            return .error(.internalError("Reading the response failed."))
        }
        return LinkHTTPResponse(status: Int(response.status.code), contentType: contentType, body: collector.data)
    }
}

/// Gathers a response body in memory, up to a limit.
final class BodyCollector: ResponseBodyWriter, Sendable {
    struct TooLarge: Error {}

    private let buffer = Mutex(Data())
    private let limit: Int

    init(limit: Int) {
        self.limit = limit
    }

    var data: Data { buffer.withLock { $0 } }

    func write(_ chunk: ByteBuffer) async throws {
        try buffer.withLock { data in
            guard data.count + chunk.readableBytes <= limit else { throw TooLarge() }
            data.append(contentsOf: chunk.readableBytesView)
        }
    }

    func finish(_ trailingHeaders: HTTPFields?) async throws {}
}
