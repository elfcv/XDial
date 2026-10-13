import Foundation

/// 主 App 发布给控制中心和快捷指令参数查询的只读快照。
///
/// Profile 仍只由主 App 持有；扩展进程只读这里的场景名和展示用连接状态，
/// 实际连接、断开和场景切换都回到主 App 的 AppState 事务里执行。
struct XDialWidgetSnapshot: Codable, Equatable, Sendable {
    struct ScenarioItem: Codable, Equatable, Sendable, Identifiable {
        let id: String
        let name: String
    }

    static let appGroupIdentifier = "group.com.kafeifei.xdial.ios"
    static let tunnelBundleIdentifier = "com.kafeifei.xdial.ios.tunnel"
    static let connectionControlKind = "com.kafeifei.xdial.ios.connection-toggle"
    private static let defaultsKey = "xdial.widget-snapshot.v1"

    var scenarios: [ScenarioItem]
    var activeScenarioID: String
    /// 与 TunnelEngine.status 相同的取值（connected / connecting / disconnected …）。
    var status: String

    var isConnectionActive: Bool {
        ["connected", "connecting", "checking", "action-required", "reconnecting"].contains(status)
    }

    var activeScenarioName: String? {
        scenarios.first { $0.id == activeScenarioID }?.name
    }

    static func load() -> XDialWidgetSnapshot? {
        guard let data = UserDefaults(suiteName: appGroupIdentifier)?.data(forKey: defaultsKey) else {
            return nil
        }
        return try? JSONDecoder().decode(XDialWidgetSnapshot.self, from: data)
    }

    func save() {
        guard let defaults = UserDefaults(suiteName: Self.appGroupIdentifier),
              let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
