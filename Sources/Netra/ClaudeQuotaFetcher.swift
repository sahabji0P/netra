import Foundation
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
    }

    var windows: [QuotaWindow]
    var subscriptionType: String?
    /// When this quota was actually fetched from Anthropic. Carried through
    /// fallbacks so the UI can say how old the number is instead of "live".
    var fetchedAt: Date
    var source: Source
    /// Pay-as-you-go credits that cover you past the plan limits.
    var extraUsage: ClaudeExtraUsage?

    init(windows: [QuotaWindow], subscriptionType: String?, fetchedAt: Date,
         source: Source = .oauth, extraUsage: ClaudeExtraUsage? = nil) {
        self.windows = windows
        self.subscriptionType = subscriptionType
        self.fetchedAt = fetchedAt
        self.source = source
        self.extraUsage = extraUsage
    }

    private enum CodingKeys: String, CodingKey {
        case windows, subscriptionType, fetchedAt, source, extraUsage
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        windows = try values.decode([QuotaWindow].self, forKey: .windows)
        subscriptionType = try values.decodeIfPresent(String.self, forKey: .subscriptionType)
        fetchedAt = try values.decode(Date.self, forKey: .fetchedAt)
        source = try values.decodeIfPresent(Source.self, forKey: .source) ?? .oauth
        extraUsage = try values.decodeIfPresent(ClaudeExtraUsage.self, forKey: .extraUsage)
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
    case badCredentials
    case tokenExpired
    case http(Int)
    case decoding
}

enum ClaudeQuotaFetcher {
    static func fetch() async throws -> ClaudeQuota {
        let credentials = try readCredentials()

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClaudeQuotaError.http(-1) }
        guard http.statusCode == 200 else { throw ClaudeQuotaError.http(http.statusCode) }

        return try quota(fromResponse: data, subscriptionType: credentials.subscriptionType)
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

    struct Credentials {
        var accessToken: String
        var subscriptionType: String?
    }

    private static func readCredentials() throws -> Credentials {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            throw ClaudeQuotaError.keychain(status)
        }
        return try credentials(fromKeychainData: data)
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
        if let expiresAt = oauth["expiresAt"] as? Double,
           expiresAt / 1000 < now.timeIntervalSince1970 {
            throw ClaudeQuotaError.tokenExpired
        }
        return Credentials(
            accessToken: accessToken,
            subscriptionType: oauth["subscriptionType"] as? String
        )
    }
}
