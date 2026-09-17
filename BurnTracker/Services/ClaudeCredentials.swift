import Foundation
import Security

/// Reads the OAuth token Claude Code already stores. Lives outside `Core/` so the
/// engine keeps to Foundation and stays testable without the Security framework.
///
/// Deliberately read-only. The blob carries a refresh token, but spending it would
/// rotate the pair and could sign Claude Code itself out. If the token is expired
/// we wait for Claude Code to renew it rather than racing it.
enum ClaudeCredentials {
    static let service = "Claude Code-credentials"
    /// Used when the credentials live in a file instead of the Keychain.
    static let fileFallback = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: ".claude/.credentials.json")

    struct Token: Sendable, Equatable {
        let accessToken: String
        let expiresAt: Date?

        func isExpired(at now: Date, leeway: TimeInterval = 60) -> Bool {
            guard let expiresAt else { return false }
            return now.addingTimeInterval(leeway) >= expiresAt
        }
    }

    private struct Stored: Decodable {
        let claudeAiOauth: OAuth?

        struct OAuth: Decodable {
            let accessToken: String?
            let expiresAt: Double?      // epoch milliseconds
        }
    }

    /// Keychain first, then the file some installs use.
    static func read(now: Date = Date()) throws -> Token {
        var denied = false
        var data: Data?
        do { data = try keychainData() } catch UsageAPIError.keychainDenied { denied = true }

        if data == nil { data = try? Data(contentsOf: fileFallback) }
        guard let data, let token = parse(data) else {
            throw denied ? UsageAPIError.keychainDenied : UsageAPIError.noToken
        }
        guard !token.isExpired(at: now) else { throw UsageAPIError.tokenExpired }
        return token
    }

    static func parse(_ data: Data) -> Token? {
        guard let stored = try? JSONDecoder().decode(Stored.self, from: data),
              let oauth = stored.claudeAiOauth,
              let accessToken = oauth.accessToken,
              !accessToken.isEmpty
        else { return nil }

        return Token(
            accessToken: accessToken,
            // Milliseconds since epoch, as Claude Code writes it.
            expiresAt: oauth.expiresAt.map { Date(timeIntervalSince1970: $0 / 1000) }
        )
    }

    private static func keychainData() throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess: return item as? Data
        case errSecItemNotFound: return nil
        // The item belongs to Claude Code, so macOS asks the user to allow this
        // app. Denial is reported distinctly: it is actionable, and unlike a
        // missing sign-in the user can fix it from the prompt on the next run.
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed:
            throw UsageAPIError.keychainDenied
        default: throw UsageAPIError.noToken
        }
    }

    /// Ready to hand to `ClaudeUsageAPI`.
    static var tokenProvider: ClaudeUsageAPI.TokenProvider {
        { try read().accessToken }
    }
}
