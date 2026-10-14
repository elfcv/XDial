import Foundation

enum ScenarioSwitchFailureCode {
    static let lineReadinessTransient = "line-readiness-transient"
    static let anyConnectRebuildRequired = "switch-anyconnect-rebuild-required"
    static let ruleSetPreflightUnavailable = "switch-rule-set-preflight-unavailable"

    /// 原理上无法保留旧连接完成的切换：AnyConnect 是进程级单例，不同线路不能
    /// 并存；规则需要冷获取时候选无法在不断流的前提下准备。这类失败不能停在
    /// 原场景，改为断开旧连接后完整连接目标场景。
    static func requiresFullReconnect(_ code: String?) -> Bool {
        code == anyConnectRebuildRequired || code == ruleSetPreflightUnavailable
    }
}

enum AutomaticScenarioSwitchWakePolicy {
    static func shouldResume(
        suspendedScenarioID: String?,
        currentDesiredScenarioID: String?,
        committedScenarioID: String
    ) -> Bool {
        guard let suspendedScenarioID,
              !suspendedScenarioID.isEmpty,
              suspendedScenarioID == currentDesiredScenarioID else {
            return false
        }
        return suspendedScenarioID != committedScenarioID
    }
}

/// Owns the bounded retry budget for one settled automatic network epoch.
/// Re-observing the same identity cannot replenish its budget, while a newer
/// epoch or Scenario generation invalidates every outstanding timer token.
struct AutomaticScenarioSwitchRetryState {
    struct Identity: Equatable {
        let epoch: UInt64
        let scenarioGeneration: Int
        let targetScenarioID: String
    }

    struct Token: Equatable {
        let identity: Identity
        let retryNumber: Int
    }

    struct ScheduledRetry: Equatable {
        let token: Token
        let delay: TimeInterval
    }

    private let delays: [TimeInterval]
    private(set) var identity: Identity?
    private(set) var retriesScheduled = 0
    private var pendingRetryToken: Token?

    init(delays: [TimeInterval] = [2, 5, 10]) {
        self.delays = delays
    }

    var maxRetries: Int { delays.count }
    var hasPendingRetry: Bool { pendingRetryToken != nil }

    /// Returns true only when this starts a distinct automatic intent.
    @discardableResult
    mutating func begin(_ newIdentity: Identity) -> Bool {
        guard identity != newIdentity else { return false }
        identity = newIdentity
        retriesScheduled = 0
        pendingRetryToken = nil
        return true
    }

    mutating func scheduleRetry(
        failureCode: String?
    ) -> ScheduledRetry? {
        guard failureCode == ScenarioSwitchFailureCode.lineReadinessTransient,
              let identity,
              delays.indices.contains(retriesScheduled) else {
            return nil
        }
        let retryNumber = retriesScheduled + 1
        let retry = ScheduledRetry(
            token: Token(
                identity: identity,
                retryNumber: retryNumber
            ),
            delay: delays[retriesScheduled]
        )
        retriesScheduled = retryNumber
        pendingRetryToken = retry.token
        return retry
    }

    func isCurrent(_ token: Token) -> Bool {
        identity == token.identity
            && retriesScheduled == token.retryNumber
            && pendingRetryToken == token
    }

    /// Atomically consumes the one scheduled retry. Runtime status updates may
    /// call the ordinary drive loop while a timer is pending, but only this
    /// token can open the gate after its backoff expires.
    mutating func takeRetry(_ token: Token) -> Bool {
        guard isCurrent(token) else { return false }
        pendingRetryToken = nil
        return true
    }

    mutating func cancel() {
        identity = nil
        retriesScheduled = 0
        pendingRetryToken = nil
    }
}
