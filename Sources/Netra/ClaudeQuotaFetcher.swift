import Foundation
import Security

/// Real Claude subscription limits, fetched from Anthropic's OAuth usage
/// endpoint using the token Claude Code keeps in the macOS Keychain. The
/// token never leaves this process except to api.anthropic.com itself.
struct ClaudeQuota: Codable, Sendable {
    var windows: [QuotaWindow]
    var subscriptionType: String?
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
        return ClaudeQuota(windows: windows, subscriptionType: credentials.subscriptionType)
    }

    private static func parseDate(_ string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }

    private struct Credentials {
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
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = object["claudeAiOauth"] as? [String: Any],
              let accessToken = oauth["accessToken"] as? String else {
            throw ClaudeQuotaError.badCredentials
        }
        // expiresAt is epoch milliseconds; Claude Code refreshes it whenever it runs.
        if let expiresAt = oauth["expiresAt"] as? Double,
           expiresAt / 1000 < Date.now.timeIntervalSince1970 {
            throw ClaudeQuotaError.tokenExpired
        }
        return Credentials(
            accessToken: accessToken,
            subscriptionType: oauth["subscriptionType"] as? String
        )
    }
}
