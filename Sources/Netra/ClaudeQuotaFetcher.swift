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

    init(windows: [QuotaWindow], subscriptionType: String?, fetchedAt: Date,
         source: Source = .oauth) {
        self.windows = windows
        self.subscriptionType = subscriptionType
        self.fetchedAt = fetchedAt
        self.source = source
    }

    private enum CodingKeys: String, CodingKey {
        case windows, subscriptionType, fetchedAt, source
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        windows = try values.decode([QuotaWindow].self, forKey: .windows)
        subscriptionType = try values.decodeIfPresent(String.self, forKey: .subscriptionType)
        fetchedAt = try values.decode(Date.self, forKey: .fetchedAt)
        source = try values.decodeIfPresent(Source.self, forKey: .source) ?? .oauth
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

        var windows: [QuotaWindow] = []
        func addWindow(key: String, label: String) {
            guard let window = object[key] as? [String: Any],
                  let utilization = window["utilization"] as? Double else { return }
            let resets = (window["resets_at"] as? String).flatMap(parseDate)
            windows.append(QuotaWindow(label: label, usedPercent: utilization, resetsAt: resets))
        }
        addWindow(key: "five_hour", label: "5h")
        addWindow(key: "seven_day", label: "weekly")
        addWindow(key: "seven_day_opus", label: "weekly · Opus")
        addWindow(key: "seven_day_sonnet", label: "weekly · Sonnet")

        guard !windows.isEmpty else { throw ClaudeQuotaError.decoding }
        return ClaudeQuota(windows: windows, subscriptionType: subscriptionType, fetchedAt: now)
    }

    /// Anthropic sends microsecond-precision ISO timestamps; shared with the
    /// Claude Code cache reader, which sees the same format.
    static func parseDate(_ string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: string) ?? ISO8601DateFormatter().date(from: string)
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
