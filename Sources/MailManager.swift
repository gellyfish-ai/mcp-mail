import Foundation

/// Thread-safe Mail.app access via Swift actor.
/// Uses AppleScript (NSAppleScript) to interact with Mail.app.
/// Returns serialized JSON Data from all methods to avoid Sendable issues at actor boundaries.
actor MailManager {
    static let shared = MailManager()

    private init() {}

    // MARK: - AppleScript Helpers

    private func runScript(_ source: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()

        if process.terminationStatus != 0 {
            let message = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "AppleScript error"
            if message.contains("-1743") {
                throw MCPError.permissionDenied("Mail.app access denied (TCC). Grant in System Settings > Privacy & Security > Automation > mcp-mail > Mail")
            }
            throw MCPError.permissionDenied(message)
        }

        return String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func serialize(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    }

    // MARK: - Access Test

    func testAccess() -> Bool {
        do {
            _ = try runScript("tell application \"Mail\" to get name of every account")
            return true
        } catch {
            print("Access test failed: \(error)")
            return false
        }
    }

    // MARK: - Accounts

    func listAccounts() async throws -> Data {
        let script = """
        tell application "Mail"
            set accountList to {}
            repeat with acct in every account
                set acctName to name of acct
                set acctType to (account type of acct) as string
                set acctEnabled to enabled of acct
                set acctEmails to email addresses of acct
                set emailStr to ""
                repeat with e in acctEmails
                    if emailStr is not "" then set emailStr to emailStr & ","
                    set emailStr to emailStr & (e as string)
                end repeat
                set end of accountList to acctName & "|||" & acctType & "|||" & (acctEnabled as string) & "|||" & emailStr
            end repeat
            set AppleScript's text item delimiters to "~~~"
            return accountList as string
        end tell
        """
        let result = try runScript(script)
        if result.isEmpty {
            return try serialize([])
        }

        let accounts = result.components(separatedBy: "~~~").compactMap { entry -> [String: Any]? in
            let parts = entry.components(separatedBy: "|||")
            guard parts.count >= 4 else { return nil }
            return [
                "name": parts[0],
                "type": parts[1],
                "enabled": parts[2] == "true",
                "emails": parts[3].components(separatedBy: ",").filter { !$0.isEmpty },
            ]
        }
        return try serialize(accounts)
    }

    // MARK: - Mailboxes

    func listMailboxes(accountName: String?) async throws -> Data {
        let accountFilter: String
        if let accountName {
            accountFilter = "of account \"\(escapeForAppleScript(accountName))\""
        } else {
            accountFilter = ""
        }

        let script = """
        tell application "Mail"
            set boxList to {}
            set allBoxes to every mailbox \(accountFilter)
            repeat with mb in allBoxes
                set mbName to name of mb
                set msgCount to count of messages of mb
                set unreadCount to unread count of mb
                set end of boxList to mbName & "|||" & (msgCount as string) & "|||" & (unreadCount as string)
            end repeat
            set AppleScript's text item delimiters to "~~~"
            return boxList as string
        end tell
        """
        let result = try runScript(script)
        if result.isEmpty {
            return try serialize([])
        }

        let mailboxes = result.components(separatedBy: "~~~").compactMap { entry -> [String: Any]? in
            let parts = entry.components(separatedBy: "|||")
            guard parts.count >= 3 else { return nil }
            return [
                "name": parts[0],
                "messageCount": Int(parts[1]) ?? 0,
                "unreadCount": Int(parts[2]) ?? 0,
            ]
        }
        return try serialize(mailboxes)
    }

    // MARK: - Check Mail

    func checkMail(accountName: String?) async throws -> Data {
        let script: String
        if let accountName {
            script = """
            tell application "Mail"
                check for new mail for account "\(escapeForAppleScript(accountName))"
            end tell
            """
        } else {
            script = """
            tell application "Mail"
                check for new mail
            end tell
            """
        }
        _ = try runScript(script)
        return try serialize(["checked": true])
    }

    // MARK: - List Messages

    func listMessages(
        account: String,
        mailbox: String,
        subject: String?,
        sender: String?,
        unreadOnly: Bool,
        limit: Int,
        offset: Int
    ) async throws -> Data {
        // Build filter conditions
        var conditions: [String] = []
        if let subject {
            conditions.append("subject of msg contains \"\(escapeForAppleScript(subject))\"")
        }
        if let sender {
            conditions.append("sender of msg contains \"\(escapeForAppleScript(sender))\"")
        }
        if unreadOnly {
            conditions.append("read status of msg is false")
        }

        let filterCheck: String
        if conditions.isEmpty {
            filterCheck = "true"
        } else {
            filterCheck = conditions.joined(separator: " and ")
        }

        let script = """
        tell application "Mail"
            set mb to mailbox "\(escapeForAppleScript(mailbox))" of account "\(escapeForAppleScript(account))"
            set msgList to {}
            set matchCount to 0
            set skipCount to 0
            set allMsgs to messages of mb
            repeat with msg in allMsgs
                try
                    if \(filterCheck) then
                        if skipCount < \(offset) then
                            set skipCount to skipCount + 1
                        else
                            set msgId to id of msg
                            set msgSubject to subject of msg
                            set msgSender to sender of msg
                            set msgDate to date received of msg as string
                            set msgRead to read status of msg
                            set msgFlagged to flagged status of msg
                            set end of msgList to (msgId as string) & "|||" & msgSubject & "|||" & msgSender & "|||" & msgDate & "|||" & (msgRead as string) & "|||" & (msgFlagged as string)
                            set matchCount to matchCount + 1
                            if matchCount ≥ \(limit) then exit repeat
                        end if
                    end if
                end try
            end repeat
            set AppleScript's text item delimiters to "~~~"
            return msgList as string
        end tell
        """
        let result = try runScript(script)
        if result.isEmpty {
            return try serialize([])
        }

        let messages = result.components(separatedBy: "~~~").compactMap { entry -> [String: Any]? in
            let parts = entry.components(separatedBy: "|||")
            guard parts.count >= 6 else { return nil }
            return [
                "messageId": Int(parts[0]) ?? 0,
                "subject": parts[1],
                "sender": parts[2],
                "dateReceived": parts[3],
                "isRead": parts[4] == "true",
                "isFlagged": parts[5] == "true",
            ]
        }
        return try serialize(messages)
    }

    // MARK: - Read Message

    func readMessage(messageId: Int, account: String, mailbox: String) async throws -> Data {
        let script = """
        tell application "Mail"
            set mb to mailbox "\(escapeForAppleScript(mailbox))" of account "\(escapeForAppleScript(account))"
            set msg to (first message of mb whose id is \(messageId))
            set msgSubject to subject of msg
            set msgSender to sender of msg
            set msgDateRecv to date received of msg as string
            set msgDateSent to date sent of msg as string
            set msgRead to read status of msg
            set msgFlagged to flagged status of msg
            set msgReplyTo to reply to of msg

            -- Get content
            set msgContent to content of msg

            -- Get attachment info
            set attachList to {}
            repeat with att in mail attachments of msg
                set attName to name of att
                set attSize to MIME type of att
                set end of attachList to attName & ":::" & attSize
            end repeat

            set AppleScript's text item delimiters to ",,,"
            set attachStr to attachList as string

            -- Get recipients
            set toList to {}
            repeat with r in to recipients of msg
                set end of toList to address of r
            end repeat
            set AppleScript's text item delimiters to ","
            set toString to toList as string

            set ccList to {}
            repeat with r in cc recipients of msg
                set end of ccList to address of r
            end repeat
            set ccString to ccList as string

            return msgSubject & "|||" & msgSender & "|||" & msgDateRecv & "|||" & msgDateSent & "|||" & (msgRead as string) & "|||" & (msgFlagged as string) & "|||" & msgReplyTo & "|||" & toString & "|||" & ccString & "|||" & attachStr & "|||" & msgContent
        end tell
        """
        let result = try runScript(script)
        let parts = result.components(separatedBy: "|||")
        guard parts.count >= 11 else {
            throw MCPError.notFound("Message not found or could not be read")
        }

        let attachments = parts[9].isEmpty ? [] : parts[9].components(separatedBy: ",,,").compactMap { entry -> [String: String]? in
            let attParts = entry.components(separatedBy: ":::")
            guard attParts.count >= 2 else { return nil }
            return ["name": attParts[0], "mimeType": attParts[1]]
        }

        let dict: [String: Any] = [
            "messageId": messageId,
            "subject": parts[0],
            "sender": parts[1],
            "dateReceived": parts[2],
            "dateSent": parts[3],
            "isRead": parts[4] == "true",
            "isFlagged": parts[5] == "true",
            "replyTo": parts[6],
            "to": parts[7].components(separatedBy: ",").filter { !$0.isEmpty },
            "cc": parts[8].components(separatedBy: ",").filter { !$0.isEmpty },
            "attachments": attachments,
            "content": parts[10...].joined(separator: "|||"),  // content may contain the delimiter
        ]
        return try serialize(dict)
    }

    // MARK: - Extract Attachment

    func extractAttachment(
        messageId: Int,
        account: String,
        mailbox: String,
        attachmentName: String?
    ) async throws -> Data {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-mail-attachments").path
        try? FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)

        let nameFilter: String
        if let attachmentName {
            nameFilter = "name of att is \"\(escapeForAppleScript(attachmentName))\""
        } else {
            nameFilter = "true"
        }

        let script = """
        set baseDir to "\(tempDir)"
        tell application "Mail"
            set mb to mailbox "\(escapeForAppleScript(mailbox))" of account "\(escapeForAppleScript(account))"
            set msg to (first message of mb whose id is \(messageId))
            set savedFiles to {}
            repeat with att in mail attachments of msg
                if \(nameFilter) then
                    set attName to name of att
                    set fullPath to baseDir & "/" & attName
                    set savePath to fullPath as POSIX file as «class furl»
                    save att in savePath
                    set end of savedFiles to fullPath
                end if
            end repeat
            set AppleScript's text item delimiters to "~~~"
            return savedFiles as string
        end tell
        """
        let result = try runScript(script)
        if result.isEmpty {
            throw MCPError.notFound("No attachments found")
        }

        let paths = result.components(separatedBy: "~~~")
        let files = paths.map { ["path": $0] }
        return try serialize(["extracted": files])
    }

    // MARK: - Mark Read

    func markRead(messageId: Int, account: String, mailbox: String, read: Bool) async throws -> Data {
        let script = """
        tell application "Mail"
            set mb to mailbox "\(escapeForAppleScript(mailbox))" of account "\(escapeForAppleScript(account))"
            set msg to (first message of mb whose id is \(messageId))
            set read status of msg to \(read)
            return "ok"
        end tell
        """
        _ = try runScript(script)
        return try serialize(["messageId": messageId, "isRead": read, "updated": true])
    }

    // MARK: - Flag Message

    func flagMessage(messageId: Int, account: String, mailbox: String, flagged: Bool) async throws -> Data {
        let script = """
        tell application "Mail"
            set mb to mailbox "\(escapeForAppleScript(mailbox))" of account "\(escapeForAppleScript(account))"
            set msg to (first message of mb whose id is \(messageId))
            set flagged status of msg to \(flagged)
            return "ok"
        end tell
        """
        _ = try runScript(script)
        return try serialize(["messageId": messageId, "isFlagged": flagged, "updated": true])
    }

    // MARK: - Move Message

    func moveMessage(
        messageId: Int,
        account: String,
        mailbox: String,
        destinationMailbox: String,
        destinationAccount: String?
    ) async throws -> Data {
        let destAccount = destinationAccount ?? account
        let script = """
        tell application "Mail"
            set srcMb to mailbox "\(escapeForAppleScript(mailbox))" of account "\(escapeForAppleScript(account))"
            set dstMb to mailbox "\(escapeForAppleScript(destinationMailbox))" of account "\(escapeForAppleScript(destAccount))"
            set msg to (first message of srcMb whose id is \(messageId))
            move msg to dstMb
            return "ok"
        end tell
        """
        _ = try runScript(script)
        return try serialize([
            "messageId": messageId,
            "movedTo": destinationMailbox,
            "account": destAccount,
            "moved": true,
        ])
    }

    // MARK: - Delete Message

    func deleteMessage(messageId: Int, account: String, mailbox: String) async throws -> Data {
        let script = """
        tell application "Mail"
            set mb to mailbox "\(escapeForAppleScript(mailbox))" of account "\(escapeForAppleScript(account))"
            set msg to (first message of mb whose id is \(messageId))
            delete msg
            return "ok"
        end tell
        """
        _ = try runScript(script)
        return try serialize(["messageId": messageId, "deleted": true])
    }

    // MARK: - Helpers

    private func escapeForAppleScript(_ str: String) -> String {
        str.replacingOccurrences(of: "\\", with: "\\\\")
           .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
