import Foundation

/// One `startVPNTunnel` for one transaction, from the call until that
/// transaction is proven connected or settled.
///
/// A system session state names no transaction, and after the call it may
/// take seconds to change (on 2026-10-22 nesessionmanager received the start
/// 2.5 s after the Host called it; why is unproven). An inactive state read
/// in that gap is the session before this start, not its result. The attempt
/// is therefore judged by what the Host has seen for its transaction: once
/// the Provider has validated the start options it writes the Host's seed
/// into its own journal, which the Host reads through the daemon. The check
/// budget bounds an attempt for which nothing is ever seen.
struct NetworkExtensionStartAttempt: Equatable {
    enum InactiveSession: Equatable {
        /// The Host has not read the Provider's copy of the transaction, and
        /// either has seen no system session state other than inactive or got
        /// no answer from its latest Provider journal probe (daemon
        /// unreachable, or no journal yet); the read decides nothing.
        case beforeStart
        /// The Host has seen the Provider's copy, so this session ran the
        /// transaction and is gone.
        case sessionEnded
        /// The Host saw the system session act on the start, and the
        /// Provider journal answered without this transaction: the start was
        /// rejected before the Provider wrote it.
        case startRejected
    }

    enum Check: Equatable {
        case keepWaiting
        /// Still unproven after the start budget: stop the session and let
        /// its inactive state settle the transaction from facts.
        case stopSession
        /// Out of budget with nothing left to wait for.
        case timedOut
    }

    static let checkInterval: TimeInterval = 0.5
    /// At least 45 seconds (checks run after each check's own work) for the
    /// attempt to be proven or settled.
    static let startCheckBudget = 90
    /// At least 10 more seconds for a stopped session to become inactive.
    static let stopCheckBudget = 20

    let id: UUID
    let intentID: UUID
    let transactionID: String
    /// Started by an automatic recovery step for its own transaction; only
    /// that step's outcome gate may settle it.
    let isRecoveryAttempt: Bool
    let startedAt: Date
    private(set) var providerTookTransaction = false
    /// Whether the latest Provider journal probe returned a report at all;
    /// an unanswered probe proves nothing about what the Provider wrote.
    private(set) var providerJournalAnswered = false
    private(set) var systemActedOnStart = false
    private(set) var checksUsed = 0
    private(set) var stopRequested = false

    init(
        id: UUID = UUID(),
        intentID: UUID,
        transactionID: String,
        isRecoveryAttempt: Bool = false,
        startedAt: Date = Date()
    ) {
        self.id = id
        self.intentID = intentID
        self.transactionID = transactionID
        self.isRecoveryAttempt = isRecoveryAttempt
        self.startedAt = startedAt
    }

    var scope: ConnectionStartAttemptScope {
        ConnectionStartAttemptScope(
            intentID: intentID,
            transactionID: transactionID
        )
    }

    var inactiveSession: InactiveSession {
        if providerTookTransaction {
            return .sessionEnded
        }
        return systemActedOnStart && providerJournalAnswered
            ? .startRejected
            : .beforeStart
    }

    /// `report` is the daemon's read of the Provider's own journal, never
    /// the Host's seed; nil when the probe got no report.
    mutating func noteProviderReport(_ report: ConnectionReport?) {
        providerJournalAnswered = report != nil
        if report?.transactionID == transactionID {
            providerTookTransaction = true
        }
    }

    /// Any session state other than invalid / disconnected after the call.
    mutating func noteSystemActive() {
        systemActedOnStart = true
    }

    /// What to do once the session of an attempt the Host saw acted on is
    /// inactive and the Provider's last report has been read.
    enum Settlement: Equatable {
        enum Cause: Equatable {
            case startTimedOut
            /// The disconnect error, or "Provider session lost" without one.
            case providerSessionLost
            /// The disconnect error, or "Provider start failed" without one.
            case providerStartFailed
        }

        /// The recovery step already consumed this transaction's outcome.
        case alreadyDecided
        /// Hand the transaction to the recovery step waiting for it, after
        /// settling it as a lost Provider session when `markSessionLost`.
        case recoveryStep(markSessionLost: Bool)
        /// Fail the transaction; inside recovery the failed report is the
        /// step's outcome.
        case fail(markSessionLost: Bool, cause: Cause)
    }

    /// `recoveryAwaitsTransaction`: recovery is in progress and its outcome
    /// gate waits for this transaction. `recoveryConsumedTransaction`: the
    /// gate already decided this transaction. A recovery attempt whose
    /// recovery ended elsewhere (e.g. parking ended) settles like any start.
    static func settlement(
        isRecoveryAttempt: Bool,
        recoveryAwaitsTransaction: Bool,
        recoveryConsumedTransaction: Bool,
        stopRequested: Bool,
        settled: Bool,
        providerTookTransaction: Bool
    ) -> Settlement {
        if isRecoveryAttempt {
            if recoveryAwaitsTransaction {
                if settled {
                    return .recoveryStep(markSessionLost: false)
                }
                if stopRequested {
                    return .fail(markSessionLost: false, cause: .startTimedOut)
                }
                return providerTookTransaction
                    ? .recoveryStep(markSessionLost: true)
                    : .fail(markSessionLost: false, cause: .providerStartFailed)
            }
            if recoveryConsumedTransaction {
                return .alreadyDecided
            }
        }
        if stopRequested {
            return .fail(markSessionLost: false, cause: .startTimedOut)
        }
        let lost = !settled && providerTookTransaction
        return .fail(
            markSessionLost: lost,
            cause: lost ? .providerSessionLost : .providerStartFailed
        )
    }

    mutating func recordCheck(sessionActive: Bool) -> Check {
        checksUsed += 1
        if stopRequested {
            return checksUsed >= Self.startCheckBudget + Self.stopCheckBudget
                ? .timedOut
                : .keepWaiting
        }
        guard checksUsed >= Self.startCheckBudget else {
            return .keepWaiting
        }
        guard sessionActive else {
            return .timedOut
        }
        stopRequested = true
        return .stopSession
    }
}
