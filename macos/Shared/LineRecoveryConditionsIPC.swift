import Foundation

/// 宿主已经掌握的电源生命周期与 Underlay 可用性。Provider 内的 Line 局部恢复只在
/// 宿主报告“已完整唤醒且 Underlay 可用”时消耗预算；系统休眠（含 Dark Wake）或
/// 没有可用 Underlay 期间，线路保持不可用（流量 REJECT、DNS SERVFAIL）并等待，
/// 不提升为完整恢复。Provider 不做自己的产品判断，只应用宿主报告的门。
///
/// 这是系统事实而非事务内容，所以不携带 transaction ID：切换中的事务换代不能让一次
/// 休眠通知被拒绝。同一宿主实例的报告按 sequence 排序；宿主重启后换新的 source。
struct ProviderLineRecoveryConditions: Codable, Equatable {
    static let kind = "line-recovery-conditions"
    static let version = 1
    /// 关闭态是租约：宿主消失时，Provider 在租约到期后恢复正常计数，不无限等待。
    /// 双方的单调时钟都不计休眠时间，宿主在条件持续期间按刷新间隔续约。
    static let sleepLease: TimeInterval = 15 * 60
    static let underlayLease: TimeInterval = 5 * 60
    static let maxLeaseMS = 15 * 60 * 1000
    static let maxSourceBytes = 64
    static let maxMessageBytes = 4096

    let kind: String
    let version: Int
    let source: String
    let sequence: UInt64
    let systemAsleep: Bool
    let underlayUsable: Bool
    /// 0 表示门打开；关闭态必须带正的租约。
    let leaseMS: Int

    enum CodingKeys: String, CodingKey {
        case kind
        case version
        case source
        case sequence
        case systemAsleep = "system_asleep"
        case underlayUsable = "underlay_usable"
        case leaseMS = "lease_ms"
    }

    init(
        source: String,
        sequence: UInt64,
        systemAsleep: Bool,
        underlayUsable: Bool
    ) {
        kind = Self.kind
        version = Self.version
        self.source = source
        self.sequence = sequence
        self.systemAsleep = systemAsleep
        self.underlayUsable = underlayUsable
        if systemAsleep {
            leaseMS = Int(Self.sleepLease * 1000)
        } else if !underlayUsable {
            leaseMS = Int(Self.underlayLease * 1000)
        } else {
            leaseMS = 0
        }
    }

    private init(copying other: Self, leaseMS: Int) {
        kind = other.kind
        version = other.version
        source = other.source
        sequence = other.sequence
        systemAsleep = other.systemAsleep
        underlayUsable = other.underlayUsable
        self.leaseMS = leaseMS
    }

    var gated: Bool { systemAsleep || !underlayUsable }

    var isValid: Bool {
        kind == Self.kind && version == Self.version
            && !source.isEmpty && source.utf8.count <= Self.maxSourceBytes
            && sequence > 0
            && (0...Self.maxLeaseMS).contains(leaseMS)
            && (gated ? leaseMS > 0 : leaseMS == 0)
    }

    /// 已经过去 `elapsed` 秒后仍然有效的同一份报告；关闭态租约到期返回 nil。
    func remaining(after elapsed: TimeInterval) -> Self? {
        guard gated else { return self }
        let remainingMS = leaseMS - Int((max(0, elapsed) * 1000).rounded(.up))
        guard remainingMS > 0 else { return nil }
        return Self(copying: self, leaseMS: remainingMS)
    }
}

struct ProviderLineRecoveryConditionsResponse: Codable, Equatable {
    let source: String
    let sequence: UInt64
    /// `ok`：已应用或已保存待应用；`stale`：同一宿主更早的报告，已忽略；
    /// `invalid-request`：报告不合法。
    let code: String

    var delivered: Bool { code == "ok" || code == "stale" }
}

/// Provider 进程内保存宿主最近一次报告并转交给当前 Libbox。引擎尚未创建时只保存，
/// 创建后按剩余租约补发。它不经过 engineQueue：启动或准备期间的休眠通知不能被排队延后。
final class LineRecoveryConditionsRelay: @unchecked Sendable {
    /// 把 Libbox 合同 JSON 交给当前引擎。
    typealias Apply = (String) -> Void

    private let lock = NSLock()
    private let uptime: () -> TimeInterval
    private var latest: ProviderLineRecoveryConditions?
    private var receivedAt: TimeInterval = 0
    private var apply: Apply?

    /// `systemUptime` 与 Libbox 的单调时钟一样不计休眠时间。
    init(
        uptime: @escaping () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        }
    ) {
        self.uptime = uptime
    }

    struct Receipt: Equatable {
        let conditions: ProviderLineRecoveryConditions
        let response: ProviderLineRecoveryConditionsResponse
    }

    /// 无法解码的消息返回 nil。
    func receive(_ data: Data) -> Receipt? {
        guard
            data.count <= ProviderLineRecoveryConditions.maxMessageBytes,
            let conditions = try? JSONDecoder().decode(
                ProviderLineRecoveryConditions.self,
                from: data
            )
        else {
            return nil
        }
        func receipt(_ code: String) -> Receipt {
            Receipt(
                conditions: conditions,
                response: ProviderLineRecoveryConditionsResponse(
                    source: conditions.source,
                    sequence: conditions.sequence,
                    code: code
                )
            )
        }
        guard conditions.isValid else { return receipt("invalid-request") }
        lock.lock()
        if let latest,
           latest.source == conditions.source,
           latest.sequence >= conditions.sequence {
            lock.unlock()
            return receipt("stale")
        }
        latest = conditions
        receivedAt = uptime()
        let apply = apply
        lock.unlock()
        if let apply, let json = Self.libboxJSON(conditions) {
            apply(json)
        }
        return receipt("ok")
    }

    /// 新引擎接管后续报告，并立即取得仍在租约内的最近一次报告。
    func attach(_ apply: @escaping Apply) {
        lock.lock()
        self.apply = apply
        let pending = latest?.remaining(after: uptime() - receivedAt)
        lock.unlock()
        if let pending, let json = Self.libboxJSON(pending) {
            apply(json)
        }
    }

    func detach() {
        lock.lock()
        apply = nil
        lock.unlock()
    }

    static func libboxJSON(
        _ conditions: ProviderLineRecoveryConditions
    ) -> String? {
        guard let data = try? JSONEncoder().encode(conditions) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}

/// 宿主侧的报告状态。只用 macOS 已经裁决的事实：完整唤醒 / 即将休眠，以及宿主
/// NWPath 是否 satisfied；不识别接口或网络产品。只有 Provider 可见的条件变化才需要
/// 立即发送，关闭态由发布者按刷新间隔续约。
struct LineRecoveryConditionsPublisherState: Equatable {
    static let refreshInterval: TimeInterval = 60
    static let deliveryRetryDelay: TimeInterval = 5
    static let maxDeliveryRetries = 3

    let source: String
    private(set) var sequence: UInt64 = 0
    private(set) var systemAsleep = false
    private(set) var underlayUsable = true
    private(set) var observedUnderlay = false

    init(source: String) {
        self.source = source
    }

    var gated: Bool { systemAsleep || !underlayUsable }

    /// 返回 true 表示需要立即发送当前条件。
    mutating func noteSystemWillSleep() -> Bool {
        guard !systemAsleep else { return false }
        systemAsleep = true
        return true
    }

    /// 只有完整唤醒（`didWake`）调用这里；Dark Wake 不是唤醒。
    mutating func noteSystemDidWake(underlayUsable usable: Bool) -> Bool {
        let changed = systemAsleep || underlayUsable != usable
        systemAsleep = false
        underlayUsable = usable
        return changed
    }

    /// 休眠期间只记录路径；休眠本身已经关闭了门。第一次观察总要发送，用来清除
    /// 上一宿主实例可能留下的关闭态。
    mutating func observeUnderlay(usable: Bool) -> Bool {
        let first = !observedUnderlay
        observedUnderlay = true
        let changed = underlayUsable != usable
        underlayUsable = usable
        return first || (changed && !systemAsleep)
    }

    mutating func makeMessage() -> ProviderLineRecoveryConditions {
        sequence += 1
        return ProviderLineRecoveryConditions(
            source: source,
            sequence: sequence,
            systemAsleep: systemAsleep,
            underlayUsable: underlayUsable
        )
    }
}
