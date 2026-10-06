import Foundation
import Security

public struct Credentials: Sendable {
    public let accessToken: String
    public let expiresAt: Date?
    public let plan: String?

    public var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt <= Date()
    }
}

/// Reads the OAuth login that Claude Code stores in the macOS login Keychain.
///
/// Read-only: Claudometer never writes, deletes or refreshes this item. The token is kept
/// in memory only and is never logged or persisted.
public struct CredentialsProvider: Sendable {
    public static let keychainService = "Claude Code-credentials"

    public init() {}

    public func load() throws -> Credentials {
        let raw = try readKeychain()
        return try Self.parse(raw)
    }

    static func parse(_ data: Data) throws -> Credentials {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else {
            throw AppError.notSignedIn
        }
        let expiresAt = (oauth["expiresAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        return Credentials(accessToken: token, expiresAt: expiresAt, plan: oauth["subscriptionType"] as? String)
    }

    private func readKeychain() throws -> Data {
        // 1. `/usr/bin/security` is normally already trusted by the item's ACL (Claude Code
        //    creates the item through it), so this avoids a Keychain prompt on every rebuild.
        var firstError: AppError
        switch readViaSecurityTool() {
        case .success(let data): return data
        case .failure(let error): firstError = error
        }
        // 2. Security framework (may show the "allow access" prompt once).
        if firstError != .notSignedIn {
            do {
                return try readViaSecurityFramework()
            } catch let error as AppError {
                firstError = error
            }
        }
        // 3. Plain-file storage used by Claude Code on some setups.
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        if let data = try? Data(contentsOf: file) { return data }
        throw firstError
    }

    private func readViaSecurityTool() -> Result<Data, AppError> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", Self.keychainService, "-w"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return .failure(.keychainDenied)
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            // 44 == errSecItemNotFound
            return .failure(process.terminationStatus == 44 ? .notSignedIn : .keychainDenied)
        }
        let trimmed = data.trimmingTrailingNewlines()
        return trimmed.isEmpty ? .failure(.notSignedIn) : .success(trimmed)
    }

    private func readViaSecurityFramework() throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { throw AppError.notSignedIn }
            return data
        case errSecItemNotFound:
            throw AppError.notSignedIn
        default:
            throw AppError.keychainDenied
        }
    }
}

private extension Data {
    func trimmingTrailingNewlines() -> Data {
        var copy = self
        while let last = copy.last, last == 0x0A || last == 0x0D { copy.removeLast() }
        return copy
    }
}
