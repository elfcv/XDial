import XCTest

final class InstallationTransactionTests: XCTestCase {
    func testOnlyAwaitingUserApprovalAllowsTermination() {
        var report = InstallationReport.fresh(applicationAlreadyInstalled: true)
        XCTAssertFalse(report.allowsTermination)
        report.updateTask(id: "helper", state: .running)
        XCTAssertFalse(report.allowsTermination)
        report.updateTask(id: "helper", state: .waitingForApproval)
        XCTAssertTrue(report.allowsTermination)
        report.updateTask(id: "helper", state: .running)
        XCTAssertFalse(report.allowsTermination, "approval granted: mutation may follow")
        report.updateTask(id: "helper", state: .ready)
        report.updateTask(id: "system-extension", state: .waitingForApproval)
        XCTAssertTrue(report.allowsTermination)
    }

    func testReplacementForcesACopyThatRefusesToQuit() {
        var now: TimeInterval = 0
        var running: Set<Int32> = [81]
        var graceful: [Int32] = []
        var forced: [Int32] = []
        XCTAssertTrue(
            ApplicationReplacementExitWaiter.terminate(
                gracefulTimeout: 20, forcedTimeout: 5, pollInterval: 1,
                monotonicNow: { now }, sleep: { now += $0 },
                requestGracefulTermination: { graceful.append($0) },
                forceTermination: {
                    forced.append($0)
                    running.remove($0)
                },
                remainingProcessIdentifiers: { running }
            )
        )
        XCTAssertEqual(graceful, [81])
        XCTAssertEqual(forced, [81])
        // One poll after forcing confirms the copy is gone.
        XCTAssertEqual(now, 21, accuracy: 0.000_001)
    }

    func testReplacementDoesNotForceACopyThatQuits() {
        var now: TimeInterval = 0
        var running: Set<Int32> = [81]
        var forced: [Int32] = []
        XCTAssertTrue(
            ApplicationReplacementExitWaiter.terminate(
                pollInterval: 1,
                monotonicNow: { now }, sleep: { now += $0 },
                requestGracefulTermination: { _ in },
                forceTermination: { forced.append($0) },
                remainingProcessIdentifiers: {
                    if now >= 3 { running = [] }
                    return running
                }
            )
        )
        XCTAssertTrue(forced.isEmpty)
        XCTAssertEqual(now, 3, accuracy: 0.000_001)
    }

    func testReplacementReportsACopyThatSurvivesForce() {
        var now: TimeInterval = 0
        var forced: [Int32] = []
        XCTAssertFalse(
            ApplicationReplacementExitWaiter.terminate(
                gracefulTimeout: 2, forcedTimeout: 1, pollInterval: 0.5,
                monotonicNow: { now }, sleep: { now += $0 },
                requestGracefulTermination: { _ in },
                forceTermination: { forced.append($0) },
                remainingProcessIdentifiers: { [81] }
            )
        )
        XCTAssertEqual(forced, [81])
        XCTAssertEqual(now, 3, accuracy: 0.000_001)
    }

    func testReplacementExitWaiterExcludesCurrentInvalidAndDuplicates() {
        XCTAssertEqual(
            ApplicationReplacementExitWaiter
                .otherProcessIdentifiers(
                    currentProcessIdentifier: 42,
                    candidateProcessIdentifiers:
                        [0, -1, 42, 81, 81, 82]
                ),
            Set([81, 82])
        )
    }

    func testReplacementExitWaiterUsesFreshSnapshotUntilExit() {
        var now: TimeInterval = 10
        var snapshots = [
            Set<Int32>([81]),
            Set<Int32>([81]),
            Set<Int32>(),
        ]
        var sleepCount = 0

        XCTAssertTrue(
            ApplicationReplacementExitWaiter.wait(
                timeout: 5,
                pollInterval: 0.5,
                monotonicNow: { now },
                sleep: {
                    sleepCount += 1
                    now += $0
                },
                requestGracefulTermination: { _ in },
                remainingProcessIdentifiers: {
                    snapshots.removeFirst()
                }
            )
        )
        XCTAssertEqual(sleepCount, 2)
        XCTAssertEqual(now, 11)
    }

    func testReplacementExitWaiterStopsAtDeadline() {
        var now: TimeInterval = 20
        var sleepDurations: [TimeInterval] = []

        XCTAssertFalse(
            ApplicationReplacementExitWaiter.wait(
                timeout: 1,
                pollInterval: 0.4,
                monotonicNow: { now },
                sleep: {
                    sleepDurations.append($0)
                    now += $0
                },
                requestGracefulTermination: { _ in },
                remainingProcessIdentifiers: {
                    Set<Int32>([81])
                }
            )
        )
        XCTAssertEqual(
            sleepDurations.reduce(0, +),
            1,
            accuracy: 0.000_001
        )
    }

    func testReplacementExitWaiterReturnsImmediatelyWhenAlreadyGone() {
        var slept = false

        XCTAssertTrue(
            ApplicationReplacementExitWaiter.wait(
                timeout: 12,
                pollInterval: 0.05,
                monotonicNow: { 100 },
                sleep: { _ in slept = true },
                requestGracefulTermination: { _ in },
                remainingProcessIdentifiers: { [] }
            )
        )
        XCTAssertFalse(slept)
    }

    func testReplacementExitWaiterRequestsNewProcessOnce() {
        var now: TimeInterval = 10
        var snapshots = [
            Set<Int32>([81]),
            Set<Int32>([81, 82]),
            Set<Int32>([82]),
            Set<Int32>(),
        ]
        var requested: [Int32] = []

        XCTAssertTrue(
            ApplicationReplacementExitWaiter.wait(
                timeout: 5,
                pollInterval: 0.5,
                monotonicNow: { now },
                sleep: { now += $0 },
                requestGracefulTermination: {
                    requested.append($0)
                },
                remainingProcessIdentifiers: {
                    snapshots.removeFirst()
                }
            )
        )
        XCTAssertEqual(requested, [81, 82])
    }

    func testReplacementExitWaiterDoesNotRepeatVisibleProcess() {
        var now: TimeInterval = 10
        var snapshots = [
            Set<Int32>([81]),
            Set<Int32>([81]),
            Set<Int32>([81]),
            Set<Int32>(),
        ]
        var requested: [Int32] = []

        XCTAssertTrue(
            ApplicationReplacementExitWaiter.wait(
                timeout: 5,
                pollInterval: 0.5,
                monotonicNow: { now },
                sleep: { now += $0 },
                requestGracefulTermination: {
                    requested.append($0)
                },
                remainingProcessIdentifiers: {
                    snapshots.removeFirst()
                }
            )
        )
        XCTAssertEqual(requested, [81])
    }

    func testReplacementExitWaiterRequestsReappearingProcessAgain() {
        var now: TimeInterval = 10
        var snapshots = [
            Set<Int32>([81, 82]),
            Set<Int32>([82]),
            Set<Int32>([81, 82]),
            Set<Int32>(),
        ]
        var requested: [Int32] = []

        XCTAssertTrue(
            ApplicationReplacementExitWaiter.wait(
                timeout: 5,
                pollInterval: 0.5,
                monotonicNow: { now },
                sleep: { now += $0 },
                requestGracefulTermination: {
                    requested.append($0)
                },
                remainingProcessIdentifiers: {
                    snapshots.removeFirst()
                }
            )
        )
        XCTAssertEqual(requested, [81, 82, 81])
    }

    func testSystemExtensionFilenameMustMatchBundleIdentifier() {
        let identifier = "com.kafeifei.xdial.transparent-proxy"
        XCTAssertTrue(
            SystemExtensionBundleNaming.matches(
                bundleIdentifier: identifier,
                bundleURL: URL(
                    fileURLWithPath:
                        "/Applications/XDial.app/Contents/Library/"
                        + "SystemExtensions/\(identifier).systemextension"
                )
            )
        )
        XCTAssertFalse(
            SystemExtensionBundleNaming.matches(
                bundleIdentifier: identifier,
                bundleURL: URL(
                    fileURLWithPath:
                        "/Applications/XDial.app/Contents/Library/"
                        + "SystemExtensions/"
                        + "XDialTransparentProxy.systemextension"
                )
            )
        )
    }

    func testInstallationMarkerInvalidatesOlderReportSchema() {
        XCTAssertEqual(
            InstallationBuildMarker.make(
                bundleIdentifier: "com.kafeifei.xdial",
                bundleVersion: "79"
            ),
            "com.kafeifei.xdial:79:installation-v4"
        )
    }

    func testUpgradeResumesAfterOutgoingHelperWasUnregistered() {
        XCTAssertTrue(InstallationBuildMarker.shouldPrepareAtLaunch(
            serviceRegistered: false, registrationRecoveryPending: false,
            previousCompletedInstallation: "com.kafeifei.xdial.debug:78:installation-v3",
            bundleIdentifier: "com.kafeifei.xdial.debug"
        ))
    }

    func testRequestedInstallationResumesAfterQuitOrReplacement() {
        XCTAssertTrue(InstallationBuildMarker.shouldPrepareAtLaunch(
            serviceRegistered: false, registrationRecoveryPending: false,
            previousCompletedInstallation: nil, bundleIdentifier: "com.kafeifei.xdial",
            requestedInstallation: "com.kafeifei.xdial"
        ))
        XCTAssertFalse(InstallationBuildMarker.shouldPrepareAtLaunch(
            serviceRegistered: false, registrationRecoveryPending: false,
            previousCompletedInstallation: nil, bundleIdentifier: "com.kafeifei.xdial.debug",
            requestedInstallation: "com.kafeifei.xdial"
        ), "another channel's request does not authorize registration")
    }

    func testFreshOrExplicitlyUninstalledApplicationDoesNotRegisterAutomatically() {
        XCTAssertFalse(InstallationBuildMarker.shouldPrepareAtLaunch(
            serviceRegistered: false, registrationRecoveryPending: false,
            previousCompletedInstallation: nil, bundleIdentifier: "com.kafeifei.xdial.app"
        ))
    }

    func testAnotherChannelsInstallationDoesNotAuthorizeRegistration() {
        XCTAssertFalse(InstallationBuildMarker.shouldPrepareAtLaunch(
            serviceRegistered: false, registrationRecoveryPending: false,
            previousCompletedInstallation: "com.kafeifei.xdial.app:79:installation-v4",
            bundleIdentifier: "com.kafeifei.xdial.debug"
        ))
    }

    func testInterruptedRegistrationResumesBeforeFirstCompletedInstallation() {
        XCTAssertTrue(InstallationBuildMarker.shouldPrepareAtLaunch(
            serviceRegistered: false, registrationRecoveryPending: true,
            previousCompletedInstallation: nil, bundleIdentifier: "com.kafeifei.xdial.debug"
        ))
    }

    func testSystemExtensionOnlyVerifiesCurrentEnabledVersion() {
        let expected = SystemExtensionPropertySnapshot(
            bundleIdentifier:
                "com.kafeifei.xdial.transparent-proxy",
            bundleVersion: "79",
            isEnabled: true,
            isAwaitingUserApproval: false,
            isUninstalling: false
        )
        XCTAssertTrue(
            SystemExtensionActivationVerifier
                .containsReadyCurrentVersion(
                    [expected],
                    expectedIdentifier:
                        "com.kafeifei.xdial.transparent-proxy",
                    expectedVersion: "79"
                )
        )
        XCTAssertFalse(
            SystemExtensionActivationVerifier
                .containsReadyCurrentVersion(
                    [
                        SystemExtensionPropertySnapshot(
                            bundleIdentifier:
                                expected.bundleIdentifier,
                            bundleVersion: "78",
                            isEnabled: true,
                            isAwaitingUserApproval: false,
                            isUninstalling: false
                        ),
                    ],
                    expectedIdentifier:
                        expected.bundleIdentifier,
                    expectedVersion: "79"
                )
        )
        XCTAssertFalse(
            SystemExtensionActivationVerifier
                .containsReadyCurrentVersion(
                    [
                        SystemExtensionPropertySnapshot(
                            bundleIdentifier:
                                expected.bundleIdentifier,
                            bundleVersion:
                                expected.bundleVersion,
                            isEnabled: false,
                            isAwaitingUserApproval: false,
                            isUninstalling: false
                        ),
                    ],
                    expectedIdentifier:
                        expected.bundleIdentifier,
                    expectedVersion: expected.bundleVersion
                )
        )
    }

    func testExtensionReadinessNeverInstallsFromConnectionOrVerification() {
        let identifier = "com.kafeifei.xdial.app.transparent-proxy"
        let unavailableSnapshots: [[SystemExtensionPropertySnapshot]] = [
            [],
            [.init(bundleIdentifier: identifier, bundleVersion: "78",
                   isEnabled: true, isAwaitingUserApproval: false,
                   isUninstalling: false)],
            [.init(bundleIdentifier: identifier, bundleVersion: "79",
                   isEnabled: false, isAwaitingUserApproval: false,
                   isUninstalling: false)],
            [.init(bundleIdentifier: identifier, bundleVersion: "79",
                   isEnabled: true, isAwaitingUserApproval: true,
                   isUninstalling: false)],
            [.init(bundleIdentifier: identifier, bundleVersion: "79",
                   isEnabled: true, isAwaitingUserApproval: false,
                   isUninstalling: true)],
        ]
        for properties in unavailableSnapshots {
            for phase in [SystemExtensionActivationVerifier.Phase.connection,
                          .installationCompletion] {
                XCTAssertEqual(SystemExtensionActivationVerifier.action(
                    for: properties, expectedIdentifier: identifier,
                    expectedVersion: "79", phase: phase
                ), .unavailable)
            }
            XCTAssertEqual(SystemExtensionActivationVerifier.action(
                for: properties, expectedIdentifier: identifier,
                expectedVersion: "79", phase: .installationPreflight
            ), .activate)
        }
    }

    func testRepeatedInstallationAcceptsCurrentVersionAlongsideRetiredVersions() {
        let identifier = "com.kafeifei.xdial.app.transparent-proxy"
        let properties: [SystemExtensionPropertySnapshot] = [
            .init(bundleIdentifier: identifier, bundleVersion: "78",
                  isEnabled: false, isAwaitingUserApproval: false,
                  isUninstalling: true),
            .init(bundleIdentifier: identifier, bundleVersion: "79",
                  isEnabled: true, isAwaitingUserApproval: false,
                  isUninstalling: false),
        ]
        for phase in [SystemExtensionActivationVerifier.Phase.connection,
                      .installationPreflight, .installationCompletion] {
            XCTAssertEqual(SystemExtensionActivationVerifier.action(
                for: properties, expectedIdentifier: identifier,
                expectedVersion: "79", phase: phase
            ), .ready)
        }
    }

    func testRelocationAllowsKnownApplicationReplacementForSameTeam() {
        XCTAssertEqual(
            XDialApplicationIdentifierPolicy.permitsReplacement(
                existingIdentifier:
                    XDialApplicationIdentifierPolicy.legacyRelease,
                incomingIdentifier:
                    XDialBuildIdentity.applicationIdentifier,
                teamIdentifiersMatch: true
            ),
            XDialBuildIdentity.allowsFormalDataMigration
        )
        XCTAssertTrue(
            XDialApplicationIdentifierPolicy.permitsReplacement(
                existingIdentifier: XDialBuildIdentity.applicationIdentifier,
                incomingIdentifier: XDialBuildIdentity.applicationIdentifier,
                teamIdentifiersMatch: true
            )
        )
        XCTAssertFalse(
            XDialApplicationIdentifierPolicy.permitsReplacement(
                existingIdentifier:
                    XDialApplicationIdentifierPolicy.release,
                incomingIdentifier:
                    XDialApplicationIdentifierPolicy.legacyProbe,
                teamIdentifiersMatch: true
            )
        )
        XCTAssertFalse(
            XDialApplicationIdentifierPolicy.permitsReplacement(
                existingIdentifier: XDialApplicationIdentifierPolicy.release,
                incomingIdentifier: XDialApplicationIdentifierPolicy.development,
                teamIdentifiersMatch: true
            )
        )
        XCTAssertFalse(
            XDialApplicationIdentifierPolicy.permitsReplacement(
                existingIdentifier: XDialApplicationIdentifierPolicy.development,
                incomingIdentifier: XDialApplicationIdentifierPolicy.release,
                teamIdentifiersMatch: true
            )
        )
    }

    func testOnlyCanonicalApplicationCanBeAnInstallationSource() {
        XCTAssertTrue(
            XDialApplicationIdentifierPolicy
                .permitsIncomingInstallation(
                    identifier: XDialBuildIdentity.applicationIdentifier
                )
        )
        XCTAssertFalse(
            XDialApplicationIdentifierPolicy
                .permitsIncomingInstallation(
                    identifier:
                        XDialApplicationIdentifierPolicy.legacyProbe
                )
        )
        XCTAssertFalse(
            XDialApplicationIdentifierPolicy
                .permitsIncomingInstallation(
                    identifier:
                        XDialApplicationIdentifierPolicy.legacyRelease
                )
        )
    }

    func testCurrentBuildRecognizesOnlyItsObsoleteApplicationIdentities() {
        let expected: Set<String> = XDialBuildIdentity.allowsFormalDataMigration
            ? [
                XDialApplicationIdentifierPolicy.legacyProbe,
                XDialApplicationIdentifierPolicy.legacyRelease,
            ]
            : []
        XCTAssertEqual(
            XDialApplicationIdentifierPolicy.obsoleteIdentifiers(
                forInstalledIdentifier:
                    XDialBuildIdentity.applicationIdentifier
            ),
            expected
        )
        XCTAssertEqual(
            XDialApplicationIdentifierPolicy.obsoleteIdentifiers(
                forInstalledIdentifier:
                    XDialApplicationIdentifierPolicy.legacyProbe
            ),
            []
        )
        XCTAssertEqual(
            XDialApplicationIdentifierPolicy.obsoleteIdentifiers(
                forInstalledIdentifier: "com.example.not-xdial"
            ),
            []
        )
    }

    func testOutgoingCleanupPlansForIdentityOrComponentMigration() throws {
        let existingURL = XDialBuildIdentity.applicationDestinationURL
        XCTAssertEqual(
            OutgoingApplicationCleanup.plan(
                existingBundleURL: existingURL,
                existingIdentifier:
                    XDialApplicationIdentifierPolicy.legacyProbe,
                incomingIdentifier:
                    XDialBuildIdentity.applicationIdentifier,
                teamIdentifiersMatch: true
            ) != nil,
            XDialBuildIdentity.allowsFormalDataMigration
        )
        XCTAssertNil(
            OutgoingApplicationCleanup.plan(
                existingBundleURL: existingURL,
                existingIdentifier: XDialBuildIdentity.applicationIdentifier,
                incomingIdentifier: XDialBuildIdentity.applicationIdentifier,
                teamIdentifiersMatch: true
            )
        )
        let componentPlan = try XCTUnwrap(
            OutgoingApplicationCleanup.plan(
                existingBundleURL: existingURL,
                existingIdentifier: XDialBuildIdentity.applicationIdentifier,
                incomingIdentifier: XDialBuildIdentity.applicationIdentifier,
                teamIdentifiersMatch: true,
                requiresComponentCleanup: true
            )
        )
        XCTAssertEqual(
            componentPlan.executableURL.path,
            existingURL.appendingPathComponent("Contents/MacOS/XDial").path
        )
        XCTAssertEqual(
            componentPlan.arguments,
            [OutgoingApplicationCleanup.replacementArgument]
        )
        XCTAssertEqual(componentPlan.timeout, 5 * 60)
        XCTAssertNil(
            OutgoingApplicationCleanup.plan(
                existingBundleURL: existingURL,
                existingIdentifier:
                    XDialApplicationIdentifierPolicy.legacyProbe,
                incomingIdentifier:
                    XDialBuildIdentity.applicationIdentifier,
                teamIdentifiersMatch: false
            )
        )
    }

    func testOutgoingCleanupRunsExactBoundedOldHostCommand() throws {
        let plan = try XCTUnwrap(
            OutgoingApplicationCleanup.plan(
                existingBundleURL: URL(
                    fileURLWithPath:
                        XDialBuildIdentity.applicationDestinationURL.path,
                    isDirectory: true
                ),
                existingIdentifier:
                    XDialBuildIdentity.applicationIdentifier,
                incomingIdentifier:
                    XDialBuildIdentity.applicationIdentifier,
                teamIdentifiersMatch: true,
                requiresComponentCleanup: true
            )
        )
        var invocation: OutgoingApplicationCleanup.Plan?

        try OutgoingApplicationCleanup.run(plan) {
            executableURL, arguments, timeout in
            invocation = OutgoingApplicationCleanup.Plan(
                executableURL: executableURL,
                arguments: arguments,
                timeout: timeout
            )
            return true
        }

        XCTAssertEqual(invocation, plan)
    }

    func testOutgoingCleanupFailureStopsReplacement() throws {
        let plan = try XCTUnwrap(
            OutgoingApplicationCleanup.plan(
                existingBundleURL: URL(
                    fileURLWithPath:
                        XDialBuildIdentity.applicationDestinationURL.path,
                    isDirectory: true
                ),
                existingIdentifier:
                    XDialBuildIdentity.applicationIdentifier,
                incomingIdentifier:
                    XDialBuildIdentity.applicationIdentifier,
                teamIdentifiersMatch: true,
                requiresComponentCleanup: true
            )
        )

        XCTAssertThrowsError(
            try OutgoingApplicationCleanup.run(plan) {
                _, _, _ in false
            }
        )
    }

    func testInstallationOnlyFinishesWhenEveryTaskIsReady() {
        var report = InstallationReport.fresh(
            applicationAlreadyInstalled: true
        )
        XCTAssertEqual(report.schemaVersion, 4)
        XCTAssertEqual(
            report.tasks.last?.id,
            "system-extension"
        )
        XCTAssertFalse(
            report.tasks.contains {
                $0.id == "system-extension-cleanup"
            }
        )
        report.finish()
        XCTAssertFalse(report.isReady)

        for task in report.tasks {
            report.updateTask(id: task.id, state: .ready)
        }
        report.finish()

        XCTAssertTrue(report.isReady)
        XCTAssertEqual(report.state, .ready)
        XCTAssertEqual(
            report.events.map(\.sequence),
            Array(1 ... report.events.count)
        )
    }

    func testApprovalAndFailureRemainAttachedToExactTask() {
        var report = InstallationReport.fresh(
            applicationAlreadyInstalled: true
        )
        report.updateTask(
            id: "system-extension",
            state: .waitingForApproval
        )
        XCTAssertEqual(report.state, .waitingForApproval)
        XCTAssertEqual(
            report.currentTask?.id,
            "system-extension"
        )

        report.fail(
            code: "extension-not-found",
            message: "找不到网络扩展",
            taskID: "system-extension"
        )
        XCTAssertEqual(report.state, .failed)
        XCTAssertEqual(report.error?.taskID, "system-extension")
        XCTAssertEqual(
            report.tasks.first {
                $0.id == "system-extension"
            }?.state,
            .failed
        )
    }

    func testRelocationPolicyNeverOverwritesDifferentIdentity() {
        XCTAssertEqual(
            ApplicationRelocationDecision.decide(
                currentIsCanonical: false,
                destinationExists: true,
                destinationMatchesIdentity: false
            ),
            .rejectExisting
        )
        XCTAssertEqual(
            ApplicationRelocationDecision.decide(
                currentIsCanonical: false,
                destinationExists: true,
                destinationMatchesIdentity: true
            ),
            .replace
        )
        XCTAssertEqual(
            ApplicationRelocationDecision.decide(
                currentIsCanonical: false,
                destinationExists: false,
                destinationMatchesIdentity: false
            ),
            .install
        )
    }

    func testRelocationRejectsAnOlderBuildOverANewerInstallation() {
        // A stable or same-version package over an installed beta: the newer
        // System Extension would stay active beside the older host.
        for (source, destination) in [
            ("1792000000", "1792000001"),
            ("999", "1000"),
        ] {
            for recognized in [true, false] {
                XCTAssertEqual(
                    ApplicationRelocationDecision.decide(
                        currentIsCanonical: false,
                        destinationExists: true,
                        destinationMatchesIdentity: !recognized,
                        destinationIsRecognizedProduct: recognized,
                        sourceBuild: source,
                        destinationBuild: destination
                    ),
                    .rejectDowngrade,
                    "\(source) over \(destination)"
                )
            }
        }
        for (source, destination) in [
            ("1792000001", "1792000000"),
            ("1000", "999"),
            ("1792000000", "1792000000"),
        ] {
            XCTAssertEqual(
                ApplicationRelocationDecision.decide(
                    currentIsCanonical: false,
                    destinationExists: true,
                    destinationMatchesIdentity: true,
                    sourceBuild: source,
                    destinationBuild: destination
                ),
                .replace,
                "\(source) over \(destination)"
            )
        }
        // An unreadable build is not evidence of a downgrade, a foreign
        // destination stays rejected, and the canonical copy just launches.
        for (source, destination) in [
            ("", "1000"), ("100", nil), ("0100", "1000"), ("abc", "1"),
        ] as [(String, String?)] {
            XCTAssertEqual(
                ApplicationRelocationDecision.decide(
                    currentIsCanonical: false,
                    destinationExists: true,
                    destinationMatchesIdentity: true,
                    sourceBuild: source,
                    destinationBuild: destination
                ),
                .replace,
                "\(source) over \(destination ?? "nil")"
            )
        }
        XCTAssertEqual(
            ApplicationRelocationDecision.decide(
                currentIsCanonical: false,
                destinationExists: true,
                destinationMatchesIdentity: false,
                sourceBuild: "1",
                destinationBuild: "2"
            ),
            .rejectExisting
        )
        XCTAssertEqual(
            ApplicationRelocationDecision.decide(
                currentIsCanonical: true,
                destinationExists: true,
                destinationMatchesIdentity: true,
                sourceBuild: "1",
                destinationBuild: "2"
            ),
            .continueLaunch
        )
        XCTAssertEqual(
            ApplicationRelocationDecision.decide(
                currentIsCanonical: false,
                destinationExists: false,
                destinationMatchesIdentity: false,
                sourceBuild: "1",
                destinationBuild: nil
            ),
            .install
        )
        XCTAssertEqual(BundleBuildNumber.compare("10", "9"), .orderedDescending)
        XCTAssertEqual(BundleBuildNumber.compare("9", "10"), .orderedAscending)
        XCTAssertEqual(BundleBuildNumber.compare("42", "42"), .orderedSame)
        XCTAssertNil(BundleBuildNumber.compare("0", "1"))
        XCTAssertNil(BundleBuildNumber.compare("1.2", "1"))
    }

    func testRelocationReadsBothBuildsFromTheBundles() throws {
        let fixture = try BuildNumberBundleFixture()
        defer { fixture.cleanup() }
        let installed = try fixture.bundle("Installed", build: "1792000001")
        let older = try fixture.bundle("Older", build: "1792000000")
        let newer = try fixture.bundle("Newer", build: "1792000002")
        let unreadable = try fixture.bundle("Unreadable", build: nil)

        for (source, destination, expected) in [
            (older, installed, ApplicationRelocationDecision.rejectDowngrade),
            (newer, installed, .replace),
            (installed, installed, .replace),
            (older, unreadable, .replace),
        ] {
            XCTAssertEqual(
                ApplicationRelocationDecision.decide(
                    currentIsCanonical: false,
                    sourceURL: source,
                    destinationURL: destination,
                    destinationExists: true,
                    destinationMatchesIdentity: true,
                    destinationIsRecognizedProduct: false
                ),
                expected,
                "\(source.lastPathComponent) over "
                    + destination.lastPathComponent
            )
        }

        // The installer repeats the rule under its lock, so --install-only
        // and a racing installer meet the same gate.
        XCTAssertTrue(
            BundleBuildNumber.installationLowersBuild(
                from: older,
                over: installed
            )
        )
        for (source, destination) in [
            (newer, installed),
            (installed, installed),
            (older, unreadable),
            (unreadable, installed),
        ] {
            XCTAssertFalse(
                BundleBuildNumber.installationLowersBuild(
                    from: source,
                    over: destination
                ),
                "\(source.lastPathComponent) over "
                    + destination.lastPathComponent
            )
        }
    }

    func testOlderHostReportsANewerActiveExtensionInsteadOfActivating() {
        let identifier = "com.kafeifei.xdial.app.transparent-proxy"
        func snapshot(
            _ version: String,
            enabled: Bool = true,
            awaitingApproval: Bool = false,
            uninstalling: Bool = false
        ) -> SystemExtensionPropertySnapshot {
            .init(
                bundleIdentifier: identifier,
                bundleVersion: version,
                isEnabled: enabled,
                isAwaitingUserApproval: awaitingApproval,
                isUninstalling: uninstalling
            )
        }
        func action(
            _ properties: [SystemExtensionPropertySnapshot],
            expectedVersion: String = "1792000000",
            phase: SystemExtensionActivationVerifier.Phase
        ) -> SystemExtensionActivationVerifier.Action {
            SystemExtensionActivationVerifier.action(
                for: properties,
                expectedIdentifier: identifier,
                expectedVersion: expectedVersion,
                phase: phase
            )
        }

        // However the older host was installed, Finder included, a newer
        // extension that macOS will not replace is named as such.
        for phase in [
            SystemExtensionActivationVerifier.Phase.installationPreflight,
            .installationCompletion,
            .connection,
        ] {
            XCTAssertEqual(
                action([snapshot("1792000001")], phase: phase),
                .newerActive(bundleVersion: "1792000001")
            )
            XCTAssertEqual(
                action(
                    [
                        snapshot("1792000001", enabled: false),
                        snapshot(
                            "1792000003",
                            enabled: false,
                            awaitingApproval: true
                        ),
                        snapshot("1792000002", uninstalling: true),
                    ],
                    phase: phase
                ),
                .newerActive(bundleVersion: "1792000003")
            )
            XCTAssertEqual(
                action(
                    [snapshot("1792000001"), snapshot("1792000000")],
                    phase: phase
                ),
                .ready
            )
        }
        // A newer build already being uninstalled no longer blocks, and an
        // unreadable bundled build keeps the earlier verdicts.
        let uninstalling = [snapshot("1792000001", enabled: false, uninstalling: true)]
        XCTAssertEqual(
            action(uninstalling, phase: .installationPreflight),
            .activate
        )
        XCTAssertEqual(action(uninstalling, phase: .connection), .unavailable)
        XCTAssertEqual(
            action(
                [snapshot("1792000001")],
                expectedVersion: "unknown",
                phase: .installationPreflight
            ),
            .activate
        )
    }

    func testBundleReplacementKeepsBackupUntilValidationSucceeds()
        throws {
        let fixture = try ReplacementFixture()
        defer { fixture.cleanup() }

        try ApplicationBundleReplacer.replace(
            destinationURL: fixture.destinationURL,
            newBundleURL: fixture.newBundleURL,
            backupName: fixture.backupName
        ) { url in
            try fixture.marker(at: url) == "new"
        }

        XCTAssertEqual(
            try fixture.marker(at: fixture.destinationURL),
            "new"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.backupURL.path
            )
        )
    }

    func testBundleReplacementRestoresBackupAfterValidationFailure()
        throws {
        let fixture = try ReplacementFixture()
        defer { fixture.cleanup() }

        XCTAssertThrowsError(
            try ApplicationBundleReplacer.replace(
                destinationURL: fixture.destinationURL,
                newBundleURL: fixture.newBundleURL,
                backupName: fixture.backupName
            ) { _ in false }
        )

        XCTAssertEqual(
            try fixture.marker(at: fixture.destinationURL),
            "old"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.backupURL.path
            )
        )
    }

    func testBundleInfoReadsReplacementAfterFoundationCachedOldBundle()
        throws {
        let fixture = try BundleInfoReplacementFixture()
        defer { fixture.cleanup() }

        XCTAssertEqual(
            Bundle(url: fixture.destinationURL)?.bundleIdentifier,
            XDialApplicationIdentifierPolicy.legacyProbe
        )

        try ApplicationBundleReplacer.replace(
            destinationURL: fixture.destinationURL,
            newBundleURL: fixture.newBundleURL,
            backupName: fixture.backupName
        ) { url in
            ApplicationBundleInfo.identifier(at: url)
                == XDialApplicationIdentifierPolicy.release
        }

        XCTAssertEqual(
            ApplicationBundleInfo.identifier(at: fixture.destinationURL),
            XDialApplicationIdentifierPolicy.release
        )
    }
}

private final class BuildNumberBundleFixture {
    let rootURL: URL

    init() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "xdial-build-number-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
    }

    func bundle(_ name: String, build: String?) throws -> URL {
        let url = rootURL.appendingPathComponent(
            "\(name)/XDial.app",
            isDirectory: true
        )
        let contentsURL = url.appendingPathComponent(
            "Contents",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: contentsURL,
            withIntermediateDirectories: true
        )
        var info: [String: Any] = [
            "CFBundleIdentifier": XDialApplicationIdentifierPolicy.release,
            "CFBundleShortVersionString": "0.10.0",
        ]
        info["CFBundleVersion"] = build
        try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        ).write(to: contentsURL.appendingPathComponent("Info.plist"))
        return url
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}

private final class BundleInfoReplacementFixture {
    let rootURL: URL
    let destinationURL: URL
    let newBundleURL: URL
    let backupName = ".XDial.bundle-info-backup.app"

    init() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "xdial-bundle-info-\(UUID().uuidString)",
                isDirectory: true
            )
        destinationURL = rootURL.appendingPathComponent(
            "XDial.app",
            isDirectory: true
        )
        newBundleURL = rootURL.appendingPathComponent(
            "New.app",
            isDirectory: true
        )
        try Self.writeBundle(
            at: destinationURL,
            identifier: XDialApplicationIdentifierPolicy.legacyProbe
        )
        try Self.writeBundle(
            at: newBundleURL,
            identifier: XDialApplicationIdentifierPolicy.release
        )
    }

    private static func writeBundle(
        at url: URL,
        identifier: String
    ) throws {
        let contentsURL = url.appendingPathComponent(
            "Contents",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: contentsURL,
            withIntermediateDirectories: true
        )
        let data = try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleIdentifier": identifier,
                "CFBundleName": "XDial",
                "CFBundlePackageType": "APPL",
                "CFBundleVersion": "1",
            ],
            format: .xml,
            options: 0
        )
        try data.write(
            to: contentsURL.appendingPathComponent("Info.plist")
        )
    }

    func cleanup() {
        if FileManager.default.fileExists(atPath: rootURL.path) {
            try? FileManager.default.removeItem(at: rootURL)
        }
    }
}

private final class ReplacementFixture {
    let rootURL: URL
    let destinationURL: URL
    let newBundleURL: URL
    let backupName = ".XDial.backup.app"

    var backupURL: URL {
        rootURL.appendingPathComponent(
            backupName,
            isDirectory: true
        )
    }

    init() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "xdial-replacement-\(UUID().uuidString)",
                isDirectory: true
            )
        destinationURL = rootURL.appendingPathComponent(
            "XDial.fixture",
            isDirectory: true
        )
        newBundleURL = rootURL.appendingPathComponent(
            "new.fixture",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: destinationURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: newBundleURL,
            withIntermediateDirectories: true
        )
        try Data("old".utf8).write(
            to: destinationURL.appendingPathComponent("marker")
        )
        try Data("new".utf8).write(
            to: newBundleURL.appendingPathComponent("marker")
        )
    }

    func marker(at url: URL) throws -> String {
        let data = try Data(
            contentsOf: url.appendingPathComponent("marker")
        )
        return String(decoding: data, as: UTF8.self)
    }

    func cleanup() {
        if FileManager.default.fileExists(atPath: rootURL.path) {
            try? FileManager.default.removeItem(at: rootURL)
        }
    }
}
