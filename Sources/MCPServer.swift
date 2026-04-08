import Foundation

// MARK: - Errors

enum MCPError: Error, CustomStringConvertible {
    case permissionDenied(String)
    case notFound(String)
    case invalidParams(String)

    var description: String {
        switch self {
        case .permissionDenied(let msg): return msg
        case .notFound(let msg): return msg
        case .invalidParams(let msg): return msg
        }
    }
}

// MARK: - JSON-RPC Types

struct JSONRPCRequest {
    let id: Any?
    let method: String
    let params: [String: Any]?

    init?(json: [String: Any]) {
        self.method = json["method"] as? String ?? ""
        self.id = json["id"]
        self.params = json["params"] as? [String: Any]
    }
}

// MARK: - MCP Server

final class MCPServer: @unchecked Sendable {
    private let serverInfo: [String: String] = [
        "name": "mcp-mail",
        "version": "1.0.0",
    ]

    func handleMessage(_ data: Data) async -> Data? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let request = JSONRPCRequest(json: json) else {
            return jsonRPCError(id: nil, code: -32700, message: "Parse error")
        }

        // Notifications have no id — no response needed
        if request.id == nil {
            return nil
        }

        let result: Any
        do {
            result = try await dispatch(request)
        } catch let error as MCPError {
            return jsonRPCToolError(id: request.id, message: error.description)
        } catch {
            return jsonRPCToolError(id: request.id, message: error.localizedDescription)
        }

        return jsonRPCResult(id: request.id, result: result)
    }

    private func dispatch(_ request: JSONRPCRequest) async throws -> Any {
        switch request.method {
        case "initialize":
            return [
                "protocolVersion": "2024-11-05",
                "capabilities": [
                    "tools": ["listChanged": false],
                ],
                "serverInfo": serverInfo,
            ] as [String: Any]

        case "ping":
            return [:] as [String: Any]

        case "tools/list":
            return ["tools": toolDefinitions()]

        case "tools/call":
            guard let params = request.params,
                  let toolName = params["name"] as? String else {
                throw MCPError.invalidParams("Missing tool name")
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            return try await callTool(name: toolName, arguments: arguments)

        default:
            return jsonRPCErrorDict(code: -32601, message: "Method not found: \(request.method)")
        }
    }

    // MARK: - Tool Definitions

    private func toolDefinitions() -> [[String: Any]] {
        [
            [
                "name": "list_accounts",
                "description": "List all configured mail accounts",
                "inputSchema": [
                    "type": "object",
                    "properties": [:] as [String: Any],
                ] as [String: Any],
            ],
            [
                "name": "list_mailboxes",
                "description": "List mailboxes for an account or all accounts",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "accountName": ["type": "string", "description": "Account name to filter by (lists all if omitted)"],
                    ] as [String: Any],
                ] as [String: Any],
            ],
            [
                "name": "check_mail",
                "description": "Force Mail.app to check for new messages",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "accountName": ["type": "string", "description": "Account name to check (checks all if omitted)"],
                    ] as [String: Any],
                ] as [String: Any],
            ],
            [
                "name": "list_messages",
                "description": "List messages in a mailbox with optional filtering",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "account": ["type": "string", "description": "Account name"],
                        "mailbox": ["type": "string", "description": "Mailbox name (e.g. INBOX, Sent Messages, Drafts)"],
                        "subject": ["type": "string", "description": "Filter by subject (contains)"],
                        "sender": ["type": "string", "description": "Filter by sender (contains)"],
                        "unreadOnly": ["type": "boolean", "description": "Only return unread messages"],
                        "limit": ["type": "integer", "description": "Maximum messages to return (default 50)"],
                        "offset": ["type": "integer", "description": "Skip this many messages (for pagination)"],
                    ] as [String: Any],
                    "required": ["account", "mailbox"],
                ] as [String: Any],
            ],
            [
                "name": "read_message",
                "description": "Read full message content including body, headers, and attachment info",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "messageId": ["type": "integer", "description": "Message ID from list_messages"],
                        "account": ["type": "string", "description": "Account name"],
                        "mailbox": ["type": "string", "description": "Mailbox name"],
                    ] as [String: Any],
                    "required": ["messageId", "account", "mailbox"],
                ] as [String: Any],
            ],
            [
                "name": "extract_attachment",
                "description": "Save a message attachment to disk and return the file path",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "messageId": ["type": "integer", "description": "Message ID"],
                        "account": ["type": "string", "description": "Account name"],
                        "mailbox": ["type": "string", "description": "Mailbox name"],
                        "attachmentName": ["type": "string", "description": "Attachment filename to extract (extracts all if omitted)"],
                    ] as [String: Any],
                    "required": ["messageId", "account", "mailbox"],
                ] as [String: Any],
            ],
            [
                "name": "mark_read",
                "description": "Mark a message as read or unread",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "messageId": ["type": "integer", "description": "Message ID"],
                        "account": ["type": "string", "description": "Account name"],
                        "mailbox": ["type": "string", "description": "Mailbox name"],
                        "read": ["type": "boolean", "description": "true to mark read, false for unread"],
                    ] as [String: Any],
                    "required": ["messageId", "account", "mailbox", "read"],
                ] as [String: Any],
            ],
            [
                "name": "flag_message",
                "description": "Flag or unflag a message",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "messageId": ["type": "integer", "description": "Message ID"],
                        "account": ["type": "string", "description": "Account name"],
                        "mailbox": ["type": "string", "description": "Mailbox name"],
                        "flagged": ["type": "boolean", "description": "true to flag, false to unflag"],
                    ] as [String: Any],
                    "required": ["messageId", "account", "mailbox", "flagged"],
                ] as [String: Any],
            ],
            [
                "name": "move_message",
                "description": "Move a message to a different mailbox",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "messageId": ["type": "integer", "description": "Message ID"],
                        "account": ["type": "string", "description": "Account name"],
                        "mailbox": ["type": "string", "description": "Source mailbox name"],
                        "destinationMailbox": ["type": "string", "description": "Destination mailbox name"],
                        "destinationAccount": ["type": "string", "description": "Destination account (same account if omitted)"],
                    ] as [String: Any],
                    "required": ["messageId", "account", "mailbox", "destinationMailbox"],
                ] as [String: Any],
            ],
            [
                "name": "delete_message",
                "description": "Delete a message (moves to Trash)",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "messageId": ["type": "integer", "description": "Message ID"],
                        "account": ["type": "string", "description": "Account name"],
                        "mailbox": ["type": "string", "description": "Mailbox name"],
                    ] as [String: Any],
                    "required": ["messageId", "account", "mailbox"],
                ] as [String: Any],
            ],
        ]
    }

    // MARK: - Tool Dispatch

    private func callTool(name: String, arguments: [String: Any]) async throws -> [String: Any] {
        let manager = MailManager.shared

        switch name {
        case "list_accounts":
            let result = try await manager.listAccounts()
            return toolResult(result)

        case "list_mailboxes":
            let result = try await manager.listMailboxes(
                accountName: arguments["accountName"] as? String
            )
            return toolResult(result)

        case "check_mail":
            let result = try await manager.checkMail(
                accountName: arguments["accountName"] as? String
            )
            return toolResult(result)

        case "list_messages":
            guard let account = arguments["account"] as? String else {
                throw MCPError.invalidParams("Missing required parameter: account")
            }
            guard let mailbox = arguments["mailbox"] as? String else {
                throw MCPError.invalidParams("Missing required parameter: mailbox")
            }
            let result = try await manager.listMessages(
                account: account,
                mailbox: mailbox,
                subject: arguments["subject"] as? String,
                sender: arguments["sender"] as? String,
                unreadOnly: arguments["unreadOnly"] as? Bool ?? false,
                limit: arguments["limit"] as? Int ?? 50,
                offset: arguments["offset"] as? Int ?? 0
            )
            return toolResult(result)

        case "read_message":
            guard let messageId = arguments["messageId"] as? Int else {
                throw MCPError.invalidParams("Missing required parameter: messageId")
            }
            guard let account = arguments["account"] as? String else {
                throw MCPError.invalidParams("Missing required parameter: account")
            }
            guard let mailbox = arguments["mailbox"] as? String else {
                throw MCPError.invalidParams("Missing required parameter: mailbox")
            }
            let result = try await manager.readMessage(
                messageId: messageId, account: account, mailbox: mailbox
            )
            return toolResult(result)

        case "extract_attachment":
            guard let messageId = arguments["messageId"] as? Int else {
                throw MCPError.invalidParams("Missing required parameter: messageId")
            }
            guard let account = arguments["account"] as? String else {
                throw MCPError.invalidParams("Missing required parameter: account")
            }
            guard let mailbox = arguments["mailbox"] as? String else {
                throw MCPError.invalidParams("Missing required parameter: mailbox")
            }
            let result = try await manager.extractAttachment(
                messageId: messageId,
                account: account,
                mailbox: mailbox,
                attachmentName: arguments["attachmentName"] as? String
            )
            return toolResult(result)

        case "mark_read":
            guard let messageId = arguments["messageId"] as? Int else {
                throw MCPError.invalidParams("Missing required parameter: messageId")
            }
            guard let account = arguments["account"] as? String else {
                throw MCPError.invalidParams("Missing required parameter: account")
            }
            guard let mailbox = arguments["mailbox"] as? String else {
                throw MCPError.invalidParams("Missing required parameter: mailbox")
            }
            guard let read = arguments["read"] as? Bool else {
                throw MCPError.invalidParams("Missing required parameter: read")
            }
            let result = try await manager.markRead(
                messageId: messageId, account: account, mailbox: mailbox, read: read
            )
            return toolResult(result)

        case "flag_message":
            guard let messageId = arguments["messageId"] as? Int else {
                throw MCPError.invalidParams("Missing required parameter: messageId")
            }
            guard let account = arguments["account"] as? String else {
                throw MCPError.invalidParams("Missing required parameter: account")
            }
            guard let mailbox = arguments["mailbox"] as? String else {
                throw MCPError.invalidParams("Missing required parameter: mailbox")
            }
            guard let flagged = arguments["flagged"] as? Bool else {
                throw MCPError.invalidParams("Missing required parameter: flagged")
            }
            let result = try await manager.flagMessage(
                messageId: messageId, account: account, mailbox: mailbox, flagged: flagged
            )
            return toolResult(result)

        case "move_message":
            guard let messageId = arguments["messageId"] as? Int else {
                throw MCPError.invalidParams("Missing required parameter: messageId")
            }
            guard let account = arguments["account"] as? String else {
                throw MCPError.invalidParams("Missing required parameter: account")
            }
            guard let mailbox = arguments["mailbox"] as? String else {
                throw MCPError.invalidParams("Missing required parameter: mailbox")
            }
            guard let destination = arguments["destinationMailbox"] as? String else {
                throw MCPError.invalidParams("Missing required parameter: destinationMailbox")
            }
            let result = try await manager.moveMessage(
                messageId: messageId,
                account: account,
                mailbox: mailbox,
                destinationMailbox: destination,
                destinationAccount: arguments["destinationAccount"] as? String
            )
            return toolResult(result)

        case "delete_message":
            guard let messageId = arguments["messageId"] as? Int else {
                throw MCPError.invalidParams("Missing required parameter: messageId")
            }
            guard let account = arguments["account"] as? String else {
                throw MCPError.invalidParams("Missing required parameter: account")
            }
            guard let mailbox = arguments["mailbox"] as? String else {
                throw MCPError.invalidParams("Missing required parameter: mailbox")
            }
            let result = try await manager.deleteMessage(
                messageId: messageId, account: account, mailbox: mailbox
            )
            return toolResult(result)

        default:
            throw MCPError.invalidParams("Unknown tool: \(name)")
        }
    }

    // MARK: - Response Helpers

    private func toolResult(_ jsonData: Data) -> [String: Any] {
        let text = String(data: jsonData, encoding: .utf8) ?? "{}"
        return [
            "content": [["type": "text", "text": text]],
            "isError": false,
        ]
    }

    private func jsonRPCResult(id: Any?, result: Any) -> Data {
        var response: [String: Any] = ["jsonrpc": "2.0", "result": result]
        if let id { response["id"] = id }
        return (try? JSONSerialization.data(withJSONObject: response)) ?? Data()
    }

    private func jsonRPCError(id: Any?, code: Int, message: String) -> Data {
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id ?? NSNull(),
            "error": ["code": code, "message": message],
        ]
        return (try? JSONSerialization.data(withJSONObject: response)) ?? Data()
    }

    private func jsonRPCToolError(id: Any?, message: String) -> Data {
        let result: [String: Any] = [
            "content": [["type": "text", "text": message]],
            "isError": true,
        ]
        return jsonRPCResult(id: id, result: result)
    }

    private func jsonRPCErrorDict(code: Int, message: String) -> [String: Any] {
        ["__jsonrpc_error__": true, "code": code, "message": message]
    }
}
