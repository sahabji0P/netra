import Foundation
import LocalAuthentication
import os
import Security

/// Real Claude subscription limits, fetched from Anthropic's OAuth usage
/// endpoint using the token Claude Code keeps in the macOS Keychain. The
/// token never leaves this process except to api.anthropic.com itself.
struct ClaudeQuota: Codable, Sendable {
    /// Where the numbers came from. Both are Anthropic-reported percentages;
    /// they differ in freshness (a direct fetch is live, Claude Code's cache
    /// is as old as its last server contact).
    enum Source: String, Codable, Sendable {
        case oauth
        case claudeCodeCache
        /// Netra's own record for this account, shown until a fresh read
        /// arrives (e.g. right after switching to a parked account).
        case lastSeen
    }

    var windows: [QuotaWindow]
    var subscriptionType: String?
    /// When this quota was actually fetched from Anthropic. Carried through
    /// fallbacks so the UI can say how old the number is instead of "live".
    var fetchedAt: Date
    var source: Source
    /// Pay-as-you-go credits that cover you past the plan limits.
    var extraUsage: ClaudeExtraUsage?
    /// `AccountIdentity.key` of the account these limits belong to, when
    /// known. A previous quota is only reused for the same account.
    var accountKey: String?

    init(windows: [QuotaWindow], subscriptionType: String?, fetchedAt: Date,
         source: Source = .oauth, extraUsage: ClaudeExtraUsage? = nil, accountKey: String? = nil) {
        self.windows = windows
        self.subscriptionType = subscriptionType
        self.fetchedAt = fetchedAt
        self.source = source
        self.extraUsage = extraUsage
        self.accountKey = accountKey
    }

    private enum CodingKeys: String, CodingKey {
        case windows, subscriptionType, fetchedAt, source, extraUsage, accountKey
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        windows = try values.decode([QuotaWindow].self, forKey: .windows)
        subscriptionType = try values.decodeIfPresent(String.self, forKey: .subscriptionType)
        fetchedAt = try values.decode(Date.self, forKey: .fetchedAt)
        source = try values.decodeIfPresent(Source.self, forKey: .source) ?? .oauth
        extraUsage = try values.decodeIfPresent(ClaudeExtraUsage.self, forKey: .extraUsage)
        accountKey = try values.decodeIfPresent(String.self, forKey: .accountKey)
    }

    /// Windows still inside their reported cycle. A window whose reset has
    /// passed shows a percentage that no longer means anything; drop it. A
    /// window without a reset stays usable only while the fetch is recent.
    func activeWindows(now: Date = .now) -> [QuotaWindow] {
        let undatedWindowFreshness: TimeInterval = 60 * 60
        return windows.filter { window in
            if let resetsAt = window.resetsAt { return resetsAt > now }
            return now.timeIntervalSince(fetchedAt) <= undatedWindowFreshness
        }
    }
}

/// Anthropic's `extra_usage` block: credits that keep you working after a
/// plan limit. Amounts are in minor units (`decimal_places`, cents for USD).
struct ClaudeExtraUsage: Codable, Hashable, Sendable {
    var isEnabled: Bool
    var usedUSD: Double?
    var monthlyLimitUSD: Double?
    /// e.g. "out_of_credits".
    var disabledReason: String?
    var everEnabled: Bool

    static func parse(_ object: Any?) -> ClaudeExtraUsage? {
        guard let object = object as? [String: Any], let enabled = object["is_enabled"] as? Bool else { return nil }
        let scale = pow(10, JSONValue.number(object["decimal_places"]) ?? 2)
        return ClaudeExtraUsage(
            isEnabled: enabled,
            usedUSD: JSONValue.number(object["used_credits"]).map { $0 / scale },
            monthlyLimitUSD: JSONValue.number(object["monthly_limit"]).map { $0 / scale },
            disabledReason: JSONValue.string(object["disabled_reason"]),
            everEnabled: object["credits_ever_enabled"] as? Bool ?? enabled
        )
    }

    /// One line for the limit card, or nil when there is nothing to say.
    var summary: String? {
        if isEnabled {
            let used = usedUSD.map(Format.cost) ?? "$0.00"
            return monthlyLimitUSD.map { "Extra usage on · \(used) of \(Format.cost($0)) this month" }
                ?? "Extra usage on · \(used) used this month"
        }
        guard everEnabled else { return nil }
        return disabledReason == "out_of_credits" ? "Extra usage credits used up" : "Extra usage off"
    }
}

enum ClaudeQuotaError: Error {
    case keychain(OSStatus)
    /// macOS would have to ask before Netra may read Claude Code's
    /// Keychain item; only a user action is allowed to trigger that prompt.
    case keychainNeedsApproval
    case badCredentials
    case tokenExpired
    case http(Int)
    case decoding
}

enum ClaudeQuotaFetcher {
    /// Background refreshes pass `allowingPrompt: false`, so a missing or
    /// one-time Keychain grant fails fast instead of showing a macOS
    /// password dialog every minute. Only a user action allows the prompt.
    static func fetch(allowingPrompt: Bool = false) async throws -> ClaudeQuota {
        let credentials = try cachedCredentials() ?? readCredentials(allowingPrompt: allowingPrompt)
        do {
            return try await fetchUsage(accessToken: credentials.accessToken, subscriptionType: credentials.subscriptionType)
        } catch ClaudeQuotaError.http(401) {
            // A rejected token was rotated or revoked; read the current one next time.
            invalidateCachedCredentials()
            throw ClaudeQuotaError.http(401)
        }
    }

    /// Forgets the in-memory token, e.g. after Netra switched Claude Code to
    /// another account, so the next fetch reads the new account's sign-in.
    static func invalidateCachedCredentials() {
        credentialCache.withLock { $0 = nil }
    }

    /// One usage request with a given access token. Also used for a parked
    /// account's still-valid token; this never refreshes a token.
    static func fetchUsage(accessToken: String, subscriptionType: String?) async throws -> ClaudeQuota {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClaudeQuotaError.http(-1) }
        guard http.statusCode == 200 else { throw ClaudeQuotaError.http(http.statusCode) }

        return try quota(fromResponse: data, subscriptionType: subscriptionType)
    }

    /// Parses the usage-endpoint response. Split out so the (unofficial,
    /// schema-unstable) contract can be locked down with fixture tests.
    static func quota(fromResponse data: Data, subscriptionType: String?,
                      now: Date = .now) throws -> ClaudeQuota {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeQuotaError.decoding
        }

        let windows = ClaudeCachedQuotaReader.windows(from: object)

        guard !windows.isEmpty else { throw ClaudeQuotaError.decoding }
        return ClaudeQuota(
            windows: windows, subscriptionType: subscriptionType, fetchedAt: now,
            extraUsage: ClaudeExtraUsage.parse(object["extra_usage"])
        )
    }

    struct Credentials: Sendable {
        var accessToken: String
        var subscriptionType: String?
        var expiresAt: Date?
    }

    /// The token stays in memory only (never persisted or logged), so the
    /// Keychain is read once per token rather than on every refresh.
    private static let credentialCache = OSAllocatedUnfairLock<Credentials?>(initialState: nil)

    private static func cachedCredentials(now: Date = .now) -> Credentials? {
        credentialCache.withLock { cached in
            if let credentials = cached, !isReusable(credentials, now: now) { cached = nil }
            return cached
        }
    }

    /// Reuse a token until shortly before it expires; a token without an
    /// expiry is re-read from the Keychain rather than trusted forever.
    static func isReusable(_ credentials: Credentials, now: Date = .now) -> Bool {
        guard let expiresAt = credentials.expiresAt else { return false }
        return expiresAt.timeIntervalSince(now) > 5 * 60
    }

    private static func readCredentials(allowingPrompt: Bool) throws -> Credentials {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if !allowingPrompt {
            // Both are needed: the LAContext flag covers authentication UI,
            // and the UI-fail policy covers the login keychain's
            // Allow/Deny access-control dialog.
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            throw keychainError(for: status)
        }
        let credentials = try credentials(fromKeychainData: data)
        credentialCache.withLock { $0 = credentials }
        return credentials
    }

    /// Statuses meaning "macOS wants the user's consent" (a silent read that
    /// would have prompted, or a prompt the user cancelled or denied).
    static func keychainError(for status: OSStatus) -> ClaudeQuotaError {
        switch status {
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled, errSecNoAccessForItem:
            .keychainNeedsApproval
        default:
            .keychain(status)
        }
    }

    /// Parses the Keychain payload. Split out so the credential contract can
    /// be tested with fixtures instead of a live Keychain.
    static func credentials(fromKeychainData data: Data, now: Date = .now) throws -> Credentials {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = object["claudeAiOauth"] as? [String: Any],
              let accessToken = oauth["accessToken"] as? String else {
            throw ClaudeQuotaError.badCredentials
        }
        // expiresAt is epoch milliseconds; Claude Code refreshes it whenever it runs.
        let expiresAt = JSONValue.number(oauth["expiresAt"]).map { Date(timeIntervalSince1970: $0 / 1000) }
        if let expiresAt, expiresAt < now {
            throw ClaudeQuotaError.tokenExpired
        }
        return Credentials(
            accessToken: accessToken,
            subscriptionType: oauth["subscriptionType"] as? String,
            expiresAt: expiresAt
        )
    }
}
