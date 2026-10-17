import Foundation
import Network

/// 把宿主掌握的电源生命周期与 Underlay 可用性告诉 Provider（合同见
/// `ProviderLineRecoveryConditions`）。宿主不替 Provider 做恢复决定；Provider 只据此
/// 判断 Line 局部恢复能否消耗预算。休眠信号只来自 AppState 的 `willSleep` / 完整
/// `didWake`，这里不另行订阅电源通知。
///
/// 只在主线程使用。
final class LineRecoveryConditionsPublisher {
    /// 发送一份报告；completion 表示 Provider 是否确认收到。
    typealias Send = (
        ProviderLineRecoveryConditions,
        @escaping (Bool) -> Void
    ) -> Void

    private var state = LineRecoveryConditionsPublisherState(
        source: UUID().uuidString
    )
    private let monitor = NWPathMonitor()
    private var send: Send?
    private var refreshWorkItem: DispatchWorkItem?
    private var retryWorkItem: DispatchWorkItem?
    private var deliveryRetries = 0

    func start(send: @escaping Send) {
        guard self.send == nil else { return }
        self.send = send
        monitor.pathUpdateHandler = { [weak self] path in
            let usable = path.status == .satisfied
            DispatchQueue.main.async {
                self?.observeUnderlay(usable: usable)
            }
        }
        monitor.start(queue: .global(qos: .utility))
    }

    func noteSystemWillSleep() {
        if state.noteSystemWillSleep() {
            publish()
        }
    }

    func noteSystemDidWake() {
        // 重新读取当前路径，不沿用休眠前最后一次回调的结论。
        let usable = monitor.currentPath.status == .satisfied
        if state.noteSystemDidWake(underlayUsable: usable) {
            publish()
        }
    }

    private func observeUnderlay(usable: Bool) {
        if state.observeUnderlay(usable: usable) {
            publish()
        }
    }

    private func publish() {
        retryWorkItem?.cancel()
        retryWorkItem = nil
        deliveryRetries = 0
        deliver()
    }

    private func deliver() {
        guard let send else { return }
        let message = state.makeMessage()
        send(message) { [weak self] delivered in
            DispatchQueue.main.async {
                self?.finishDelivery(
                    sequence: message.sequence,
                    delivered: delivered
                )
            }
        }
        scheduleRefreshIfGated()
    }

    /// 未送达的最新报告有界重试；更新的报告已经发出时旧结果作废。
    private func finishDelivery(sequence: UInt64, delivered: Bool) {
        guard
            sequence == state.sequence,
            !delivered,
            deliveryRetries
                < LineRecoveryConditionsPublisherState.maxDeliveryRetries
        else {
            return
        }
        deliveryRetries += 1
        retryWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.retryWorkItem = nil
            self?.deliver()
        }
        retryWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now()
                + LineRecoveryConditionsPublisherState.deliveryRetryDelay,
            execute: work
        )
    }

    /// 关闭态在条件持续期间续约；`DispatchTime` 与 Provider 的租约时钟一样不计休眠。
    private func scheduleRefreshIfGated() {
        refreshWorkItem?.cancel()
        refreshWorkItem = nil
        guard state.gated else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.refreshWorkItem = nil
            self.publish()
        }
        refreshWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now()
                + LineRecoveryConditionsPublisherState.refreshInterval,
            execute: work
        )
    }
}
