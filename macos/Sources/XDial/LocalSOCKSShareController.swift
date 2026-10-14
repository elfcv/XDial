import Foundation

/// 通用设置里的连接方式与本机 SOCKS5 端口。偏好只存在 App 偏好域，不进入 Profile，
/// 也不参与运行指纹。
///
/// - 接管系统：本机 SOCKS5 是可选的附加入口，开关和端口在已连接时立即下发。
/// - 仅 SOCKS5：端口是这笔连接唯一的入口，由连接事务建立；改变方式或端口要重连，
///   当前连接继续按原入口运行。
private enum LocalSOCKSPreferenceKey {
    static let enabled = "xdial.localSOCKSShare.enabled"
    static let port = "xdial.localSOCKSShare.port"
    static let ingressMode = "xdial.connectionIngress.mode"
}

@MainActor
final class LocalSOCKSShareController: ObservableObject {
    enum Phase: Equatable {
        case off
        case waitingForConnection
        case applying
        case listening
        case failed(code: String)
        /// Provider 没有给出结果（超时、连接正在变化）。
        case unavailable
    }

    typealias Send = (
        LocalSOCKSShareRequest,
        @escaping (Result<LocalSOCKSShareResponse, Error>) -> Void
    ) -> Void

    /// 下一次完整连接使用的入口。宿主在每笔完整连接开始时读取，可在任意线程调用。
    nonisolated static func preferredIngress(defaults: UserDefaults) -> ConnectionIngress {
        guard defaults.string(forKey: LocalSOCKSPreferenceKey.ingressMode)
                == ConnectionIngress.Mode.localSOCKS.rawValue else {
            return .system
        }
        return .localSOCKS(port: UInt16(storedPort(defaults)))
    }

    nonisolated private static func storedPort(_ defaults: UserDefaults) -> Int {
        let saved = defaults.integer(forKey: LocalSOCKSPreferenceKey.port)
        return LocalSOCKSSharePort.isValid(saved) ? saved : LocalSOCKSSharePort.defaultValue
    }

    @Published var ingressMode: ConnectionIngress.Mode {
        didSet {
            guard ingressMode != oldValue else { return }
            defaults.set(ingressMode.rawValue, forKey: LocalSOCKSPreferenceKey.ingressMode)
            synchronize(force: false)
        }
    }
    /// 接管系统时是否附加本机 SOCKS5；仅 SOCKS5 方式下端口总是开启。
    @Published var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: LocalSOCKSPreferenceKey.enabled)
            synchronize(force: false)
        }
    }
    @Published private(set) var port: Int
    @Published private(set) var phase: Phase = .off
    /// 当前已提交连接的入口；未连接时为 nil。
    @Published private(set) var committedIngress: ConnectionIngress?

    private let defaults: UserDefaults
    private let send: Send
    private var transactionID: String?
    /// 本次 Provider 生命周期内是否下发过附加监听且尚未确认关闭。
    private var providerMayListen = false
    private var requestGeneration = 0

    init(defaults: UserDefaults, send: @escaping Send) {
        self.defaults = defaults
        self.send = send
        isEnabled = defaults.bool(forKey: LocalSOCKSPreferenceKey.enabled)
        port = Self.storedPort(defaults)
        ingressMode = Self.preferredIngress(defaults: defaults).mode
        phase = isEnabled || ingressMode == .localSOCKS ? .waitingForConnection : .off
    }

    var preferredIngress: ConnectionIngress {
        ingressMode == .localSOCKS ? .localSOCKS(port: UInt16(port)) : .system
    }

    /// 端口对外可用：附加开关打开，或选择了仅 SOCKS5。
    var socksRequested: Bool {
        isEnabled || ingressMode == .localSOCKS
    }

    /// 已连接，但入口设置与当前连接不同，需要重连才生效。
    var ingressRequiresReconnect: Bool {
        guard let committedIngress else { return false }
        return committedIngress != preferredIngress
    }

    /// 返回 false 表示端口不合法，保留原值。
    @discardableResult
    func setPort(_ newPort: Int) -> Bool {
        guard LocalSOCKSSharePort.isValid(newPort) else { return false }
        guard newPort != port else { return true }
        port = newPort
        defaults.set(newPort, forKey: LocalSOCKSPreferenceKey.port)
        synchronize(force: false)
        return true
    }

    func retry() {
        synchronize(force: true)
    }

    /// `transactionID` 与 `ingress` 只在事务已提交、Provider 仍承载连接时非空。
    /// 场景切换产生新的事务 ID 但沿用入口；附加监听属于 Provider，重新下发相同
    /// 端口是幂等的。
    func connectionChanged(transactionID: String?, ingress: ConnectionIngress?) {
        let committed = transactionID == nil ? nil : ingress
        guard transactionID != self.transactionID || committed != committedIngress else {
            return
        }
        self.transactionID = transactionID
        committedIngress = committed
        if transactionID == nil {
            // Provider 停止即关闭所有监听。
            providerMayListen = false
        }
        synchronize(force: false)
    }

    private func synchronize(force: Bool) {
        requestGeneration += 1
        let generation = requestGeneration
        guard let transactionID, let committedIngress else {
            phase = socksRequested ? .waitingForConnection : .off
            return
        }
        if case .localSOCKS = committedIngress.mode {
            // 端口是这笔连接的入口：提交即监听，变更只能经重连。
            phase = .listening
            return
        }
        let desired: UInt16? = socksRequested ? UInt16(port) : nil
        if desired == nil, !providerMayListen, !force {
            phase = .off
            return
        }
        if desired != nil {
            providerMayListen = true
        }
        phase = desired == nil ? .off : .applying
        send(LocalSOCKSShareRequest(transactionID: transactionID, port: desired)) { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.requestGeneration == generation else { return }
                self.apply(result, desired: desired)
            }
        }
    }

    private func apply(
        _ result: Result<LocalSOCKSShareResponse, Error>,
        desired: UInt16?
    ) {
        guard case let .success(response) = result,
              response.code == "ok",
              let status = response.status else {
            // 结果未知时不假定 Provider 状态，保留“可能在监听”，由重试或下一次变化重新下发。
            phase = .unavailable
            return
        }
        switch status.state {
        case .listening where status.port == desired:
            phase = .listening
        case .failed where status.port == desired:
            phase = .failed(code: status.code ?? "listener-failed")
        case .off where desired == nil:
            providerMayListen = false
            phase = .off
        default:
            phase = .unavailable
        }
    }
}
