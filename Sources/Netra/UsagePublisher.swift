import Foundation
import LocalAuthentication
import os
import Security

/// Endpoint rules for publishing: https only, except plain http to this Mac
/// (localhost / 127.0.0.1) for developing the site locally.
enum UsagePublishEndpoint {
    static func validated(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        switch scheme {
        case "https": return url
        case "http": return ["localhost", "127.0.0.1"].contains(host) ? url : nil
        default: return nil
        }
    }
}

/// The website token, kept in Netra's own Keychain item (never Claude
/// Code's, never UserDefaults, never logged).
enum UsagePublishToken {
    static let service = "com.sahabji0P.netra.usage-feed"
    static let account = "publish-token"

    enum KeychainError: Error, Equatable {
        /// macOS wants the user's consent (e.g. a rebuilt, re-signed app).
        case needsApproval
        case status(OSStatus)
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// The saved token, or nil when none is saved. Background reads never
    /// show a Keychain dialog; user actions may.
    static func read(allowingPrompt: Bool) throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if !allowingPrompt {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let token = String(data: data, encoding: .utf8),
                  !token.isEmpty else { return nil }
            return token
        case errSecItemNotFound:
            return nil
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled, errSecNoAccessForItem:
            throw KeychainError.needsApproval
        default:
            throw KeychainError.status(status)
        }
    }

    /// Whether a token is saved, from the item's attributes only (no secret
    /// is read, so this never prompts).
    static func exists() -> Bool {
        var query = baseQuery
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        var item: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess
    }

    static func save(_ token: String) throws {
        try delete()
        var query = baseQuery
        query[kSecValueData as String] = Data(token.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        query[kSecAttrLabel as String] = "Netra website publishing token"
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    static func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.status(status) }
    }
}

/// What the publisher remembers between refreshes and launches. Never holds
/// the token.
struct UsagePublisherState: Codable, Equatable, Sendable {
    var lastSuccessAt: Date?
    /// `UsageFeed.contentHash()` of the last feed the site accepted.
    var lastContentHash: String?
    var consecutiveFailures = 0
    var nextRetryAt: Date?
    /// Set when the site rejected the token or the feed (401/413/422): no
    /// more automatic attempts until settings change or, for a rejected
    /// feed, Netra's version changes.
    var stoppedVersion: String?
    /// The last problem, in plain words, for the settings status line.
    var lastError: String?

    var isStopped: Bool { stoppedVersion != nil }
}

/// Pushes the usage feed to the owner's website (opt-in), following the
/// transport rules of `netra.usage-feed/1`:
/// - at most one publish every 5 minutes (measured from the last success);
/// - no POST when the content (ignoring `generatedAt`) matches the last
///   success, unless that success is over an hour old (heartbeat);
/// - 429 / 5xx / network errors back off 30 s, doubling, capped at 30 min;
/// - 401 / 413 / 422 stop publishing until settings (or the version) change.
/// Retries are driven by the refresh loop, so a failure never blocks a
/// refresh and nothing runs while publishing is off.
actor UsagePublisher {
    enum SkipReason: Equatable, Sendable {
        case notConfigured, noToken, stopped, backingOff, tooSoon, unchanged, inFlight
    }

    enum Outcome: Equatable, Sendable {
        case published
        case skipped(SkipReason)
        /// Transient; retried after the backoff.
        case failed(String)
        /// Needs the user; no automatic retries.
        case stopped(String)
    }

    static let minimumInterval: TimeInterval = 5 * 60
    static let heartbeatInterval: TimeInterval = 60 * 60
    static let initialBackoff: TimeInterval = 30
    static let maximumBackoff: TimeInterval = 30 * 60
    static let maximumBodyBytes = 2 * 1024 * 1024
    private static let stateKey = "publisher.usageFeed.state"

    typealias TokenProvider = @Sendable (_ allowingPrompt: Bool) throws -> String?

    private let session: URLSession
    private let defaults: UserDefaults
    private let version: String
    private let now: @Sendable () -> Date
    private let tokenProvider: TokenProvider
    private let log = Logger(subsystem: "com.sahabji0P.netra", category: "publish")
    private var cachedToken: String?
    private var inFlight = false
    private(set) var state: UsagePublisherState

    init(
        session: URLSession = UsagePublisher.defaultSession(),
        defaults: UserDefaults = .standard,
        version: String,
        now: @escaping @Sendable () -> Date = { Date() },
        tokenProvider: @escaping TokenProvider = { try UsagePublishToken.read(allowingPrompt: $0) }
    ) {
        self.session = session
        self.defaults = defaults
        self.version = version
        self.now = now
        self.tokenProvider = tokenProvider
        var state = defaults.data(forKey: Self.stateKey)
            .flatMap { try? JSONDecoder().decode(UsagePublisherState.self, from: $0) } ?? UsagePublisherState()
        // A rejected feed may be accepted by a newer Netra.
        if let stopped = state.stoppedVersion, stopped != version {
            state.stoppedVersion = nil
            state.lastError = nil
        }
        self.state = state
    }

    static func defaultSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }

    /// The endpoint, enabled flag, or token changed: forget the stop, the
    /// backoff, and the cached token, and re-send the next feed even if its
    /// content matches (the new destination may not have it).
    func settingsChanged() {
        cachedToken = nil
        state.stoppedVersion = nil
        state.consecutiveFailures = 0
        state.nextRetryAt = nil
        state.lastContentHash = nil
        state.lastError = nil
        persist()
    }

    /// Publishes when the transport rules allow. `force` is the user's
    /// "Publish now": it bypasses the interval, hash, backoff, and stop
    /// gates (never the size cap) and may show a Keychain prompt.
    @discardableResult
    func publish(_ feed: UsageFeed, to endpoint: URL?, force: Bool = false) async -> Outcome {
        guard let endpoint else { return .skipped(.notConfigured) }
        guard !inFlight else { return .skipped(.inFlight) }
        let hash = feed.contentHash()
        let start = now()
        if !force {
            if state.isStopped { return .skipped(.stopped) }
            if let next = state.nextRetryAt, start < next { return .skipped(.backingOff) }
            if let last = state.lastSuccessAt {
                let age = start.timeIntervalSince(last)
                if age >= 0, age < Self.minimumInterval { return .skipped(.tooSoon) }
                if hash == state.lastContentHash, age >= 0, age < Self.heartbeatInterval {
                    return .skipped(.unchanged)
                }
            }
        }

        inFlight = true
        defer { inFlight = false }

        let token: String
        do {
            guard let found = try cachedToken ?? tokenProvider(force) else {
                state.lastError = "Save a website token to publish."
                persist()
                return .skipped(.noToken)
            }
            token = found
            cachedToken = found
        } catch UsagePublishToken.KeychainError.needsApproval {
            state.lastError = "Netra needs Keychain access to read the website token. Click Publish now to allow it."
            persist()
            return .skipped(.noToken)
        } catch {
            state.lastError = "Couldn't read the website token from the Keychain."
            persist()
            return .skipped(.noToken)
        }

        let body: Data
        do {
            body = try feed.encoded()
        } catch {
            return stop("Netra couldn't encode the usage feed.")
        }
        guard body.count <= Self.maximumBodyBytes else {
            return stop("The usage feed is larger than the website's 2 MB limit.")
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            return backOff("Couldn't reach the website (\(error.localizedDescription)).")
        }
        guard let status = (response as? HTTPURLResponse)?.statusCode else {
            return backOff("The website sent an unreadable response.")
        }
        log.info("usage feed POST answered \(status, privacy: .public)")

        switch status {
        case 200...299, 409:
            // 204 stored, 200 {"status":"unchanged"}, 409 older than stored:
            // either way the site has this feed or a newer one.
            state.lastSuccessAt = now()
            state.lastContentHash = hash
            state.consecutiveFailures = 0
            state.nextRetryAt = nil
            state.stoppedVersion = nil
            state.lastError = nil
            persist()
            return .published
        case 401:
            return stop("The website rejected the token (401). Save the correct token to resume.")
        case 413:
            return stop("The website says the feed is too large (413)\(Self.detail(data)).")
        case 422:
            return stop("The website rejected the feed (422)\(Self.detail(data)).")
        case 429:
            return backOff("The website is rate-limiting Netra (429).")
        case 500...599:
            return backOff("The website had a server error (\(status)).")
        case 400...499:
            // Not in the contract: a wrong URL or method is a settings problem.
            return stop("The website answered \(status). Check the endpoint URL.")
        default:
            return backOff("The website answered \(status).")
        }
    }

    private func stop(_ message: String) -> Outcome {
        state.stoppedVersion = version
        state.nextRetryAt = nil
        state.lastError = message
        persist()
        log.error("usage feed publishing stopped: \(message, privacy: .public)")
        return .stopped(message)
    }

    private func backOff(_ message: String) -> Outcome {
        state.consecutiveFailures += 1
        let exponent = Double(min(state.consecutiveFailures - 1, 16))
        let delay = min(Self.initialBackoff * pow(2, exponent), Self.maximumBackoff)
        state.nextRetryAt = now().addingTimeInterval(delay)
        state.lastError = message
        persist()
        return .failed(message)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(state) {
            defaults.set(data, forKey: Self.stateKey)
        }
    }

    /// The site's `{"error": "..."}` explanation, shortened for one line.
    private static func detail(_ data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = JSONValue.string(object["error"]) else { return "" }
        return ": \(message.prefix(160))"
    }
}
