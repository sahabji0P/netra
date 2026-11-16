import Foundation

/// A JSON value from a command's `args`, decoded strictly: `true` is never a
/// number and `1` is never a boolean.
enum DashboardJSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([DashboardJSONValue])
    case object([String: DashboardJSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([DashboardJSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: DashboardJSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

/// One validated change to a preference the dashboard may set.
enum DashboardPreferenceChange: Equatable, Sendable {
    case menuBarIcon(MenuBarIconKind)
    case menuBarItems([MenuBarItem])
    case menuBarStyle(MenuBarStyle)
    case menuBarTint(MenuBarTint)
    case menuBarLimitSource(String)
    case menuBarCompact(Bool)
    case showsLimits(Bool)
    case showsProviderBreakdown(Bool)
    case showsActivityChart(Bool)
    case showsKeepAwake(Bool)
    case hiddenMenuProviders(Set<String>)
    case defaultPeriod(PeriodTab)
    case barsShowRemaining(Bool)
    case resetTimeStyle(ResetTimeStyle)
    case showsPace(Bool)
    case limitProviderOrder([String])
    case claudeQuotaEnabled(Bool)
    case cursorUsageEnabled(Bool)
    case confettiOnReset(Bool)
    case notchIslandEnabled(Bool)
    case dailyTokenAlertEnabled(Bool)
    case dailyTokenAlertThreshold(Int)
    case providerLimitAlertEnabled(Bool)
    case providerLimitAlertThreshold(Double)
    case websitePublishEnabled(Bool)
    case websiteEndpoint(String)
}

/// A command from the dashboard's `commands/` folder, decoded and validated.
/// Pure: deciding what a file asks for is separate from doing it.
enum DashboardCommand: Equatable, Sendable {
    case preferenceSet(DashboardPreferenceChange)
    case limitsMove(provider: String, offset: Int)
    case providerSetVisible(provider: String, visible: Bool)
    case refresh
    case claudeAuthorizeKeychain
    case launchAtLoginSet(Bool)
    case notificationsRequest
    case notificationsOpenSettings
    case accountStartManaging(AccountProvider)
    case accountSwitch(UUID)
    case accountBeginSignIn(AccountProvider)
    case accountCancelSignIn
    case accountRemove(UUID)
    case accountRename(UUID)
    case accountDismissNotice
    case historyExport(URL)
    case historyImport(URL)
    case websitePromptToken
    case websitePromptEndpoint
    case websiteClearToken
    case websitePublishNow

    /// Why a command file was refused, in words for the result message.
    struct Failure: Error, Equatable, Sendable {
        var message: String
    }

    /// A parsed file: its id and command name (as far as they could be read)
    /// and either the command or the reason it was refused.
    struct Request: Equatable, Sendable {
        var id: String
        var name: String
        var command: Result<DashboardCommand, Failure>
    }

    private struct Envelope: Decodable {
        var id: String
        var command: String
        var at: Date?
        var args: [String: DashboardJSONValue]?
    }

    static let maxPathLength = 4096
    static let maxEndpointLength = 2048

    /// Decodes one command file. `fallbackID` (the file name) stands in when
    /// the file is too broken to carry its own id. `dataDirectory` is
    /// Netra's own folder, which an export must not write into.
    static func parse(_ data: Data, fallbackID: String, dataDirectory: URL) -> Request {
        guard let envelope = try? DashboardJSON.decoder().decode(Envelope.self, from: data) else {
            return Request(id: fallbackID, name: "unknown",
                           command: .failure(Failure(message: "The command file couldn't be read.")))
        }
        let args = envelope.args ?? [:]
        return Request(
            id: envelope.id, name: envelope.command,
            command: Result { try decode(envelope.command, args: args, dataDirectory: dataDirectory) }
                .mapError { $0 as? Failure ?? Failure(message: "\($0)") }
        )
    }

    private static func decode(
        _ name: String, args: [String: DashboardJSONValue], dataDirectory: URL
    ) throws -> DashboardCommand {
        switch name {
        case "preference.set":
            return .preferenceSet(try preference(key: string(args, "key"), value: args["value"]))
        case "limits.move":
            let provider = try string(args, "provider")
            guard AppPreferences.limitProviders.contains(provider) else {
                throw Failure(message: "Unknown limit provider \"\(provider)\".")
            }
            let offset = try integer(args, "offset")
            guard offset == -1 || offset == 1 else { throw Failure(message: "offset must be -1 or 1.") }
            return .limitsMove(provider: provider, offset: offset)
        case "provider.setVisible":
            let provider = try string(args, "provider").lowercased()
            guard !provider.isEmpty, provider.count <= 64 else { throw Failure(message: "provider is not a provider name.") }
            return .providerSetVisible(provider: provider, visible: try bool(args, "visible"))
        case "refresh": return .refresh
        case "claude.authorizeKeychain": return .claudeAuthorizeKeychain
        case "launchAtLogin.set": return .launchAtLoginSet(try bool(args, "enabled"))
        case "notifications.request": return .notificationsRequest
        case "notifications.openSettings": return .notificationsOpenSettings
        case "account.startManaging": return .accountStartManaging(try provider(args))
        case "account.switch": return .accountSwitch(try accountID(args))
        case "account.beginSignIn": return .accountBeginSignIn(try provider(args))
        case "account.cancelSignIn": return .accountCancelSignIn
        case "account.remove": return .accountRemove(try accountID(args))
        case "account.rename": return .accountRename(try accountID(args))
        case "account.dismissNotice": return .accountDismissNotice
        case "history.export":
            let url = try path(args)
            let data = dataDirectory.standardizedFileURL.resolvingSymlinksInPath().path
            let target = url.deletingLastPathComponent().resolvingSymlinksInPath().path
            if target == data || target.hasPrefix(data + "/") {
                throw Failure(message: "Choose a location outside Netra's own data folder.")
            }
            return .historyExport(url)
        case "history.import": return .historyImport(try path(args))
        case "website.promptToken": return .websitePromptToken
        case "website.promptEndpoint": return .websitePromptEndpoint
        case "website.clearToken": return .websiteClearToken
        case "website.publishNow": return .websitePublishNow
        case "popover.open": throw Failure(message: "Opening the popover isn't supported yet.")
        default: throw Failure(message: "Unknown command \"\(name)\".")
        }
    }

    // MARK: Preferences

    private static func preference(key: String, value: DashboardJSONValue?) throws -> DashboardPreferenceChange {
        guard let value else { throw Failure(message: "Missing value for \(key).") }
        func flag() throws -> Bool {
            guard case .bool(let flag) = value else { throw Failure(message: "\(key) must be true or false.") }
            return flag
        }
        func text() throws -> String {
            guard case .string(let text) = value else { throw Failure(message: "\(key) must be a string.") }
            return text
        }
        func list() throws -> [String] {
            guard case .array(let items) = value else { throw Failure(message: "\(key) must be a list of strings.") }
            return try items.map {
                guard case .string(let item) = $0 else { throw Failure(message: "\(key) must be a list of strings.") }
                return item
            }
        }
        func choice<T: RawRepresentable>(_ type: T.Type) throws -> T where T.RawValue == String {
            let raw = try text()
            guard let value = T(rawValue: raw) else { throw Failure(message: "\"\(raw)\" isn't a valid \(key).") }
            return value
        }
        func number(in range: ClosedRange<Double>) throws -> Double {
            guard case .number(let number) = value, number.isFinite else { throw Failure(message: "\(key) must be a number.") }
            guard range.contains(number) else {
                throw Failure(message: "\(key) must be between \(Int(range.lowerBound)) and \(Int(range.upperBound)).")
            }
            return number
        }

        switch key {
        case "menuBarIcon": return .menuBarIcon(try choice(MenuBarIconKind.self))
        case "menuBarItems":
            let raw = try list()
            guard Set(raw).count == raw.count else { throw Failure(message: "menuBarItems lists an item twice.") }
            return .menuBarItems(try raw.map {
                guard let item = MenuBarItem(rawValue: $0) else { throw Failure(message: "\"\($0)\" isn't a menu-bar item.") }
                return item
            })
        case "menuBarStyle": return .menuBarStyle(try choice(MenuBarStyle.self))
        case "menuBarTint": return .menuBarTint(try choice(MenuBarTint.self))
        case "menuBarLimitSource":
            let source = try text()
            guard AppPreferences.isValidLimitSource(source) else {
                throw Failure(message: "\"\(source)\" isn't a limit source.")
            }
            return .menuBarLimitSource(source)
        case "menuBarCompact": return .menuBarCompact(try flag())
        case "showsLimits": return .showsLimits(try flag())
        case "showsProviderBreakdown": return .showsProviderBreakdown(try flag())
        case "showsActivityChart": return .showsActivityChart(try flag())
        case "showsKeepAwake": return .showsKeepAwake(try flag())
        case "hiddenMenuProviders":
            let names = try list().map { $0.lowercased() }
            guard names.allSatisfy({ !$0.isEmpty && $0.count <= 64 }), names.count <= 64 else {
                throw Failure(message: "hiddenMenuProviders must hold provider names.")
            }
            return .hiddenMenuProviders(Set(names))
        case "defaultPeriod":
            let raw = try text()
            guard let tab = PeriodTab(bridgeID: raw) else { throw Failure(message: "\"\(raw)\" isn't a period.") }
            return .defaultPeriod(tab)
        case "barsShowRemaining": return .barsShowRemaining(try flag())
        case "resetTimeStyle": return .resetTimeStyle(try choice(ResetTimeStyle.self))
        case "showsPace": return .showsPace(try flag())
        case "limitProviderOrder":
            let order = try list()
            guard Set(order).count == order.count, order.allSatisfy(AppPreferences.limitProviders.contains) else {
                throw Failure(message: "limitProviderOrder must list known limit providers once each.")
            }
            return .limitProviderOrder(order)
        case "claudeQuotaEnabled": return .claudeQuotaEnabled(try flag())
        case "cursorUsageEnabled": return .cursorUsageEnabled(try flag())
        case "confettiOnReset": return .confettiOnReset(try flag())
        case "notchIslandEnabled": return .notchIslandEnabled(try flag())
        case "dailyTokenAlertEnabled": return .dailyTokenAlertEnabled(try flag())
        case "dailyTokenAlertThreshold":
            let number = try number(in: 1...1_000_000_000_000)
            guard number.rounded() == number else { throw Failure(message: "dailyTokenAlertThreshold must be a whole number.") }
            return .dailyTokenAlertThreshold(Int(number))
        case "providerLimitAlertEnabled": return .providerLimitAlertEnabled(try flag())
        case "providerLimitAlertThreshold": return .providerLimitAlertThreshold(try number(in: 1...100))
        case "websitePublishEnabled": return .websitePublishEnabled(try flag())
        case "websiteEndpoint":
            let endpoint = try text().trimmingCharacters(in: .whitespaces)
            guard endpoint.count <= maxEndpointLength, !endpoint.contains(where: \.isNewline) else {
                throw Failure(message: "websiteEndpoint isn't a usable address.")
            }
            return .websiteEndpoint(endpoint)
        default:
            throw Failure(message: "Unknown preference \"\(key)\".")
        }
    }

    // MARK: Argument readers

    private static func string(_ args: [String: DashboardJSONValue], _ name: String) throws -> String {
        guard case .string(let value) = args[name] else { throw Failure(message: "Missing \(name).") }
        return value
    }

    private static func bool(_ args: [String: DashboardJSONValue], _ name: String) throws -> Bool {
        guard case .bool(let value) = args[name] else { throw Failure(message: "\(name) must be true or false.") }
        return value
    }

    private static func integer(_ args: [String: DashboardJSONValue], _ name: String) throws -> Int {
        guard case .number(let value) = args[name], value.rounded() == value, abs(value) < 1e9 else {
            throw Failure(message: "\(name) must be a whole number.")
        }
        return Int(value)
    }

    private static func provider(_ args: [String: DashboardJSONValue]) throws -> AccountProvider {
        let raw = try string(args, "provider")
        guard let provider = AccountProvider(rawValue: raw) else {
            throw Failure(message: "\"\(raw)\" has no switchable accounts.")
        }
        return provider
    }

    private static func accountID(_ args: [String: DashboardJSONValue]) throws -> UUID {
        let raw = try string(args, "id")
        guard let id = UUID(uuidString: raw) else { throw Failure(message: "\"\(raw)\" isn't an account id.") }
        return id
    }

    private static func path(_ args: [String: DashboardJSONValue]) throws -> URL {
        let raw = try string(args, "path")
        let expanded = (raw as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/"), expanded.count <= maxPathLength, !expanded.contains("\0") else {
            throw Failure(message: "path must be an absolute file path.")
        }
        return URL(fileURLWithPath: expanded).standardizedFileURL
    }
}

/// Which files in `commands/` to run, which to drop, and in what order.
enum DashboardInbox {
    /// A command older than this is dropped: one written while Netra was not
    /// running must not fire later.
    static let maxAge: TimeInterval = 60

    struct Entry: Equatable, Sendable {
        var url: URL
        var modified: Date

        /// The command id the dashboard put in the file name.
        var fallbackID: String { url.deletingPathExtension().lastPathComponent }
    }

    /// Finished files only (`*.json`, never the `.tmp` being written),
    /// oldest first, split into those to run and those that expired.
    static func plan(_ entries: [Entry], now: Date) -> (run: [Entry], expired: [Entry]) {
        let ready = entries
            .filter { $0.url.pathExtension == "json" }
            .sorted { ($0.modified, $0.url.lastPathComponent) < ($1.modified, $1.url.lastPathComponent) }
        let expired = ready.filter { now.timeIntervalSince($0.modified) > maxAge }
        return (ready.filter { now.timeIntervalSince($0.modified) <= maxAge }, expired)
    }

    /// Lists, reads, and deletes the waiting commands (deleted before they
    /// run, so a crash cannot replay one). Blocking file work: call off the
    /// main actor.
    static func drain(directory: URL, dataDirectory: URL, now: Date = .now) -> (requests: [DashboardCommand.Request], expired: [String]) {
        let manager = FileManager.default
        let urls = (try? manager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]
        )) ?? []
        let entries = urls.compactMap { url -> Entry? in
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { return nil }
            return Entry(url: url, modified: values?.contentModificationDate ?? now)
        }
        let (run, expired) = plan(entries, now: now)
        for entry in expired { try? manager.removeItem(at: entry.url) }
        var requests: [DashboardCommand.Request] = []
        for entry in run {
            let data = try? Data(contentsOf: entry.url)
            try? manager.removeItem(at: entry.url)
            requests.append(DashboardCommand.parse(data ?? Data(), fallbackID: entry.fallbackID, dataDirectory: dataDirectory))
        }
        return (requests, expired.map(\.fallbackID))
    }
}
