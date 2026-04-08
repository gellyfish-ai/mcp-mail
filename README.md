# mcp-mail

MCP server for Apple Mail via AppleScript. Exposes email operations over the Model Context Protocol (MCP) using SSE transport.

## Requirements

- macOS 14+ (Sonoma or later)
- Swift 6.0+
- Xcode 16+ (or Swift toolchain)
- Mail.app configured with email accounts

## Setup

### 1. Build

```bash
swift build -c release
```

### 2. Grant Permissions

Mail.app access requires Automation permission via TCC. Run the setup command to trigger the permission dialog:

```bash
swift run mcp-mail --setup
```

**The reliable way to grant permissions:**
1. Run `--setup` once (may or may not show a prompt)
2. Go to **System Settings → Privacy & Security → Automation** → find `mcp-mail` → enable **Mail**

If you rebuild the binary, macOS may revoke permissions — re-grant in System Settings.

### 3. Run

```bash
swift run mcp-mail
```

The server starts on `http://127.0.0.1:8202` by default.

### 4. Install as launchd daemon (recommended)

Run as a persistent macOS daemon that starts on boot and restarts on crash:

```bash
cat > ~/Library/LaunchAgents/com.gellyfish.mcp-mail.plist << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.gellyfish.mcp-mail</string>
    <key>ProgramArguments</key>
    <array>
        <string>~/.local/bin/mcp-mail</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PORT</key>
        <string>8202</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>~/Library/Logs/mcp-mail.log</string>
    <key>StandardErrorPath</key>
    <string>~/Library/Logs/mcp-mail.log</string>
</dict>
</plist>
PLIST

# Load the daemon
launchctl load ~/Library/LaunchAgents/com.gellyfish.mcp-mail.plist

# Verify it's running
curl -s http://localhost:8202/health
```

Manage the daemon:
```bash
# Stop
launchctl unload ~/Library/LaunchAgents/com.gellyfish.mcp-mail.plist

# Restart (unload + load)
launchctl unload ~/Library/LaunchAgents/com.gellyfish.mcp-mail.plist
launchctl load ~/Library/LaunchAgents/com.gellyfish.mcp-mail.plist

# Check logs
tail -f ~/Library/Logs/mcp-mail.log
```

## Configuration

Environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `HOST` | `127.0.0.1` | Bind address |
| `PORT` | `8202` | Listen port |

## MCP Transport

Uses legacy HTTP+SSE transport:

- **SSE endpoint:** `GET /sse` - Connect to receive server events
- **Message endpoint:** `POST /message?sessionId=<id>` - Send JSON-RPC messages
- **Health check:** `GET /health`

## Tools

### Read & Organize (Phase 1)

| Tool | Description |
|------|-------------|
| `list_accounts` | List all configured mail accounts |
| `list_mailboxes` | List mailboxes for an account |
| `check_mail` | Force Mail.app to check for new messages |
| `list_messages` | List messages with filtering (sender, subject, read status) and pagination |
| `read_message` | Read full message content, headers, and attachment info |
| `extract_attachment` | Save attachment to disk, return file path |
| `mark_read` | Mark message as read/unread |
| `flag_message` | Flag/unflag a message |
| `move_message` | Move message to a different mailbox |
| `delete_message` | Delete a message (moves to Trash) |

### Compose & Send (Phase 2 — planned)

| Tool | Description |
|------|-------------|
| `send_message` | Compose and send an email |
| `reply_message` | Reply to a message |
| `forward_message` | Forward a message |

## Security

- Binds to `127.0.0.1` by default (localhost only)
- No credentials or tokens in responses
- Message content is read from Mail.app, not raw IMAP — respects Mail.app's security model
- Phase 2 send operations will require human confirmation

## License

MIT
