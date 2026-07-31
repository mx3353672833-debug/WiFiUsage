import SwiftUI

@main
struct WiFiUsageApp: App {
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("WiFi 使用情况", id: "main") {
            RootView()
                .environment(model)
                .preferredColorScheme(.dark)
                .frame(minWidth: 920, minHeight: 640)
                .onAppear { appDelegate.model = model }
        }
        .defaultSize(width: 1120, height: 760)

        MenuBarExtra {
            MenuBarUsageView()
                .environment(model)
                .preferredColorScheme(.dark)
        } label: {
            Label(model.totalUsage.totalBytes.formattedByteCount, systemImage: "chart.bar.xaxis")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(model)
                .preferredColorScheme(.dark)
                .frame(width: 560, height: 430)
        }
    }
}
