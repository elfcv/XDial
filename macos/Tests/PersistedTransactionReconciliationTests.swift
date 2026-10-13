import XCTest

final class PersistedTransactionReconciliationTests: XCTestCase {
    private let unfinishedStates: [ConnectionTransactionState] = [
        .planning,
        .preparing,
        .readyToCommit,
        .committing,
        .rollingBack,
        .rolledBack,
    ]

    /// 2026-10-06: a wake status sync arrived while this Host's automatic
    /// reconnect was still preparing. It must not be treated as a leftover of
    /// an earlier process and stopped.
    func testLateSyncNeverStopsThisHostsPreparingTransaction() {
        for state in unfinishedStates {
            for session in [
                SystemProxySessionState.absent,
                .inactive,
                .active,
            ] {
                XCTAssertEqual(
                    decide(
                        state,
                        .thisHost,
                        session,
                        hostIntentActive: true
                    ),
                    .none,
                    "state=\(state) session=\(session)"
                )
            }
        }
    }

    func testInheritedUnfinishedTransactionIsRecovered() {
        for state in unfinishedStates {
            XCTAssertEqual(
                decide(state, .inherited, .active),
                .recoverInterrupted(stopSystemSession: true),
                "state=\(state)"
            )
            XCTAssertEqual(
                decide(state, .inherited, .inactive),
                .recoverInterrupted(stopSystemSession: false),
                "state=\(state)"
            )
            XCTAssertEqual(
                decide(state, .inherited, .absent),
                .recoverInterrupted(stopSystemSession: false),
                "state=\(state)"
            )
        }
    }

    func testInheritedStateIgnoresUnrelatedHostIntent() {
        XCTAssertEqual(
            decide(.preparing, .inherited, .active, hostIntentActive: true),
            .recoverInterrupted(stopSystemSession: true)
        )
    }

    func testWithdrawnOwnTransactionFinishesOnlyAfterSessionIsGone() {
        for state in unfinishedStates {
            XCTAssertEqual(
                decide(state, .thisHost, .inactive),
                .finishWithdrawnTransaction,
                "state=\(state)"
            )
            XCTAssertEqual(
                decide(state, .thisHost, .absent),
                .finishWithdrawnTransaction,
                "state=\(state)"
            )
            XCTAssertEqual(
                decide(state, .thisHost, .active),
                .none,
                "state=\(state)"
            )
        }
    }

    func testCommittedSessionLostIsAFactForAnyOwner() {
        for ownership in [TransactionOwnership.thisHost, .inherited] {
            for intent in [false, true] {
                XCTAssertEqual(
                    decide(
                        .committed,
                        ownership,
                        .inactive,
                        hostIntentActive: intent
                    ),
                    .markProviderSessionLost
                )
                XCTAssertEqual(
                    decide(
                        .committed,
                        ownership,
                        .absent,
                        hostIntentActive: intent
                    ),
                    .markProviderSessionLost
                )
            }
        }
    }

    func testRunningCommittedSessionIsAdoptedNotTornDown() {
        XCTAssertEqual(
            decide(.committed, .inherited, .active),
            .adoptCommittedSession
        )
        XCTAssertEqual(
            decide(.committed, .thisHost, .active),
            .none
        )
    }

    func testTerminalReportsAreNeverReinterpreted() {
        for state in [ConnectionTransactionState.failed, .cancelled] {
            for ownership in [TransactionOwnership.thisHost, .inherited] {
                for session in [
                    SystemProxySessionState.absent,
                    .inactive,
                    .active,
                ] {
                    XCTAssertEqual(
                        decide(state, ownership, session),
                        .none
                    )
                }
            }
        }
    }

    private func decide(
        _ state: ConnectionTransactionState,
        _ ownership: TransactionOwnership,
        _ session: SystemProxySessionState,
        hostIntentActive: Bool = false
    ) -> PersistedTransactionDisposition {
        let plan = ConnectionPlan(
            schemaVersion: 3,
            scenario: ConnectionPlanScenario(id: "scenario", name: "Scenario"),
            tasks: []
        )
        var report = ConnectionReport(transactionID: "tx", plan: plan)
        report.state = state
        return PersistedTransactionReconciliation.decide(
            report: report,
            ownership: ownership,
            systemSession: session,
            hostIntentActive: hostIntentActive
        )
    }
}
