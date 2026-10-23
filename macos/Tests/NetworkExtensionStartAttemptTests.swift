import XCTest

final class NetworkExtensionStartAttemptTests: XCTestCase {
    func testInactiveReadBeforeTheStartIsActedOnDecidesNothing() {
        let attempt = makeAttempt()

        XCTAssertEqual(attempt.inactiveSession, .beforeStart)
    }

    func testProviderCopyOfTheTransactionMakesInactiveTheSessionEnd() {
        var attempt = makeAttempt()
        attempt.noteProviderReport(report(transactionID: "retry"))

        XCTAssertTrue(attempt.providerTookTransaction)
        XCTAssertEqual(attempt.inactiveSession, .sessionEnded)
    }

    func testOtherTransactionsProviderReportNeverTakesTheAttempt() {
        var attempt = makeAttempt()
        attempt.noteProviderReport(report(transactionID: "previous"))
        attempt.noteProviderReport(nil)

        XCTAssertFalse(attempt.providerTookTransaction)
        XCTAssertEqual(attempt.inactiveSession, .beforeStart)
    }

    func testSystemActivityWithoutProviderCopyIsARejectedStart() {
        var attempt = makeAttempt()
        attempt.noteSystemActive()
        attempt.noteProviderReport(report(transactionID: "previous"))
        XCTAssertEqual(attempt.inactiveSession, .startRejected)

        attempt.noteProviderReport(report(transactionID: "retry"))
        XCTAssertEqual(attempt.inactiveSession, .sessionEnded)
    }

    /// An unanswered probe says nothing about what the Provider wrote, so the
    /// start stays undecided until the journal answers or the budget ends.
    func testUnansweredProviderProbeNeverRejectsTheStart() {
        var attempt = makeAttempt()
        attempt.noteSystemActive()
        attempt.noteProviderReport(nil)

        XCTAssertFalse(attempt.providerJournalAnswered)
        XCTAssertEqual(attempt.inactiveSession, .beforeStart)

        attempt.noteProviderReport(report(transactionID: "previous"))
        attempt.noteProviderReport(nil)
        XCTAssertEqual(attempt.inactiveSession, .beforeStart)
    }

    func testStartBudgetBoundsAnAttemptMacOSNeverActsOn() {
        var attempt = makeAttempt()
        for _ in 1..<NetworkExtensionStartAttempt.startCheckBudget {
            XCTAssertEqual(
                attempt.recordCheck(sessionActive: false),
                .keepWaiting
            )
        }
        XCTAssertEqual(attempt.recordCheck(sessionActive: false), .timedOut)
    }

    func testUnprovenActiveSessionIsStoppedThenBounded() {
        var attempt = makeAttempt()
        for _ in 1..<NetworkExtensionStartAttempt.startCheckBudget {
            XCTAssertEqual(
                attempt.recordCheck(sessionActive: true),
                .keepWaiting
            )
        }
        XCTAssertEqual(
            attempt.recordCheck(sessionActive: true),
            .stopSession
        )
        XCTAssertTrue(attempt.stopRequested)
        for _ in 1..<NetworkExtensionStartAttempt.stopCheckBudget {
            XCTAssertEqual(
                attempt.recordCheck(sessionActive: true),
                .keepWaiting
            )
        }
        XCTAssertEqual(attempt.recordCheck(sessionActive: true), .timedOut)
    }

    func testScopeNamesTheIntentAndTransaction() {
        let intentID = UUID()
        let attempt = NetworkExtensionStartAttempt(
            intentID: intentID,
            transactionID: "retry"
        )

        XCTAssertTrue(
            attempt.scope.matches(
                currentIntentID: intentID,
                currentTransactionID: "retry"
            )
        )
        XCTAssertFalse(
            attempt.scope.matches(
                currentIntentID: UUID(),
                currentTransactionID: "retry"
            )
        )
    }

    /// Incident 2026-10-22, attempt 3: the Host started 684A0DF0 and, by
    /// inference from the Host's journal reads, read `disconnected` 0.5 s
    /// later; nesessionmanager received the start only 2.5 s after the call,
    /// and the retry then committed while connected.
    func testIncident684A0DF0IsProvenAtTheFirstConnectedRead() {
        var attempt = NetworkExtensionStartAttempt(
            intentID: UUID(),
            transactionID: "684A0DF0"
        )

        // +0.5 s: the system session is still the one before the start.
        XCTAssertEqual(attempt.inactiveSession, .beforeStart)
        XCTAssertEqual(attempt.recordCheck(sessionActive: false), .keepWaiting)

        // +2.5 s: the session acts on the start and the Provider writes its
        // copy of the seed.
        attempt.noteSystemActive()
        var providerReport = report(transactionID: "684A0DF0")
        attempt.noteProviderReport(providerReport)
        XCTAssertEqual(attempt.recordCheck(sessionActive: true), .keepWaiting)

        // +9.5 s: committed and connected; the attempt's own transaction
        // proves it.
        providerReport.updateTask(
            id: "ingress:transparent-proxy",
            state: .committed
        )
        providerReport.systemTakeoverRemoved = false
        providerReport.setState(.committed)
        let proof =
            TransparentProxyRuntimeGate.connectionProofTransactionID(
                currentTransactionID: "684A0DF0",
                automaticReconnectInProgress: true,
                attemptTransactionID: attempt.transactionID
            )
        XCTAssertEqual(
            TransparentProxyRuntimeGate.resolve(
                systemStatus: "connected",
                report: providerReport,
                activeTransactionID: proof,
                previousStatus: "reconnecting"
            ),
            "connected"
        )
    }

    private func settlement(
        recovery: Bool = false,
        awaits: Bool = false,
        consumed: Bool = false,
        stopped: Bool = false,
        settled: Bool = false,
        providerTook: Bool = false
    ) -> NetworkExtensionStartAttempt.Settlement {
        NetworkExtensionStartAttempt.settlement(
            isRecoveryAttempt: recovery,
            recoveryAwaitsTransaction: awaits,
            recoveryConsumedTransaction: consumed,
            stopRequested: stopped,
            settled: settled,
            providerTookTransaction: providerTook
        )
    }

    func testRecoveryAttemptIsSettledOnlyByTheStepWaitingForIt() {
        // The Provider settled it: the waiting step decides.
        XCTAssertEqual(
            settlement(recovery: true, awaits: true, settled: true),
            .recoveryStep(markSessionLost: false)
        )
        // The Provider took it and its session ended unsettled.
        XCTAssertEqual(
            settlement(recovery: true, awaits: true, providerTook: true),
            .recoveryStep(markSessionLost: true)
        )
        // A rejected start inside recovery fails as the step's outcome.
        XCTAssertEqual(
            settlement(recovery: true, awaits: true),
            .fail(markSessionLost: false, cause: .providerStartFailed)
        )
        // Stopped for its budget and settled by the stopped Provider: the
        // waiting step decides, worded as a timeout by the Host.
        XCTAssertEqual(
            settlement(
                recovery: true,
                awaits: true,
                stopped: true,
                settled: true,
                providerTook: true
            ),
            .recoveryStep(markSessionLost: false)
        )
        // Stopped for its budget before the Provider settled it.
        XCTAssertEqual(
            settlement(
                recovery: true,
                awaits: true,
                stopped: true,
                providerTook: true
            ),
            .fail(markSessionLost: false, cause: .startTimedOut)
        )
    }

    func testRecoveryAttemptDecidedAlreadyIsNeverSettledTwice() {
        XCTAssertEqual(
            settlement(recovery: true, consumed: true, settled: true),
            .alreadyDecided
        )
    }

    /// Parking ended (e.g. its Scenario was removed) while a wake or tail
    /// attempt was in flight: the attempt still has to end visibly.
    func testRecoveryAttemptOrphanedByEndedRecoverySettlesLikeAnyStart() {
        XCTAssertEqual(
            settlement(recovery: true, providerTook: true),
            .fail(markSessionLost: true, cause: .providerSessionLost)
        )
        XCTAssertEqual(
            settlement(recovery: true, settled: true),
            .fail(markSessionLost: false, cause: .providerStartFailed)
        )
    }

    func testPlainStartSettlement() {
        XCTAssertEqual(
            settlement(stopped: true, settled: true, providerTook: true),
            .fail(markSessionLost: false, cause: .startTimedOut)
        )
        XCTAssertEqual(
            settlement(providerTook: true),
            .fail(markSessionLost: true, cause: .providerSessionLost)
        )
        XCTAssertEqual(
            settlement(settled: true, providerTook: true),
            .fail(markSessionLost: false, cause: .providerStartFailed)
        )
        XCTAssertEqual(
            settlement(),
            .fail(markSessionLost: false, cause: .providerStartFailed)
        )
    }

    private func makeAttempt() -> NetworkExtensionStartAttempt {
        NetworkExtensionStartAttempt(
            intentID: UUID(),
            transactionID: "retry"
        )
    }

    private func report(transactionID: String) -> ConnectionReport {
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
        return ConnectionReport(transactionID: transactionID, plan: plan)
    }
}
