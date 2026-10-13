import Foundation

/// Which Host process is responsible for finishing a journaled transaction.
///
/// The journal shape cannot distinguish a preparation that is still in flight
/// from one abandoned by a previous Host process: both read `preparing` while
/// macOS reports the session as `connecting`. Only the process which began
/// (or adopted) the transaction knows, so recovery is decided by ownership.
enum TransactionOwnership: Equatable {
    /// Began by this Host process, or a committed session it adopted.
    case thisHost
    /// Left behind by an earlier Host process.
    case inherited
}

/// The exact XDial Network Extension session as macOS reports it.
enum SystemProxySessionState: Equatable {
    /// No XDial Transparent Proxy configuration exists.
    case absent
    /// `.invalid` or `.disconnected`: no system takeover remains.
    case inactive
    /// `.connecting`, `.connected`, `.reasserting` or `.disconnecting`.
    case active
}

enum PersistedTransactionDisposition: Equatable {
    /// The live Host state machine, or nobody, owns the next step.
    case none
    /// An inherited committed session is still running; this Host takes it
    /// over instead of tearing it down.
    case adoptCommittedSession
    /// The report claims a committed takeover that macOS no longer has.
    case markProviderSessionLost
    /// An earlier Host process left this transaction unfinished.
    case recoverInterrupted(stopSystemSession: Bool)
    /// This Host withdrew its own intent (explicit stop) and macOS confirms no
    /// session remains, so no other writer can finish the report.
    case finishWithdrawnTransaction
}

enum PersistedTransactionReconciliation {
    static func decide(
        report: ConnectionReport,
        ownership: TransactionOwnership,
        systemSession: SystemProxySessionState,
        hostIntentActive: Bool
    ) -> PersistedTransactionDisposition {
        switch report.state {
        case .failed, .cancelled:
            // Unsafe terminal reports are completed by the exact manager's
            // disconnect confirmation, never by reinterpretation here.
            return .none
        case .committed:
            switch systemSession {
            case .absent, .inactive:
                return .markProviderSessionLost
            case .active:
                return ownership == .inherited
                    ? .adoptCommittedSession
                    : .none
            }
        case .planning, .preparing, .readyToCommit, .committing,
             .rollingBack, .rolledBack:
            switch ownership {
            case .inherited:
                return .recoverInterrupted(
                    stopSystemSession: systemSession == .active
                )
            case .thisHost:
                guard !hostIntentActive,
                      systemSession != .active else {
                    // Either the live start/reconnect/switch still owns it,
                    // or an explicit stop is draining the session and the
                    // disconnect projection will finish it.
                    return .none
                }
                return .finishWithdrawnTransaction
            }
        }
    }
}
