import Foundation
import Security

/// The claude.ai session key the user pastes in Settings, kept in Claudometer's own Keychain
/// item. Never written to disk, `UserDefaults`, logs or the widget's shared folder.
public struct SessionKeyStore: Sendable {
    public static let service = "dev.claudometer.claude-ai-session"
    static let account = "sessionKey"

    public init() {}

    public func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty else {
            return nil
        }
        return key
    }

    public var hasKey: Bool { load() != nil }

    public func save(_ key: String) throws {
        let data = Data(key.utf8)
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]
        var status = SecItemUpdate(match as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = match
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "Claudometer claude.ai session"
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw AppError.keychainDenied }
    }

    public func delete() {
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
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
