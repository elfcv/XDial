import XCTest

final class ScenarioSwitchFeedbackTests: XCTestCase {
    private func observation(
        status: String = "preparing", inFlight: Bool = true,
        active: String = "source", cancelled: Bool = false
    ) -> ScenarioSwitchFeedback {
        let plan = ConnectionPlan(
            schemaVersion: 3,
            scenario: ConnectionPlanScenario(id: "private-scenario", name: "PRIVATE_NAME"),
            configurationFingerprint: "PRIVATE_FINGERPRINT", tasks: []
        )
        var report = ConnectionReport(transactionID: "private-transaction", plan: plan)
        report.fail(code: "secret-code", message: "PRIVATE_PASSWORD", taskID: "PRIVATE_TASK")
        return ScenarioSwitchFeedback(
            id: "11111111-1111-1111-1111-111111111111",
            startedAt: Date(timeIntervalSince1970: 100),
            observedAt: Date(timeIntervalSince1970: 101),
            status: status, inFlight: inFlight,
            sourceTransactionID: "source", targetTransactionID: "target",
            activeTransactionID: active, candidate: report, sameScenario: false,
            cancellationRequested: cancelled, code: "PRIVATE_CODE", channel: "debug"
        )
    }

    func testPublicObservationDoesNotCopyReportOrArbitraryStrings() throws {
        let data = try JSONEncoder().encode(observation())
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("PRIVATE"))
        XCTAssertFalse(text.contains("private-scenario"))
        XCTAssertFalse(text.contains("private-transaction"))
        XCTAssertFalse(text.contains("configurationFingerprint"))
        XCTAssertEqual(observation().errorCode, "unclassified")
    }

    func testCancellationAcknowledgementIsNotATerminalFact() {
        var history = ScenarioSwitchFeedbackHistory()
        XCTAssertTrue(history.record(observation()))
        XCTAssertTrue(history.record(observation(status: "reconciling", active: "", cancelled: true)))
        XCTAssertEqual(history.observations.last?.activeRelationship, "unknown")
        XCTAssertEqual(history.observations.last?.inFlight, true)
        XCTAssertTrue(history.record(observation(status: "committed", inFlight: false, active: "target")))
        XCTAssertEqual(history.observations.last?.cancellationRequested, true)
        XCTAssertEqual(history.observations.last?.activeRelationship, "target")
        XCTAssertFalse(history.record(observation()))
        XCTAssertEqual(history.observations.last?.status, "committed")
    }

    func testPollingIsDeduplicatedAndHistoryIsBounded() {
        var history = ScenarioSwitchFeedbackHistory()
        XCTAssertTrue(history.record(observation()))
        XCTAssertFalse(history.record(observation()))
        for _ in 0 ..< 5 {
            let value = ScenarioSwitchFeedback(
                id: UUID().uuidString, startedAt: Date(), status: "rejected",
                inFlight: false, sourceTransactionID: "", targetTransactionID: "",
                activeTransactionID: "", candidate: nil, sameScenario: nil
            )
            XCTAssertTrue(history.record(value, limit: 3))
        }
        XCTAssertEqual(history.observations.count, 3)
        XCTAssertNil(history.observations.last?.sameScenario)
    }

    func testPersistenceSurvivesRestartAndKeepsPrivatePermissions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("scenario-switch-observations.json")
        try ScenarioSwitchFeedbackRecorder(directory: directory).persist(observation())
        try ScenarioSwitchFeedbackRecorder(directory: directory).persist(
            observation(status: "failed", inFlight: false)
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let history = try decoder.decode(ScenarioSwitchFeedbackHistory.self, from: Data(contentsOf: file))
        XCTAssertEqual(history.observations.count, 1)
        XCTAssertEqual(history.observations.first?.transitions, ["preparing", "failed"])
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }

    func testCorruptHistoryIsNotOverwritten() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("scenario-switch-observations.json")
        let original = Data("broken journal".utf8)
        try original.write(to: file)
        XCTAssertThrowsError(try ScenarioSwitchFeedbackRecorder(directory: directory).persist(observation()))
        XCTAssertEqual(try Data(contentsOf: file), original)
    }
}
