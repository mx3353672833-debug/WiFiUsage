import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(AppSection.allCases, selection: $model.selection) { section in
                Label(section.rawValue, systemImage: section.symbol)
                    .tag(section)
                    .padding(.vertical, 3)
            }
            .navigationTitle("流量账本")
            .scrollContentBackground(.hidden)
            .background(Color.usageSidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 240)
        } detail: {
            Group {
                switch model.selection ?? .overview {
                case .overview: DashboardView()
                case .wifi: WiFiNetworksView()
                case .applications: ApplicationsView()
                case .plans: PlansView()
                case .settings: SettingsView()
                }
            }
            .background(Color.usageBackground)
        }
        .tint(Color.usageDownload)
    }
}
