import Foundation
import Security

/// Manages Claude OAuth tokens stored in the macOS Keychain by Claude Code.
///
/// Claude Code stores credentials under the Keychain service `Claude Code-credentials`
/// as a JSON blob containing an access token, refresh token, and expiry timestamp.
/// This class reads, refreshes, and caches those tokens so trm can use them
/// as API keys without requiring the user to paste one manually.
final class OAuthTokenManager: @unchecked Sendable {
    static let shared = OAuthTokenManager()

    // MARK: - Types

    struct OAuthCredentials {
        let accessToken: String
        let refreshToken: String
        let expiresAt: Date
    }

    enum OAuthError: LocalizedError {
        case noCredentials
        case refreshFailed(String)
        case keychainWriteFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .noCredentials:
                return "No Claude Code OAuth credentials found in Keychain."
            case .refreshFailed(let reason):
                return "Token refresh failed: \(reason)"
            case .keychainWriteFailed(let status):
                return "Failed to update Keychain (OSStatus \(status))."
            }
        }
    }

    // MARK: - Constants

    private static let keychainService = "Claude Code-credentials"
    private static let refreshURL = URL(string: "https://console.anthropic.com/v1/oauth/token")!
    private static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    /// Refresh 5 minutes before actual expiry to avoid mid-request failures.
    private static let expiryBuffer: TimeInterval = 5 * 60

    // MARK: - State

    private let queue = DispatchQueue(label: "trm.oauth-token-manager")
    private var cached: OAuthCredentials?

    private init() {}

    // MARK: - Public API

    /// Whether the Keychain contains Claude Code OAuth credentials.
    var isAvailable: Bool {
        queue.sync {
            if cached != nil { return true }
            return readFromKeychain() != nil
        }
    }

    /// Returns a valid access token, refreshing if needed.
    /// Throws if no credentials exist or refresh fails.
    func validAccessToken() async throws -> String {
        let creds: OAuthCredentials = try queue.sync {
            if let c = cached, !Self.isExpired(c) {
                return c
            }
            guard let c = readFromKeychain() else {
                throw OAuthError.noCredentials
            }
            cached = c
            return c
        }

        if Self.isExpired(creds) {
            let refreshed = try await refresh(using: creds.refreshToken)
            queue.sync { cached = refreshed }
            writeToKeychain(refreshed)
            return refreshed.accessToken
        }

        return creds.accessToken
    }

    /// Force-refresh the token (e.g. after a 401).
    func forceRefresh() async throws -> String {
        let refreshToken: String = try queue.sync {
            if let c = cached {
                return c.refreshToken
            }
            guard let c = readFromKeychain() else {
                throw OAuthError.noCredentials
            }
            cached = c
            return c.refreshToken
        }

        let refreshed = try await refresh(using: refreshToken)
        queue.sync { cached = refreshed }
        writeToKeychain(refreshed)
        return refreshed.accessToken
    }

    /// Clear the in-memory cache (e.g. on sign-out or for testing).
    func clearCache() {
        queue.sync { cached = nil }
    }

    // MARK: - Keychain Read

    func readFromKeychain() -> OAuthCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }

        return parseCredentials(from: data)
    }

    // MARK: - Keychain Write

    func writeToKeychain(_ credentials: OAuthCredentials) {
        guard let data = encodeCredentials(credentials) else { return }

        // Try to update first; if the item doesn't exist, add it.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
        ]
        let update: [String: Any] = [
            kSecValueData as String: data
        ]

        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }

    // MARK: - Token Refresh

    func refresh(using refreshToken: String) async throws -> OAuthCredentials {
        var request = URLRequest(url: Self.refreshURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = "grant_type=refresh_token&refresh_token=\(refreshToken)&client_id=\(Self.clientID)"
        request.httpBody = body.data(using: .utf8)
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw OAuthError.refreshFailed("No HTTP response")
        }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OAuthError.refreshFailed("HTTP \(http.statusCode): \(body)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String else {
            throw OAuthError.refreshFailed("Invalid response JSON")
        }

        let newRefreshToken = json["refresh_token"] as? String ?? refreshToken
        let expiresIn = json["expires_in"] as? TimeInterval ?? 28800
        let expiresAt = Date().addingTimeInterval(expiresIn)

        return OAuthCredentials(
            accessToken: accessToken,
            refreshToken: newRefreshToken,
            expiresAt: expiresAt
        )
    }

    // MARK: - Helpers

    private static func isExpired(_ creds: OAuthCredentials) -> Bool {
        creds.expiresAt.timeIntervalSinceNow < expiryBuffer
    }

    /// Parse the Claude Code credential JSON from Keychain data.
    ///
    /// Expected format:
    /// ```json
    /// {"claudeAiOauth":{"accessToken":"sk-ant-oat01-...","refreshToken":"sk-ant-ort01-...","expiresAt":1771505562874}}
    /// ```
    private func parseCredentials(from data: Data) -> OAuthCredentials? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let accessToken = oauth["accessToken"] as? String,
              let refreshToken = oauth["refreshToken"] as? String,
              let expiresAtMs = oauth["expiresAt"] as? Double else {
            return nil
        }

        let expiresAt = Date(timeIntervalSince1970: expiresAtMs / 1000.0)
        return OAuthCredentials(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresAt
        )
    }

    /// Encode credentials back into the Claude Code JSON format for Keychain storage.
    private func encodeCredentials(_ credentials: OAuthCredentials) -> Data? {
        // Read the existing Keychain data to preserve any other fields.
        var root: [String: Any] = [:]
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data,
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = existing
        }

        var oauth = (root["claudeAiOauth"] as? [String: Any]) ?? [:]
        oauth["accessToken"] = credentials.accessToken
        oauth["refreshToken"] = credentials.refreshToken
        oauth["expiresAt"] = credentials.expiresAt.timeIntervalSince1970 * 1000.0
        root["claudeAiOauth"] = oauth

        return try? JSONSerialization.data(withJSONObject: root)
    }
}
