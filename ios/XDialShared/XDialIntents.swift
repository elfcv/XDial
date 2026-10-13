import AppIntents
import Foundation

// MARK: - Host
//
// 本文件同时编译进主 App 与控制中心扩展：控制必须在扩展里引用 intent 类型，
// 但连接需要主 App 内的配置编译、凭据和数据链路验收。主 App 启动时注册宿主；
// 扩展进程里宿主为空，intent 只会报错而不会绕开 AppState 直接操作系统 VPN。

@MainActor
protocol XDialIntentHosting: AnyObject {
    func connect() async throws
    func disconnect() async throws
    func activateScenario(id: String) async throws
}

@MainActor
enum XDialIntentHost {
    static var current: (any XDialIntentHosting)?

    static func require() throws -> any XDialIntentHosting {
        guard let current else { throw XDialIntentError.appUnavailable }
        return current
    }
}

enum XDialIntentError: Error, CustomLocalizedStringResourceConvertible {
    case appUnavailable
    case failed(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .appUnavailable:
            return "XDial 未能在后台启动，请打开 App 后重试。"
        case .failed(let message):
            return "\(message)"
        }
    }
}

// MARK: - Scenario entity

struct ScenarioEntity: AppEntity, Identifiable, Sendable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "场景"
    static let defaultQuery = ScenarioEntityQuery()

    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct ScenarioEntityQuery: EntityQuery {
    func entities(for identifiers: [ScenarioEntity.ID]) async throws -> [ScenarioEntity] {
        let wanted = Set(identifiers)
        return Self.all().filter { wanted.contains($0.id) }
    }

    func suggestedEntities() async throws -> [ScenarioEntity] {
        Self.all()
    }

    private static func all() -> [ScenarioEntity] {
        (XDialWidgetSnapshot.load()?.scenarios ?? []).map {
            ScenarioEntity(id: $0.id, name: $0.name)
        }
    }
}

// MARK: - Intents

struct ConnectXDialIntent: AppIntent {
    static let title: LocalizedStringResource = "连接 XDial"
    static let description = IntentDescription("按当前场景建立 XDial 连接。")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await XDialIntentHost.require().connect()
        return .result(dialog: "XDial 已连接")
    }
}

struct DisconnectXDialIntent: AppIntent {
    static let title: LocalizedStringResource = "断开 XDial"
    static let description = IntentDescription("断开当前 XDial 连接。")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await XDialIntentHost.require().disconnect()
        return .result(dialog: "XDial 已断开")
    }
}

struct SwitchXDialScenarioIntent: AppIntent {
    static let title: LocalizedStringResource = "切换 XDial 场景"
    static let description = IntentDescription("把 XDial 的当前场景切换为指定场景。连接中时需要先断开。")

    @Parameter(title: "场景")
    var scenario: ScenarioEntity

    static var parameterSummary: some ParameterSummary {
        Summary("把 XDial 切换到 \(\.$scenario)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await XDialIntentHost.require().activateScenario(id: scenario.id)
        return .result(dialog: "已切换到 \(scenario.name)")
    }
}

/// 控制中心开关的动作。LiveActivityIntent 让系统在主 App 进程（必要时后台启动）
/// 执行 perform，从而复用 AppState 的连接事务，而不是在扩展进程里执行。
@available(iOS 18.0, *)
struct SetXDialConnectionIntent: SetValueIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "XDial 连接"
    static let isDiscoverable = false

    @Parameter(title: "已连接")
    var value: Bool

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        let host = try XDialIntentHost.require()
        if value {
            try await host.connect()
        } else {
            try await host.disconnect()
        }
        return .result()
    }
}
