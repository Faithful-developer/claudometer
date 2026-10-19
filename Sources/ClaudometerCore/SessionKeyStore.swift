import Foundation
import Security

/// A claude.ai session key the user pastes in Settings, kept in Claudometer's own Keychain
/// item: one per account (TZ F-2). The Claude Code account's key is its backup and keeps the
/// item name it had before accounts existed. The key is never written to disk, `UserDefaults`,
/// logs or the widget's shared folder.
///
/// The item is created and read through `/usr/bin/security`, so its access list trusts that
/// tool rather than this build's ad-hoc signature, and rebuilds or updates don't bring back
/// the Keychain password prompt.
public struct SessionKeyStore: Sendable {
    public static let service = "dev.claudometer.claude-ai-session"
    /// Item saved by 0.1.3 and earlier through the Security framework; its access list is tied
    /// to one build. `migrateLegacyKey()` moves it over.
    static let legacyAccount = "sessionKey"

    public let accountID: String
    /// Keychain account name of this store's item.
    let account: String

    public init(accountID: String = Account.primaryID) {
        self.accountID = accountID
        self.account = Self.keychainAccount(for: accountID)
    }

    static func keychainAccount(for accountID: String) -> String {
        accountID == Account.primaryID ? "sessionKey.v2" : "sessionKey.\(accountID)"
    }

    static func pausedKey(for accountID: String) -> String {
        accountID == Account.primaryID ? "sessionKeyAccessPaused" : "sessionKeyAccessPaused.\(accountID)"
    }

    private var isPrimary: Bool { accountID == Account.primaryID }

    public enum Access: Equatable, Sendable {
        case key(String)
        case missing
        /// The user denied the Keychain prompt (or it couldn't be shown).
        case denied
    }

    public func read() -> Access {
        guard let output = SecurityTool.run(["find-generic-password", "-s", Self.service, "-a", account, "-w"]) else {
            return .denied
        }
        switch output.status {
        case 0:
            guard let key = String(data: output.data, encoding: .utf8), !key.isEmpty else { return .missing }
            return .key(key)
        case SecurityTool.itemNotFound:
            return .missing
        default:
            return .denied
        }
    }

    /// The key for a background fetch. Once the user denies the Keychain prompt, stops asking
    /// until they choose Try Again in Settings, so polling doesn't keep raising the dialog.
    public func loadForPolling() -> String? {
        guard !isPaused else { return nil }
        switch read() {
        case .key(let key): return key
        case .missing: return nil
        case .denied:
            isPaused = true
            return nil
        }
    }

    /// Checks the items' attributes only, which never shows a Keychain prompt. Counts a key
    /// still waiting to be migrated.
    public var hasKey: Bool { hasItem(account) || (isPrimary && hasItem(Self.legacyAccount)) }

    private func hasItem(_ account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess
    }

    /// Moves a key saved by 0.1.3 or earlier into the current item. Reading the old item shows
    /// the Keychain prompt once; a denial pauses the backup like any other denied read. Does
    /// nothing (and never prompts) once there's no old item left. Only the Claude Code
    /// account's backup is that old.
    public func migrateLegacyKey() {
        guard isPrimary, !isPaused, hasItem(Self.legacyAccount), !hasItem(account) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.legacyAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        switch SecItemCopyMatching(query as CFDictionary, &item) {
        case errSecSuccess:
            if let data = item as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty {
                // A failed save keeps the old item; pausing stops re-reading it (and prompting)
                // on every poll until Try Again.
                do { try save(key) } catch { isPaused = true }
            } else {
                deleteLegacyItem()
            }
        case errSecItemNotFound:
            break
        default:
            isPaused = true
        }
    }

    /// Set after a denied Keychain prompt; kept across launches.
    public var isPaused: Bool {
        get { UserDefaults.standard.bool(forKey: Self.pausedKey(for: accountID)) }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: Self.pausedKey(for: accountID)) }
    }

    public func save(_ key: String) throws {
        // Hex via stdin: no quoting to get wrong, and the key never shows up in `ps`.
        let hex = Data(key.utf8).map { String(format: "%02x", $0) }.joined()
        let command = "add-generic-password -U -s \(Self.service) -a \(account) "
            + "-l \"Claudometer claude.ai session\" -X \(hex)\n"
        guard SecurityTool.run(["-i"], input: command)?.status == 0, read() == .key(key) else {
            throw AppError.keychainDenied
        }
        // Only once the new item is confirmed, so a failed save can't lose a migrated key.
        deleteLegacyItem()
        isPaused = false
    }

    public func delete() {
        _ = SecurityTool.run(["delete-generic-password", "-s", Self.service, "-a", account])
        deleteLegacyItem()
        UserDefaults.standard.removeObject(forKey: Self.pausedKey(for: accountID))
    }

    private func deleteLegacyItem() {
        guard isPrimary else { return }
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.legacyAccount,
        ]
        SecItemDelete(match as CFDictionary)
    }

    /// Accepts the bare value, `sessionKey=…`, or a whole `Cookie:` header copied from DevTools.
    public static func normalize(_ input: String) -> String {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("cookie:") { text = String(text.dropFirst("cookie:".count)) }
        for part in text.split(separator: ";") {
            let pair = part.trimmingCharacters(in: .whitespaces)
            if pair.hasPrefix("sessionKey=") { return String(pair.dropFirst("sessionKey=".count)) }
        }
        return text.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
    }
}
