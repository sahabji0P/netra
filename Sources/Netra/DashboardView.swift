import Observation
import SwiftUI

/// Sidebar destinations, grouped into what you look at and what you tune.
enum DashboardSection: String, CaseIterable, Identifiable {
    case usage
    case subscriptions
    case menuBar
    case limits
    case providers
    case accounts
    case notifications
    case general

    var id: Self { self }

    static let overview: [DashboardSection] = [.usage, .subscriptions]
    static let settings: [DashboardSection] = [.menuBar, .limits, .providers, .accounts, .notifications, .general]

    var title: String {
        switch self {
        case .usage: "Usage"
        case .subscriptions: "Subscriptions"
        case .menuBar: "Menu Bar & Popover"
        case .limits: "Limits"
        case .providers: "Providers"
        case .accounts: "Accounts"
        case .notifications: "Notifications"
        case .general: "General"
        }
    }

    var subtitle: String {
        switch self {
        case .usage: "Coding-agent activity and API-equivalent cost"
        case .subscriptions: "Plan limits, resets, and pace for every provider"
        case .menuBar: "What the menu-bar label and popover show"
        case .limits: "How limit bars, resets, and pace read"
        case .providers: "Which agents appear, and optional account connections"
        case .accounts: "Switch Claude Code and Codex between your accounts"
        case .notifications: "When Netra should get your attention"
        case .general: "Startup and small delights"
        }
    }

    var symbol: String {
        switch self {
        case .usage: "chart.bar.xaxis"
        case .subscriptions: "gauge.with.dots.needle.50percent"
        case .menuBar: "menubar.rectangle"
        case .limits: "slider.horizontal.below.rectangle"
        case .providers: "square.stack.3d.up"
        case .accounts: "person.2.fill"
        case .notifications: "bell.badge"
        case .general: "gearshape"
        }
    }

    var tint: Color {
        switch self {
        case .usage: .blue
        case .subscriptions: .orange
        case .menuBar: .indigo
        case .limits: .teal
        case .providers: .purple
        case .accounts: .green
        case .notifications: .red
        case .general: .gray
        }
    }
}

@MainActor
@Observable
final class DashboardNavigation {
    var selection: DashboardSection

    init(selection: DashboardSection = .usage) {
        self.selection = selection
    }
}

struct DashboardView: View {
    @Bindable var store: UsageStore
    @Bindable var preferences: AppPreferences
    @Bindable var navigation: DashboardNavigation
    var accounts: AccountStore? = nil

    var body: some View {
        NavigationSplitView {
            List(selection: $navigation.selection) {
                Section("Overview") {
                    ForEach(DashboardSection.overview) { sidebarRow($0) }
                }
                Section("Settings") {
                    ForEach(DashboardSection.settings) { sidebarRow($0) }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 230)
        } detail: {
            switch navigation.selection {
            case .usage:
                DashboardUsageView(store: store)
            case .subscriptions:
                DashboardSubscriptionsView(
                    store: store, preferences: preferences, navigation: navigation, accounts: accounts
                )
            case .accounts:
                if let accounts {
                    DashboardAccountsView(accounts: accounts, store: store, preferences: preferences)
                }
            default:
                DashboardSettingsView(section: navigation.selection, preferences: preferences, store: store)
            }
        }
        .frame(minWidth: 940, minHeight: 660)
    }

    private func sidebarRow(_ section: DashboardSection) -> some View {
        Label {
            Text(section.title)
        } icon: {
            IconTile(symbol: section.symbol, tint: section.tint, size: 20)
        }
        .tag(section)
    }
}

// MARK: - Shared dashboard components

/// A rounded, colored SF Symbol badge, like System Settings' sidebar icons.
struct IconTile: View {
    var symbol: String
    var tint: Color
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
    }
}

/// Large page title with its icon, used at the top of every dashboard page.
struct DashboardPageHeader<Accessory: View>: View {
    var section: DashboardSection
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            IconTile(symbol: section.symbol, tint: section.tint, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(section.title)
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                Text(section.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            accessory
        }
    }
}

extension DashboardPageHeader where Accessory == EmptyView {
    init(section: DashboardSection) {
        self.init(section: section) { EmptyView() }
    }
}

struct DashboardPanel<Content: View>: View {
    var title: String
    var detail: String?
    var symbol: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            content
        }
        .padding(18)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.separator.opacity(0.55), lineWidth: 0.5)
        }
    }
}

/// One settings line: title and explanation on the left, control on the right.
struct SettingsRow<Control: View>: View {
    var title: String
    var detail: String?
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control
        }
    }
}

extension SettingsRow where Control == SettingsSwitch {
    init(_ title: String, detail: String? = nil, isOn: Binding<Bool>) {
        self.init(title: title, detail: detail) { SettingsSwitch(title: title, isOn: isOn) }
    }
}

struct SettingsSwitch: View {
    var title: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(title, isOn: $isOn)
            .toggleStyle(.switch)
            .labelsHidden()
    }
}

/// Scrolling page container shared by every settings and overview page.
struct DashboardPage<Content: View>: View {
    var maxWidth: CGFloat = 820
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                content
            }
            .padding(24)
            .frame(maxWidth: maxWidth)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
