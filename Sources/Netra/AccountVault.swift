import Foundation

// MARK: - Running helper tools

/// Runs a short-lived helper (`security`, `codex`, `ps`) to completion with a
/// timeout. Blocking: call from an actor or detached task, never the main actor.
enum ProcessRunner {
    struct Result: Sendable {
        var status: Int32
        var stdout: Data
        var timedOut: Bool
    }

    /// A child that exits early must not kill Netra when its stdin is
    /// written; with SIGPIPE ignored the write throws instead.
    private static let ignoreSIGPIPE: Void = { signal(SIGPIPE, SIG_IGN) }()

    /// `capturesOutput: false` sends stdout to /dev/null — required for
    /// commands that may leave a daemon holding the pipe open.
    static func run(
        _ executable: String,
        _ arguments: [String],
        input: Data? = nil,
        environment: [String: String]? = nil,
        capturesOutput: Bool = true,
        timeout: TimeInterval = 15
    ) throws -> Result {
        _ = ignoreSIGPIPE
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        process.standardError = FileHandle.nullDevice
        let stdin = Pipe()
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin

        // Drain stdout while the process runs so a full pipe never blocks it.
        let collected = LockedData()
        let reachedEOF = DispatchSemaphore(value: 0)
        let output = Pipe()
        if capturesOutput {
            process.standardOutput = output
            output.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    reachedEOF.signal()
                } else {
                    collected.append(chunk)
                }
            }
        } else {
            process.standardOutput = FileHandle.nullDevice
        }
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        if let input {
            try? stdin.fileHandleForWriting.write(contentsOf: input)
            try? stdin.fileHandleForWriting.close()
        }
        let timedOut = finished.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            process.terminate()
            _ = finished.wait(timeout: .now() + 2)
        }
        if capturesOutput {
            // Never block on EOF: a grandchild may still hold the pipe.
            _ = reachedEOF.wait(timeout: .now() + 1)
            output.fileHandleForReading.readabilityHandler = nil
        }
        return Result(status: timedOut ? -1 : process.terminationStatus, stdout: collected.data, timedOut: timedOut)
    }
}

private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()

    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        buffer.append(chunk)
    }

    var data: Data {
        lock.lock(); defer { lock.unlock() }
        return buffer
    }
}

// MARK: - Keychain items through /usr/bin/security

enum SecretStoreError: Error, Equatable {
    case notFound
    /// The keychain is locked or would need a prompt (status 36 right after
    /// wake is common). Not the same as "absent": never act as if nobody is
    /// signed in when this happens.
    case unavailable
    case failed(Int32)
    case unreadable
}

/// Generic-password items addressed by service and account.
protocol SecretStore: Sendable {
    func read(service: String, account: String) throws -> Data
    func write(_ data: Data, service: String, account: String) throws
    func delete(service: String, account: String) throws
}

/// The login keychain through `/usr/bin/security` — the same tool, argument
/// shape, and encoding Claude Code itself uses.
///
/// Why not Security.framework: a framework write re-stamps the item's
/// partition list with the caller's code signature, which locks Claude Code
/// out of its own sign-in (and locks ad-hoc-signed Netra builds out after
/// every rebuild). Items written by `security` stay readable by `security`,
/// so neither app ever sees a prompt.
struct SecurityCommandKeychain: SecretStore {
    static let tool = "/usr/bin/security"
    /// Claude Code's own cap for a `security -i` stdin line; longer payloads
    /// go through argv exactly as Claude Code does.
    static let interactiveLineLimit = 4032
    private static let statusNotFound: Int32 = 44
    private static let statusInteractionNotAllowed: Int32 = 36

    func read(service: String, account: String) throws -> Data {
        let result = try ProcessRunner.run(Self.tool, ["find-generic-password", "-a", account, "-s", service, "-w"])
        try Self.check(result.status)
        var text = String(decoding: result.stdout, as: UTF8.self)
        if text.hasSuffix("\n") { text.removeLast() }
        return Self.decodeSecret(text)
    }

    func write(_ data: Data, service: String, account: String) throws {
        let hex = data.map { String(format: "%02x", $0) }.joined()
        let line = "add-generic-password -U -a \"\(account)\" -s \"\(service)\" -X \"\(hex)\"\n"
        let result: ProcessRunner.Result
        if line.utf8.count <= Self.interactiveLineLimit {
            result = try ProcessRunner.run(Self.tool, ["-i"], input: Data(line.utf8))
        } else {
            result = try ProcessRunner.run(
                Self.tool, ["add-generic-password", "-U", "-a", account, "-s", service, "-X", hex]
            )
        }
        try Self.check(result.status)
        // `security -i` reports some failures only on stderr; trust a read-back.
        guard (try? read(service: service, account: account)) == data else {
            throw SecretStoreError.failed(result.status)
        }
    }

    func delete(service: String, account: String) throws {
        let result = try ProcessRunner.run(Self.tool, ["delete-generic-password", "-a", account, "-s", service])
        if result.status == Self.statusNotFound { return }
        try Self.check(result.status)
    }

    private static func check(_ status: Int32) throws {
        switch status {
        case 0: return
        case statusNotFound: throw SecretStoreError.notFound
        case statusInteractionNotAllowed: throw SecretStoreError.unavailable
        default: throw SecretStoreError.failed(status)
        }
    }

    /// `security -w` prints a printable payload verbatim and anything else as
    /// hex. JSON payloads are printable; accept hex for anything that isn't.
    static func decodeSecret(_ text: String) -> Data {
        let isHex = !text.isEmpty && text.count.isMultiple(of: 2) && text.allSatisfy(\.isHexDigit)
        if isHex, !text.hasPrefix("{") {
            var bytes = Data(capacity: text.count / 2)
            var index = text.startIndex
            while index < text.endIndex {
                let next = text.index(index, offsetBy: 2)
                guard let byte = UInt8(text[index..<next], radix: 16) else { return Data(text.utf8) }
                bytes.append(byte)
                index = next
            }
            return bytes
        }
        return Data(text.utf8)
    }
}

/// An in-memory keychain for tests and previews.
final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    /// When set, every call fails with this error (e.g. a locked keychain).
    var failure: SecretStoreError?

    init(_ items: [String: Data] = [:]) {
        self.items = items
    }

    static func key(_ service: String, _ account: String) -> String { "\(service)\u{1F}\(account)" }

    func read(service: String, account: String) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        if let failure { throw failure }
        guard let data = items[Self.key(service, account)] else { throw SecretStoreError.notFound }
        return data
    }

    func write(_ data: Data, service: String, account: String) throws {
        lock.lock(); defer { lock.unlock() }
        if let failure { throw failure }
        items[Self.key(service, account)] = data
    }

    func delete(service: String, account: String) throws {
        lock.lock(); defer { lock.unlock() }
        if let failure { throw failure }
        items[Self.key(service, account)] = nil
    }

    func value(service: String, account: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return items[Self.key(service, account)]
    }
}

// MARK: - The vault

/// One parked sign-in, exactly as each CLI keeps it.
struct VaultEntry: Codable, Sendable, Equatable {
    var provider: AccountProvider
    var capturedAt: Date
    /// Claude: the account-owned fields of Claude Code's Keychain item
    /// (`claudeAiOauth`, …) as a JSON object.
    var claudeCredentials: Data?
    /// Claude: the `oauthAccount` object from `~/.claude.json`.
    var claudeProfile: Data?
    /// Codex: the exact bytes of `auth.json`.
    var codexAuth: Data?
}

/// Sign-ins of managed accounts, stored only in the login keychain under
/// Netra's own service — one item per account, never on disk.
struct AccountVault: Sendable {
    static let service = "Netra Account Vault"
    let secrets: SecretStore

    init(secrets: SecretStore = SecurityCommandKeychain()) {
        self.secrets = secrets
    }

    func load(_ id: UUID) throws -> VaultEntry {
        let data = try secrets.read(service: Self.service, account: id.uuidString)
        guard let entry = try? JSONDecoder().decode(VaultEntry.self, from: data) else {
            throw SecretStoreError.unreadable
        }
        return entry
    }

    func save(_ entry: VaultEntry, for id: UUID) throws {
        let data = try JSONEncoder().encode(entry)
        try secrets.write(data, service: Self.service, account: id.uuidString)
    }

    func remove(_ id: UUID) {
        try? secrets.delete(service: Self.service, account: id.uuidString)
    }
}
