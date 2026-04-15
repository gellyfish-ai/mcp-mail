import Foundation
import Hummingbird

@main
struct MCPMailApp {
    static func main() async throws {
        let port = Int(ProcessInfo.processInfo.environment["PORT"] ?? "8202") ?? 8202
        let host = ProcessInfo.processInfo.environment["HOST"] ?? "127.0.0.1"

        // Handle --setup flag for permission requests
        if CommandLine.arguments.contains("--setup") {
            print("Testing Mail.app AppleScript access...")
            let manager = MailManager.shared
            let hasAccess = await manager.testAccess()
            if hasAccess {
                print("Mail.app access granted. You can now run the server.")
            } else {
                print("Mail.app access denied.")
                print("Grant permission in System Settings > Privacy & Security > Automation > mcp-mail > Mail")
            }
            return
        }

        let mcpServer = MCPServer()
        let transport = SSETransport(mcpServer: mcpServer)

        let router = Router()
        transport.registerRoutes(router: router)

        // Health check
        router.get("/health") { _, _ in
            return Response(status: .ok, body: .init(byteBuffer: .init(string: "ok")))
        }

        let app = Application(
            router: router,
            configuration: .init(address: .hostname(host, port: port))
        )

        print("[mcp-mail] Starting on \(host):\(port) — pid \(ProcessInfo.processInfo.processIdentifier)")
        print("SSE endpoint: http://\(host):\(port)/sse")
        print("Message endpoint: http://\(host):\(port)/message")
        print("Run with --setup to test Mail.app access permissions")

        try await app.runService()
    }
}
