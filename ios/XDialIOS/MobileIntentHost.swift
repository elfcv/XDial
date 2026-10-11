import AppIntents
import Combine
import Foundation
import WidgetKit

/// 主 App 进程内唯一的 AppState。快捷指令和控制中心可能在没有任何窗口场景时
/// 后台启动 App，因此状态不能只挂在视图的 StateObject 上。
@MainActor
enum MobileAppRuntime {
    static let state: AppState = makeState()

    private static func makeState() -> AppState {
        #if targetEnvironment(simulator)
        let engine = FakeTunnelEngine()
        let manager = FakeTunnelManager(engine: engine)
        engine.retain(manager: manager)
        let arguments = ProcessInfo.processInfo.arguments
        let shouldResetUITesting = arguments.contains("-XDialUITestingReset")
        let isUITesting = shouldResetUITesting || arguments.contains("-XDialUITesting")
        let persistence: AppPersistenceContext = isUITesting ? .uiTesting : .production
        if shouldResetUITesting { _ = persistence.clearForTesting() }
        return AppState(
            engine: engine,
            tunnelManager: manager,
            tailscaleSetupRuntime: FakeTailscaleSetupRuntime(),
            persistence: persistence
        )
        #else
        let engine = GoEngine.shared
        let manager = TunnelManager(engine: engine)
        return AppState(
            engine: engine,
            tunnelManager: manager,
            tailscaleSetupRuntime: LocalTailscaleSetupRuntime()
        )
        #endif
    }
}

/// 把快捷指令 / 控制中心动作接到 AppState 的既有事务上，并发布扩展可读的快照。
@MainActor
final class MobileIntentHost: XDialIntentHosting {
    private let app: AppState
    private var subscriptions: Set<AnyCancellable> = []
    private var lastSnapshot: XDialWidgetSnapshot?

    init(app: AppState) {
        self.app = app
        app.$profile
            .combineLatest(app.engine.statusPublisher)
            .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
            .sink { [weak self] profile, status in
                self?.publishSnapshot(profile: profile, status: status)
            }
            .store(in: &subscriptions)
    }

    // MARK: XDialIntentHosting

    func connect() async throws {
        await app.refreshTunnelProfileStatusAndWait()
        await waitWhileBusy(timeout: .seconds(10))
        if app.hasFormalTunnel { return }
        guard app.tailscaleSetupLineID == nil else {
            throw XDialIntentError.failed(app.tr(
                "正在设置 Tailscale 线路，请在 App 内完成后再连接。",
                "A Tailscale line setup is in progress. Finish it in the app first."
            ))
        }
        guard app.canConnect else {
            let issues = app.activeConfigurationIssues.prefix(3).joined(separator: app.tr("；", "; "))
            throw XDialIntentError.failed(issues.isEmpty
                ? app.tr("当前无法连接，请打开 XDial 查看。", "XDial cannot connect right now. Open the app for details.")
                : issues)
        }

        app.connect()
        // connect() 在同一 MainActor 回合里进入 connecting；仍为 disconnected 表示
        // 保存或校验已同步失败，错误已写入 lastError。
        if app.engine.status == "disconnected" { throw connectionFailure() }

        let settled = await waitForStatus(timeout: .seconds(25)) {
            ["connected", "action-required", "disconnected"].contains($0)
        }
        if settled == "disconnected" { throw connectionFailure() }
        // 超时仍在连接或验收中时不判失败：系统开关已显示进行中，结果由主 App 继续收敛。
    }

    func disconnect() async throws {
        await app.refreshTunnelProfileStatusAndWait()
        if app.hasFormalTunnel || app.engine.status == "connecting" || app.engine.status == "reconnecting" {
            app.disconnect()
            _ = await waitForStatus(timeout: .seconds(10)) { $0 == "disconnected" }
        } else if app.tailscaleSetupLineID != nil {
            await withCheckedContinuation { continuation in
                app.finishTailscaleSetup { continuation.resume() }
            }
        }
    }

    func activateScenario(id: String) async throws {
        guard let scenario = app.profile.scenarios.first(where: { $0.id == id }) else {
            throw XDialIntentError.failed(app.tr("场景已不存在。", "The scenario no longer exists."))
        }
        if app.profile.activeScenarioID == id { return }
        await app.refreshTunnelProfileStatusAndWait()
        guard app.canMutateConfiguration else {
            throw XDialIntentError.failed(app.tr(
                "XDial 连接中，请先断开再切换到「\(scenario.name)」。",
                "XDial is connected. Disconnect before switching to \"\(scenario.name)\"."
            ))
        }
        app.profile.activeScenarioID = id
        guard app.save() else {
            throw XDialIntentError.failed(app.tr("场景切换未能保存。", "The scenario change could not be saved."))
        }
    }

    // MARK: Helpers

    private func connectionFailure() -> XDialIntentError {
        .failed(app.engine.lastError.map(userFacingConnectionText)
            ?? app.tr("连接失败，请打开 XDial 查看。", "Connection failed. Open XDial for details."))
    }

    private func waitWhileBusy(timeout: Duration) async {
        _ = await waitForStatus(timeout: timeout) { _ in !self.app.isBusy }
    }

    /// 轮询 MainActor 上的引擎状态直到满足条件或超时，返回最后观察到的状态。
    private func waitForStatus(
        timeout: Duration,
        until isSettled: (String) -> Bool
    ) async -> String {
        let deadline = ContinuousClock.now + timeout
        while !isSettled(app.engine.status), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(200))
        }
        return app.engine.status
    }

    private func publishSnapshot(profile: Profile, status: String) {
        let snapshot = XDialWidgetSnapshot(
            scenarios: profile.scenarios.map { .init(id: $0.id, name: $0.name) },
            activeScenarioID: profile.activeScenarioID,
            status: status
        )
        guard snapshot != lastSnapshot else { return }
        let scenariosChanged = snapshot.scenarios != lastSnapshot?.scenarios
        lastSnapshot = snapshot
        snapshot.save()
        if #available(iOS 18.0, *) {
            ControlCenter.shared.reloadControls(ofKind: XDialWidgetSnapshot.connectionControlKind)
        }
        if scenariosChanged {
            XDialShortcuts.updateAppShortcutParameters()
        }
    }
}

struct XDialShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ConnectXDialIntent(),
            phrases: [
                "连接 \(.applicationName)",
                "Connect \(.applicationName)",
            ],
            shortTitle: "连接",
            systemImageName: "power"
        )
        AppShortcut(
            intent: DisconnectXDialIntent(),
            phrases: [
                "断开 \(.applicationName)",
                "Disconnect \(.applicationName)",
            ],
            shortTitle: "断开",
            systemImageName: "stop.circle"
        )
        AppShortcut(
            intent: SwitchXDialScenarioIntent(),
            phrases: [
                "把 \(.applicationName) 切换到 \(\.$scenario)",
                "Switch \(.applicationName) to \(\.$scenario)",
            ],
            shortTitle: "切换场景",
            systemImageName: "square.grid.2x2"
        )
    }
}
