import AppKit
import XCTest

final class FeedbackAssistantTests: XCTestCase {
    func testDiscoveryRejectsMissingMismatchedAndNonexecutableBundles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Renamed Assistant.app")
        let executable = app.appendingPathComponent("Contents/MacOS/Assistant")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("test executable".utf8).write(to: executable)
        let info: [String: Any] = ["CFBundleIdentifier": "com.xd.cindy", "CFBundleExecutable": "Assistant",
                                   "CFBundleDisplayName": "Renamed Cindy", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        XCTAssertTrue(FeedbackAssistant.discover(resolve: { _ in nil }).isEmpty)
        XCTAssertTrue(FeedbackAssistant.discover(resolve: { _ in app }).isEmpty)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let discovered = FeedbackAssistant.discover(resolve: { _ in app })
        XCTAssertEqual(discovered.count, 1)
        XCTAssertEqual(discovered.first?.id, "com.xd.cindy")
        XCTAssertEqual(discovered.first?.name, "Renamed Cindy")
        XCTAssertEqual(discovered.first?.applicationURL, app)
    }

    @MainActor func testHandoffCopiesFileAndTextAndRemembersOnlySuccessfulOpen() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "xdial-feedback-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let assistant = FeedbackAssistant(id: "com.xd.cindy", name: "Cindy", applicationURL: URL(fileURLWithPath: "/Applications/Cindy.app"))
        var opened: [URL] = []
        var finish: ((Bool) -> Void)?
        let coordinator = FeedbackCoordinator(defaults: defaults, directory: root, discover: { [assistant] }, open: {
            opened.append($0); finish = $1
        })
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        coordinator.refreshAssistants()
        coordinator.description = "现场说明"
        coordinator.continueInAssistant(english: false, pasteboard: pasteboard)
        XCTAssertEqual(opened, [assistant.applicationURL])
        XCTAssertTrue(coordinator.isOpening)
        coordinator.continueInAssistant(english: false, pasteboard: pasteboard)
        XCTAssertEqual(opened.count, 1)
        XCTAssertTrue(pasteboard.string(forType: .string)?.contains("现场说明") == true)
        XCTAssertNotNil(pasteboard.string(forType: .fileURL))
        XCTAssertNotNil(coordinator.fileURL)
        XCTAssertNil(defaults.string(forKey: "xdial.feedback.assistant"))
        finish?(true)
        XCTAssertEqual(coordinator.outcome, .opened("Cindy"))
        XCTAssertFalse(coordinator.isOpening)
        XCTAssertEqual(defaults.string(forKey: "xdial.feedback.assistant"), assistant.id)
    }

    @MainActor func testFailedOpenKeepsFileForManualHandoff() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let assistant = FeedbackAssistant(id: "test", name: "Test", applicationURL: root)
        let coordinator = FeedbackCoordinator(directory: root, discover: { [assistant] }, open: { _, complete in complete(false) })
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        coordinator.refreshAssistants()
        coordinator.continueInAssistant(english: true, pasteboard: pasteboard)
        XCTAssertEqual(coordinator.outcome, .openFailed)
        XCTAssertNotNil(coordinator.fileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: coordinator.fileURL!.path))
    }

    @MainActor func testMissingAssistantDoesNotLaunchAnotherOrLoseDraft() {
        let first = FeedbackAssistant(id: "first", name: "First", applicationURL: URL(fileURLWithPath: "/first"))
        let second = FeedbackAssistant(id: "second", name: "Second", applicationURL: URL(fileURLWithPath: "/second"))
        var installed = [first, second]
        var opened = false
        let coordinator = FeedbackCoordinator(discover: { installed }, open: { _, _ in opened = true })
        coordinator.refreshAssistants()
        coordinator.selectedAssistantID = first.id
        coordinator.description = "保留这份反馈"
        installed = [second]
        coordinator.refreshAssistants()
        XCTAssertNil(coordinator.selectedAssistant)
        XCTAssertEqual(coordinator.outcome, .assistantUnavailable)
        coordinator.continueInAssistant(english: false)
        XCTAssertFalse(opened)
        XCTAssertEqual(coordinator.outcome, .openFailed)
        XCTAssertEqual(coordinator.description, "保留这份反馈")
        installed = []
        coordinator.refreshAssistants()
        XCTAssertTrue(coordinator.assistants.isEmpty)
        XCTAssertEqual(coordinator.description, "保留这份反馈")
    }

    @MainActor func testSuggestionOmitsRuntimeAndConfigurationIncludesItByDefault() {
        let coordinator = FeedbackCoordinator(discover: { [] })
        coordinator.snapshot = FeedbackRuntimeSnapshot(connectionStatus: "connected", installationState: .ready,
            hasUnappliedChanges: false, connection: nil, scenarioSwitch: nil)
        coordinator.kind = .suggestion
        XCTAssertFalse(coordinator.includeDiagnostics)
        XCTAssertNil(coordinator.package().runtime)
        coordinator.kind = .configuration
        XCTAssertTrue(coordinator.includeDiagnostics)
        XCTAssertNotNil(coordinator.package().runtime)
    }

    @MainActor func testInstallingFirstAssistantResumesTheExistingDraft() {
        var installed: [FeedbackAssistant] = []
        let coordinator = FeedbackCoordinator(discover: { installed })
        coordinator.refreshAssistants()
        coordinator.description = "安装前已填写的建议"
        coordinator.kind = .suggestion
        installed = [FeedbackAssistant(id: "com.xd.cindy", name: "Cindy", applicationURL: URL(fileURLWithPath: "/Cindy.app"))]
        coordinator.refreshAssistants()
        XCTAssertEqual(coordinator.selectedAssistantID, "com.xd.cindy")
        XCTAssertEqual(coordinator.description, "安装前已填写的建议")
        XCTAssertEqual(coordinator.kind, .suggestion)
        XCTAssertFalse(coordinator.includeDiagnostics)
    }

    @MainActor func testExportFailureDoesNotLaunchOrReplaceClipboard() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("not a directory".utf8).write(to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let assistant = FeedbackAssistant(id: "test", name: "Test", applicationURL: root)
        var opened = false
        let coordinator = FeedbackCoordinator(directory: root, discover: { [assistant] }, open: { _, _ in opened = true })
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("previous contents", forType: .string)
        coordinator.refreshAssistants()
        coordinator.continueInAssistant(english: false, pasteboard: pasteboard)
        XCTAssertFalse(opened)
        XCTAssertEqual(coordinator.outcome, .exportFailed)
        XCTAssertEqual(pasteboard.string(forType: .string), "previous contents")
    }
}
