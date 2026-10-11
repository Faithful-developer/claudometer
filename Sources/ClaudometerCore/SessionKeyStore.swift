import Foundation
import Security

/// The claude.ai session key the user pastes in Settings, kept in Claudometer's own Keychain
/// item. The key is never written to disk, `UserDefaults`, logs or the widget's shared folder.
///
/// The item is created and read through `/usr/bin/security`, so its access list trusts that
/// tool rather than this build's ad-hoc signature, and rebuilds or updates don't bring back
/// the Keychain password prompt.
public struct SessionKeyStore: Sendable {
    public static let service = "dev.claudometer.claude-ai-session"
    static let account = "sessionKey.v2"
    /// Item saved by 0.1.3 and earlier through the Security framework; its access list is tied
    /// to one build. Removed on the next Save or Remove.
    static let legacyAccount = "sessionKey"

    public init() {}

    public enum Access: Equatable, Sendable {
        case key(String)
        case missing
        /// The user denied the Keychain prompt (or it couldn't be shown).
        case denied
    }

    public func read() -> Access {
        guard let output = SecurityTool.run(["find-generic-password", "-s", Self.service, "-a", Self.account, "-w"]) else {
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

    /// Checks the item's attributes only, which never shows a Keychain prompt.
    public var hasKey: Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess
    }

    /// Set after a denied Keychain prompt; kept across launches.
    public var isPaused: Bool {
        get { UserDefaults.standard.bool(forKey: Self.pausedKey) }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: Self.pausedKey) }
    }

    static let pausedKey = "sessionKeyAccessPaused"

    public func save(_ key: String) throws {
        deleteLegacyItem()
        // Hex via stdin: no quoting to get wrong, and the key never shows up in `ps`.
        let hex = Data(key.utf8).map { String(format: "%02x", $0) }.joined()
        let command = "add-generic-password -U -s \(Self.service) -a \(Self.account) "
            + "-l \"Claudometer claude.ai session\" -X \(hex)\n"
        guard SecurityTool.run(["-i"], input: command)?.status == 0, read() == .key(key) else {
            throw AppError.keychainDenied
        }
        isPaused = false
    }

    public func delete() {
        _ = SecurityTool.run(["delete-generic-password", "-s", Self.service, "-a", Self.account])
        deleteLegacyItem()
        isPaused = false
    }

    private func deleteLegacyItem() {
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
