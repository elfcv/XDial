import XCTest

final class FeedbackPackageTests: XCTestCase {
    private func snapshot() -> FeedbackRuntimeSnapshot {
        let plan = ConnectionPlan(schemaVersion: 3,
            scenario: ConnectionPlanScenario(id: "PRIVATE_SCENARIO_ID", name: "PRIVATE_SCENARIO_NAME"),
            configurationFingerprint: "PRIVATE_FINGERPRINT", tasks: [
                ConnectionPlanTask(id: "PRIVATE_TASK", kind: "PRIVATE_KIND", name: "PRIVATE_NAME",
                    detail: "PRIVATE_DETAIL", preparation: "PRIVATE_PREPARATION", resourceID: "PRIVATE_RESOURCE",
                    resourceType: "PRIVATE_RESOURCE_TYPE")
            ])
        var report = ConnectionReport(transactionID: "PRIVATE_TRANSACTION", plan: plan)
        report.fail(code: "PRIVATE_CODE", message: "PRIVATE_PASSWORD", taskID: "PRIVATE_TASK")
        report.events.append(ConnectionReportEvent(sequence: 2, timestamp: Date(), type: "PRIVATE_TYPE",
            state: "PRIVATE_STATE", taskID: "PRIVATE_TASK", code: "PRIVATE_CODE", message: "PRIVATE_ERROR", facts: ["PRIVATE_KEY": true]))
        let projection = HostScenarioSwitchProjection(status: "PRIVATE_STATUS", fromScenarioID: "PRIVATE_SOURCE",
            toScenarioID: "PRIVATE_TARGET", sourceCommittedTransactionID: "source", candidateTransactionID: "target",
            activeCommittedTransactionID: "source", inFlight: false, candidateReport: report,
            reusedLineIDs: ["PRIVATE_LINE"], code: "PRIVATE_CODE", message: "PRIVATE_MESSAGE")
        return FeedbackRuntimeSnapshot(connectionStatus: "PRIVATE_STATUS", installationState: .ready,
            hasUnappliedChanges: true, connection: report, scenarioSwitch: projection)
    }

    func testRuntimeSnapshotStripsIdentitiesMessagesAndUnknownFields() throws {
        let data = try JSONEncoder().encode(snapshot())
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("PRIVATE"))
        XCTAssertFalse(text.contains("transactionID"))
        XCTAssertFalse(text.contains("configurationFingerprint"))
        XCTAssertTrue(text.contains("unclassified"))
        XCTAssertTrue(text.contains("source"))
        XCTAssertEqual(snapshot().connectionStatus, "unknown")
    }

    func testRuntimeCanBeOmittedAndUserDescriptionIsPreserved() throws {
        let package = FeedbackPackage(kind: .suggestion, description: "用户自己填写的描述 PRIVATE_USER_TEXT", runtime: nil)
        let text = try package.text(english: false)
        XCTAssertTrue(text.contains("用户自己填写的描述 PRIVATE_USER_TEXT"))
        XCTAssertFalse(text.contains("connectionStatus"))
        XCTAssertFalse(text.contains("白名单运行事实"))
        XCTAssertTrue(text.contains("功能建议"))
        XCTAssertTrue(try package.text(english: true).contains("feature suggestion"))
    }

    func testConfigurationTaskExplainsSupportedEditingAndSeparateApply() throws {
        let text = try FeedbackPackage(kind: .configuration, description: "办公域名走指定线路", runtime: snapshot()).text(english: false)
        XCTAssertTrue(text.contains("不要直接修改加密配置库或钥匙串"))
        XCTAssertTrue(text.contains("由用户决定何时应用并重连"))
        XCTAssertTrue(text.contains("办公域名走指定线路"))
        XCTAssertFalse(text.contains("PRIVATE"))
    }

    func testDescriptionAndReportEventsAreBounded() throws {
        let package = FeedbackPackage(kind: .problem, description: String(repeating: "长", count: 20_000), runtime: nil)
        XCTAssertEqual(package.description.count, FeedbackPackage.descriptionLimit)
        let plan = ConnectionPlan(schemaVersion: 3, scenario: ConnectionPlanScenario(id: "id", name: "name"),
                                  configurationFingerprint: "fingerprint", tasks: [])
        var report = ConnectionReport(transactionID: "id", plan: plan)
        for sequence in 0..<50 {
            report.events.append(ConnectionReportEvent(sequence: sequence, timestamp: Date(), type: "task",
                state: "running", taskID: "PRIVATE", code: "", message: "PRIVATE", facts: nil))
        }
        let summary = FeedbackRuntimeSnapshot.Report(report)
        XCTAssertEqual(summary.recentEvents.count, 20)
    }

    func testFilesArePrivateAndRetriesDoNotOverwriteEvidence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let package = FeedbackPackage(kind: .diagnosis, description: "问题", runtime: snapshot())
        let first = try package.write(text: "first", under: root)
        let second = try package.write(text: "second", under: root)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try String(contentsOf: first), "first")
        XCTAssertEqual(try String(contentsOf: second), "second")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: first.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: first.deletingLastPathComponent().path)[.posixPermissions] as? Int, 0o700)
    }
}
