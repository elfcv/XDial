import SwiftUI

@main
struct XDialIOSApp: App {
    init() {
        // 快捷指令和控制中心会在无窗口时后台启动 App，宿主必须在 App 初始化时注册。
        XDialIntentHost.current = MobileIntentHost(app: MobileAppRuntime.state)
    }

    var body: some Scene {
        WindowGroup {
            MobileRootView()
        }
    }
}

enum MobileTab: Hashable {
    case home
    case scenarios
    case configuration
    case settings
}

struct MobileRootView: View {
    @StateObject private var app: AppState
    @State private var selectedTab: MobileTab = .home

    init() {
        _app = StateObject(wrappedValue: MobileAppRuntime.state)
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            HomeView(selectedTab: $selectedTab)
                .tabItem { Label(app.tr("首页", "Home"), systemImage: "power") }
                .tag(MobileTab.home)

            ScenariosView()
                .tabItem {
                    Label(
                        app.tr("场景", "Scenarios"),
                        systemImage: "square.grid.2x2"
                    )
                }
                .tag(MobileTab.scenarios)

            ConfigurationView()
                .tabItem { Label(app.tr("配置", "Config"), systemImage: "slider.horizontal.3") }
                .tag(MobileTab.configuration)

            MobileSettingsView()
                .tabItem { Label(app.tr("设置", "Settings"), systemImage: "gearshape") }
                .tag(MobileTab.settings)
        }
        .environmentObject(app)
        #if targetEnvironment(simulator)
        .onAppear { app.seedDemoDataForSimulator() }
        #endif
    }
}
