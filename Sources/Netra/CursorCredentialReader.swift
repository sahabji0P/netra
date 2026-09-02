import Foundation
import SQLite3

/// Reads Cursor's saved login from its Electron state store. Cursor keeps no
/// usage data on local disk, so its access token (plus the user id encoded in
/// that token) is the only handle onto Cursor's own usage API. Read-only, and
/// never persisted by Netra — it is used for a single request and discarded.
enum CursorCredentialReader {
    struct Credentials {
        var accessToken: String
        var userID: String
        var membershipType: String?
    }

    static func read(
        applicationSupport: URL = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
    ) -> Credentials? {
        let db = applicationSupport
            .appendingPathComponent("Cursor/User/globalStorage/state.vscdb")
        guard FileManager.default.fileExists(atPath: db.path) else { return nil }
        guard let token = value(forKey: "cursorAuth/accessToken", in: db),
              tokenIsUsable(token),
              let userID = userID(fromToken: token) else { return nil }
        return Credentials(
            accessToken: token,
            userID: userID,
            membershipType: value(forKey: "cursorAuth/stripeMembershipType", in: db)
        )
    }

    /// The user id is the JWT `sub` claim's final segment (e.g.
    /// `auth0|user_01ABC` → `user_01ABC`). Cursor's API keys usage by it. The
    /// id is validated because it is interpolated into a request cookie.
    static func userID(fromToken token: String) -> String? {
        guard let claims = jwtClaims(token),
              let sub = claims["sub"] as? String else { return nil }
        let id = sub.split(separator: "|").last.map(String.init) ?? sub
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        guard !id.isEmpty, id.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return id
    }

    /// Gate on the JWT's own expiry (60s margin) rather than spending a
    /// request on a token Cursor has already rotated out.
    static func tokenIsUsable(_ token: String, now: Date = .now) -> Bool {
        guard let claims = jwtClaims(token),
              let exp = claims["exp"] as? Double else { return false }
        return Date(timeIntervalSince1970: exp).timeIntervalSince(now) > 60
    }

    private static func jwtClaims(_ token: String) -> [String: Any]? {
        let segments = token.split(separator: ".")
        guard segments.count >= 2,
              let payload = decodeBase64URL(String(segments[1])) else { return nil }
        return try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
    }

    private static func decodeBase64URL(_ string: String) -> Data? {
        var s = string.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s.append("=") }
        return Data(base64Encoded: s)
    }

    /// Reads one value from the VS Code `ItemTable`. Opened read-only and
    /// immutable so a running Cursor (WAL mode) can't block or be disturbed.
    private static func value(forKey key: String, in url: URL) -> String? {
        var handle: OpaquePointer?
        let uri = "file:\(url.path)?immutable=1"
        guard sqlite3_open_v2(
            uri, &handle,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil
        ) == SQLITE_OK else {
            sqlite3_close(handle)
            return nil
        }
        defer { sqlite3_close(handle) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            handle, "SELECT value FROM ItemTable WHERE key = ?1", -1, &statement, nil
        ) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }

        // SQLITE_TRANSIENT: SQLite must copy the key bytes, since `key` is
        // freed when this function returns.
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, key, -1, transient)

        guard sqlite3_step(statement) == SQLITE_ROW,
              let raw = sqlite3_column_text(statement, 0) else { return nil }
        let stored = String(cString: raw)
        // VS Code stores some values JSON-encoded ("\"token\""); unwrap if so.
        if stored.hasPrefix("\""), let data = stored.data(using: .utf8),
           let unquoted = try? JSONSerialization.jsonObject(with: data) as? String {
            return unquoted
        }
        return stored
    }
}
