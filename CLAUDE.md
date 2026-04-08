# mcp-mail

MCP server for Apple Mail via AppleScript. Swift 6, macOS 14+.

## Architecture

```
Sources/
├── App.swift              # Entry point — Hummingbird HTTP server, routes, --setup flag
├── MCPServer.swift        # MCP protocol — tool definitions, JSON-RPC dispatch
├── MailManager.swift      # Mail.app actor — all email operations via AppleScript
├── SSETransport.swift     # SSE session management (legacy HTTP+SSE transport)
└── Resources/Info.plist   # Bundle info for TCC entitlements
```

- **MCPServer.swift** has two key sections: `toolDefinitions()` (schema) and `callTool()` (dispatch). Every tool appears in both.
- **MailManager** is a Swift actor. Uses `NSAppleScript` to talk to Mail.app. All methods return `Data` (serialized JSON) to stay Sendable-safe across actor boundaries.
- Transport is HTTP+SSE on port 8202 (configurable via `PORT` env var). SSE at `GET /sse`, messages at `POST /message?sessionId=<id>`.
- AppleScript results are encoded using delimiters (`|||` for fields, `~~~` for records) and parsed in Swift. This avoids complex AppleScript JSON serialization.

## Adding a new tool

1. Add the tool definition dict to `toolDefinitions()` in `MCPServer.swift`
2. Add the implementation method to `MailManager.swift` (follow existing patterns — run AppleScript, parse result, return serialized JSON)
3. Add a dispatch `case` in `callTool()` in `MCPServer.swift`
4. Update the tools table in `README.md`

## Development workflow

```bash
# Build release (agents use the release binary)
swift build -c release

# Sign the binary (required for persistent TCC permissions)
# Find your identity: security find-identity -v -p codesigning
codesign --force --sign "<your signing identity>" \
  --identifier "com.gellyfish.mcp-mail" \
  .build/release/mcp-mail

# Restart via launchd
launchctl unload ~/Library/LaunchAgents/com.gellyfish.mcp-mail.plist
launchctl load ~/Library/LaunchAgents/com.gellyfish.mcp-mail.plist

# Verify it's up
curl -s http://127.0.0.1:8202/health
```

**Code signing matters.** Without it, macOS identifies the binary by hash — every rebuild revokes TCC permissions. With a consistent code signature, TCC grants persist across rebuilds. Always sign after building.

**MCP clients cache the tool list at connection time.** After restarting the server, any connected MCP client (Claude Code session, agent) must reconnect to discover new/changed tools. This typically means restarting the client session.

## TCC permissions

This MCP server requires **Automation** permission (not Calendar/Reminders like mcp-calendar).

```bash
# Trigger permission dialog
.build/release/mcp-mail --setup

# If dialog doesn't appear, grant manually:
# System Settings → Privacy & Security → Automation → mcp-mail → Mail → toggle ON

# Error -1743 means TCC denied — check Automation permissions
```

## AppleScript patterns

- **String escaping:** Always use `escapeForAppleScript()` for user-provided strings to prevent injection
- **Delimiter parsing:** Results use `|||` between fields and `~~~` between records
- **Error handling:** Error -1743 = TCC denied, caught and re-thrown as MCPError.permissionDenied
- **Large mailboxes:** `list_messages` supports `limit` (default 50) and `offset` for pagination

## Conventions

- Port: 8202 (next after mcp-calendar on 8201)
- All messages are identified by `messageId` (Mail.app's internal ID), plus `account` and `mailbox` context
- Delete moves to Trash (Mail.app default behavior)
