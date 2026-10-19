import Foundation

/// One Claude account Claudometer tracks (TZ F-2).
///
/// The Claude Code login is always the first account. Up to `AccountStore.maxExtra` more are
/// added with a claude.ai session key each. A key for the Claude Code account itself is that
/// account's backup (TZ §2.3), not an account of its own.
public struct Account: Codable, Hashable, Identifiable, Sendable {
    public static let primaryID = "claude-code"

    public let id: String
    /// Name chosen by the user; empty shows the default from `title`.
    public var name: String
    /// claude.ai organization the account reads. Set for added accounts; the Claude Code
    /// account's comes from its own login.
    public var orgUUID: String?

    public init(id: String, name: String = "", orgUUID: String? = nil) {
        self.id = id
        self.name = name
        self.orgUUID = orgUUID
    }

    public static let primary = Account(id: primaryID)

    /// A new account with a fresh id.
    public static func added(name: String, orgUUID: String) -> Account {
        Account(id: UUID().uuidString.lowercased(), name: name, orgUUID: orgUUID)
    }

    public var isPrimary: Bool { id == Self.primaryID }

    public var title: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return isPrimary ? tr("Claude Code") : tr("Account")
    }

    /// File in the shared folder for this account: the Claude Code account keeps the names
    /// used before accounts existed (so placed widgets keep working), others get their id.
    public func fileName(_ base: String) -> String {
        isPrimary ? "\(base).json" : "\(base).\(id).json"
    }

    /// Ids end up in file names and Keychain item names, so only plain ones are accepted.
    static func isValidID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }
}

/// `accounts.json` in the shared folder. Holds names and organization ids only, never a key,
/// so the widget can read it to offer the accounts in Edit Widget.
public struct AccountStore: Sendable {
    /// Extra accounts besides Claude Code's; four in all fit the popover's switcher.
    public static let maxExtra = 3

    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public static func `default`() -> AccountStore {
        AccountStore(fileURL: SnapshotStore.sharedDirectory.appendingPathComponent("accounts.json"))
    }

    public func load() -> [Account] {
        let saved = (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode([Account].self, from: $0) } ?? []
        return Self.normalized(saved)
    }

    /// The file exists but doesn't decode (damaged, or written by a newer version).
    public var isUnreadable: Bool {
        guard let data = try? Data(contentsOf: fileURL) else { return false }
        return (try? JSONDecoder().decode([Account].self, from: data)) == nil
    }

    public func save(_ accounts: [Account]) {
        guard let data = try? JSONEncoder().encode(Self.normalized(accounts)) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    /// The Claude Code account first, then valid, distinct extra accounts up to the cap.
    static func normalized(_ accounts: [Account]) -> [Account] {
        let primary = accounts.first(where: \.isPrimary) ?? .primary
        var seen: Set<String> = [primary.id]
        let extras = accounts.filter { account in
            !account.isPrimary && Account.isValidID(account.id) && seen.insert(account.id).inserted
        }
        return [primary] + extras.prefix(maxExtra)
    }
}

/// The account Claude Code is logged in to, from `~/.claude.json`. Only the organization is
/// read; the token stays in the Keychain item `CredentialsProvider` reads.
public struct ClaudeCodeProfile: Equatable, Sendable {
    public let orgUUID: String?

    public static func load() -> ClaudeCodeProfile? {
        let file = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude.json")
        return (try? Data(contentsOf: file)).flatMap(parse)
    }

    static func parse(_ data: Data) -> ClaudeCodeProfile? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = root["oauthAccount"] as? [String: Any] else { return nil }
        return ClaudeCodeProfile(orgUUID: account["organizationUuid"] as? String)
    }
}
