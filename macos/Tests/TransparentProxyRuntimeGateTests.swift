import XCTest

final class TransparentProxyRuntimeGateTests: XCTestCase {
    func testConnectedRequiresSameCommittedTransactionAndIngress() {
        let report = committedReport(transactionID: "current")

        XCTAssertEqual(
            TransparentProxyRuntimeGate.resolve(
                systemStatus: "connected",
                report: report,
                activeTransactionID: "current",
                previousStatus: "connecting"
            ),
            "connected"
        )
        XCTAssertEqual(
            TransparentProxyRuntimeGate.resolve(
                systemStatus: "connected",
                report: report,
                activeTransactionID: "stale",
                previousStatus: "connecting"
            ),
            "connecting"
        )

        var missingIngress = report
        missingIngress.updateTask(
            id: "ingress:transparent-proxy",
            state: .ready
        )
        XCTAssertEqual(
            TransparentProxyRuntimeGate.resolve(
                systemStatus: "connected",
                report: missingIngress,
                activeTransactionID: "current",
                previousStatus: "connecting"
            ),
            "connecting"
        )

        var removedTakeover = report
        removedTakeover.systemTakeoverRemoved = true
        XCTAssertEqual(
            TransparentProxyRuntimeGate.resolve(
                systemStatus: "connected",
                report: removedTakeover,
                activeTransactionID: "current",
                previousStatus: "connecting"
            ),
            "connecting"
        )
    }

    func testSystemStatusStillBoundsCommittedReport() {
        let report = committedReport(transactionID: "current")
        XCTAssertEqual(
            TransparentProxyRuntimeGate.resolve(
                systemStatus: "disconnected",
                report: report,
                activeTransactionID: "current",
                previousStatus: "connected"
            ),
            "disconnected"
        )

        var rollingBack = report
        rollingBack.setState(.rollingBack)
        XCTAssertEqual(
            TransparentProxyRuntimeGate.resolve(
                systemStatus: "connected",
                report: rollingBack,
                activeTransactionID: "current",
                previousStatus: "connected"
            ),
            "disconnecting"
        )
    }

    func testAutomaticRecoveryRejectsLostCommittedSession() {
        let oldReport = committedReport(transactionID: "old")
        let proofTransactionID =
            TransparentProxyRuntimeGate
                .connectionProofTransactionID(
                    currentTransactionID: "old",
                    automaticReconnectInProgress: true,
                    attemptTransactionID: nil
                )

        XCTAssertNil(proofTransactionID)
        XCTAssertEqual(
            TransparentProxyRuntimeGate.resolve(
                systemStatus: "connected",
                report: oldReport,
                activeTransactionID: proofTransactionID,
                previousStatus: "reconnecting"
            ),
            "reconnecting"
        )
    }

    func testRecoveryProofIsTheOpenAttemptTransaction() {
        let proof =
            TransparentProxyRuntimeGate
                .connectionProofTransactionID(
                    currentTransactionID: "retry",
                    automaticReconnectInProgress: true,
                    attemptTransactionID: "retry"
                )
        XCTAssertEqual(proof, "retry")
        XCTAssertEqual(
            TransparentProxyRuntimeGate.resolve(
                systemStatus: "connected",
                report: committedReport(transactionID: "retry"),
                activeTransactionID: proof,
                previousStatus: "reconnecting"
            ),
            "connected"
        )
        XCTAssertEqual(
            TransparentProxyRuntimeGate.resolve(
                systemStatus: "connected",
                report: committedReport(transactionID: "old"),
                activeTransactionID: proof,
                previousStatus: "reconnecting"
            ),
            "reconnecting"
        )
    }

    func testRecoveryProofNeedsTheAttemptToBeCurrent() {
        XCTAssertNil(
            TransparentProxyRuntimeGate.connectionProofTransactionID(
                currentTransactionID: "switch-target",
                automaticReconnectInProgress: true,
                attemptTransactionID: "retry"
            )
        )
    }

    /// Incident 2026-10-22: the retry committed and macOS reported the
    /// session connected, but a state read from before the start had erased
    /// the Host's session marker, so the retry stayed unproven forever. The
    /// proof is now only the attempt's own committed transaction.
    func testCommittedRetryIsProvenWithoutAnySessionMarker() {
        let proof =
            TransparentProxyRuntimeGate
                .connectionProofTransactionID(
                    currentTransactionID: "684A0DF0",
                    automaticReconnectInProgress: true,
                    attemptTransactionID: "684A0DF0"
                )
        XCTAssertEqual(
            TransparentProxyRuntimeGate.resolve(
                systemStatus: "connected",
                report: committedReport(transactionID: "684A0DF0"),
                activeTransactionID: proof,
                previousStatus: "reconnecting"
            ),
            "connected"
        )
    }

    private func committedReport(
        transactionID: String
    ) -> ConnectionReport {
        let plan = ConnectionPlan(
            schemaVersion: 3,
            scenario: ConnectionPlanScenario(id: "scenario", name: "Scenario"),
            tasks: [
                ConnectionPlanTask(
                    id: "ingress:transparent-proxy",
                    kind: "ingress",
                    name: "Transparent Proxy",
                    preparation: "commit"
                ),
            ]
        )
        var report = ConnectionReport(
            transactionID: transactionID,
            plan: plan
        )
        report.updateTask(
            id: "ingress:transparent-proxy",
            state: .committed
        )
        report.systemTakeoverRemoved = false
        report.setState(.committed)
        return report
    }
}
