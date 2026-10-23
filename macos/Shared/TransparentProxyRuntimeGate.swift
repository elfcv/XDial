import Foundation

/// Combines the system Network Extension state with the current transaction.
///
/// `NEVPNStatus.connected` proves only that the system configuration is up. It
/// cannot publish XDial as connected until the same transaction has committed
/// its Transparent Proxy ingress and still owns the system takeover.
enum TransparentProxyRuntimeGate {
    /// During automatic recovery only the open attempt's own transaction can
    /// prove connectivity; the transaction which opened recovery never can.
    /// The attempt's ID is minted for it and reaches only the Provider session
    /// started with it, so that transaction's committed report together with
    /// a connected system session is the attempt's session. No separate
    /// session marker is kept: a system state read names no transaction, and
    /// one read from before the start could erase it for good.
    static func connectionProofTransactionID(
        currentTransactionID: String?,
        automaticReconnectInProgress: Bool,
        attemptTransactionID: String?
    ) -> String? {
        guard automaticReconnectInProgress else {
            return currentTransactionID
        }
        guard
            let attemptTransactionID,
            attemptTransactionID == currentTransactionID
        else {
            return nil
        }
        return attemptTransactionID
    }

    static func resolve(
        systemStatus: String,
        report: ConnectionReport?,
        activeTransactionID: String?,
        previousStatus: String
    ) -> String {
        switch systemStatus {
        case "connected":
            guard
                let report,
                report.transactionID == activeTransactionID,
                report.state == .committed,
                !report.systemTakeoverRemoved,
                report.tasks.contains(where: {
                    $0.id == "ingress:transparent-proxy"
                        && $0.kind == "ingress"
                        && $0.state == .committed
                })
            else {
                if report?.state == .rollingBack
                    || report?.state == .rolledBack
                    || report?.state == .failed
                    || report?.state == .cancelled {
                    return "disconnecting"
                }
                return previousStatus == "reconnecting"
                    ? "reconnecting"
                    : "connecting"
            }
            return "connected"
        case "connecting":
            return "connecting"
        case "reconnecting":
            return "reconnecting"
        case "disconnecting":
            return "disconnecting"
        case "disconnected":
            return "disconnected"
        default:
            return "disconnected"
        }
    }
}
