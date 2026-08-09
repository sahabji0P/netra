import Observation
import SwiftUI

enum DashboardSection: String, CaseIterable, Identifiable {
    case usage
    case settings

    var id: Self { self }

    var title: String {
        switch self {
        case .usage: "Usage"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .usage: "chart.xyaxis.line"
        case .settings: "slider.horizontal.3"
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

    var body: some View {
        NavigationSplitView {
            List(DashboardSection.allCases, selection: $navigation.selection) { section in
                Label(section.title, systemImage: section.symbol)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 152, ideal: 168, max: 190)
        } detail: {
            switch navigation.selection {
            case .usage:
                DashboardUsageView(store: store)
            case .settings:
                DashboardSettingsView(preferences: preferences)
            }
        }
        .frame(minWidth: 900, minHeight: 650)
    }
}

struct DashboardPanel<Content: View>: View {
    var title: String
    var detail: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
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
