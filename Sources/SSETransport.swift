import Foundation
import Hummingbird
import NIOCore

/// Legacy HTTP+SSE transport for MCP.
/// GET /sse — SSE stream for server-to-client messages.
/// POST /message — Client sends JSON-RPC messages here.
final class SSETransport: Sendable {
    let mcpServer: MCPServer
    let connections = SSEConnectionStore()

    init(mcpServer: MCPServer) {
        self.mcpServer = mcpServer
    }

    func registerRoutes(router: Router<some RequestContext>) {
        let transport = self

        router.get("/sse") { request, _ -> Response in
            let sessionId = UUID().uuidString

            let (stream, continuation) = AsyncStream<String>.makeStream()
            await transport.connections.add(sessionId: sessionId, continuation: continuation)

            // Send the endpoint event so the client knows where to POST
            let authority = request.uri.host ?? "127.0.0.1"
            let port = request.uri.port ?? 8202
            let endpointURL = "http://\(authority):\(port)/message?sessionId=\(sessionId)"
            continuation.yield("event: endpoint\ndata: \(endpointURL)\n\n")

            let responseBody = ResponseBody(asyncSequence: SSEByteSequence(stream: stream))

            return Response(
                status: .ok,
                headers: [
                    .contentType: "text/event-stream",
                    .cacheControl: "no-cache",
                    .connection: "keep-alive",
                ],
                body: responseBody
            )
        }

        router.post("/message") { request, context -> Response in
            let sessionId = request.uri.queryParameters.get("sessionId") ?? ""

            guard await transport.connections.has(sessionId: sessionId) else {
                return Response(
                    status: .badRequest,
                    body: .init(byteBuffer: .init(string: "Invalid or expired session"))
                )
            }

            let body = try await request.body.collect(upTo: 1_048_576)
            let bodyData = Data(buffer: body)

            if let responseData = await transport.mcpServer.handleMessage(bodyData) {
                // Check if it's a protocol-level error
                if let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
                   let result = json["result"] as? [String: Any],
                   result["__jsonrpc_error__"] as? Bool == true {
                    let errorResponse: [String: Any] = [
                        "jsonrpc": "2.0",
                        "id": json["id"] ?? NSNull(),
                        "error": ["code": result["code"] ?? -32601, "message": result["message"] ?? "Unknown error"],
                    ]
                    let errorData = (try? JSONSerialization.data(withJSONObject: errorResponse)) ?? Data()
                    let sseMessage = "event: message\ndata: \(String(data: errorData, encoding: .utf8) ?? "")\n\n"
                    await transport.connections.send(sessionId: sessionId, message: sseMessage)
                } else {
                    let sseMessage = "event: message\ndata: \(String(data: responseData, encoding: .utf8) ?? "")\n\n"
                    await transport.connections.send(sessionId: sessionId, message: sseMessage)
                }
            }

            return Response(status: .accepted)
        }
    }
}

// MARK: - SSE Byte Sequence

struct SSEByteSequence: AsyncSequence, Sendable {
    typealias Element = ByteBuffer

    let stream: AsyncStream<String>

    struct AsyncIterator: AsyncIteratorProtocol {
        var iterator: AsyncStream<String>.AsyncIterator

        mutating func next() async -> ByteBuffer? {
            guard let str = await iterator.next() else { return nil }
            return ByteBuffer(string: str)
        }
    }

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(iterator: stream.makeAsyncIterator())
    }
}

// MARK: - Connection Store

actor SSEConnectionStore {
    private var connections: [String: AsyncStream<String>.Continuation] = [:]

    func add(sessionId: String, continuation: AsyncStream<String>.Continuation) {
        connections[sessionId] = continuation
    }

    func has(sessionId: String) -> Bool {
        connections[sessionId] != nil
    }

    func send(sessionId: String, message: String) {
        connections[sessionId]?.yield(message)
    }

    func remove(sessionId: String) {
        connections[sessionId]?.finish()
        connections.removeValue(forKey: sessionId)
    }
}
