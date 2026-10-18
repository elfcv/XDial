import CryptoKit
import XCTest

final class AppUpdateCheckerTests: XCTestCase {
    private let production = AppUpdateFeedConfiguration.production

    func testVersionPolicyAcceptsOnlyCanonicalNewerStableTag() {
        XCTAssertTrue(VersionUpdatePolicy.isNewer(
            latestTag: "v0.8.0",
            than: "0.7.0"
        ))
        XCTAssertFalse(VersionUpdatePolicy.isNewer(
            latestTag: "v0.7",
            than: "0.7.0"
        ))
        for rejected in [
            "1.2.3", "V1.2.3", "v1.2", "v1.2.3.4",
            "v01.2.3", "v1.02.3", "v1.2.03", "v1.2.3-rc.1",
        ] {
            XCTAssertNil(
                VersionUpdatePolicy.stableReleaseVersion(
                    fromTag: rejected
                ),
                rejected
            )
        }
    }

    func testFeedConfigurationUsesOnlySignedProductionOrAcceptanceID()
        throws
    {
        XCTAssertEqual(
            try AppUpdateFeedConfiguration.current(
                infoDictionary: [:]
            ),
            .production
        )
        XCTAssertEqual(
            try AppUpdateFeedConfiguration.current(
                infoDictionary: [
                    AppUpdateFeedConfiguration.acceptanceInfoKey: "",
                ]
            ),
            .production
        )

        let acceptanceID = "pages-Acceptance-42"
        let acceptance = try AppUpdateFeedConfiguration.current(
            infoDictionary: [
                AppUpdateFeedConfiguration.acceptanceInfoKey: acceptanceID,
            ]
        )
        XCTAssertEqual(acceptance.acceptanceID, acceptanceID)
        XCTAssertEqual(
            acceptance.feedURL.absoluteString,
            "https://saymiao.github.io/xdial-updates/acceptance/"
                + acceptanceID + "/stable.json"
        )
        XCTAssertTrue(acceptance.permitsArchiveURL(
            URL(string:
                "https://github.com/saymiao/xdial-updates/releases/download/"
                    + "v0.8.0/XDial-v0.8.0.zip"
            )!,
            tag: "v0.8.0",
            archiveName: "XDial-v0.8.0.zip"
        ))
        XCTAssertFalse(acceptance.permitsArchiveURL(
            productionArchiveURL(tag: "v0.8.0"),
            tag: "v0.8.0",
            archiveName: "XDial-v0.8.0.zip"
        ))

        for rejected: Any in [
            "-leading",
            "contains_underscore",
            "contains/slash",
            String(repeating: "a", count: 81),
            42,
        ] {
            XCTAssertThrowsError(
                try AppUpdateFeedConfiguration.current(
                    infoDictionary: [
                        AppUpdateFeedConfiguration.acceptanceInfoKey:
                            rejected,
                    ]
                ),
                "(rejected)"
            )
        }
        XCTAssertNoThrow(
            try AppUpdateFeedConfiguration.acceptance(
                id: "a" + String(repeating: "-", count: 79)
            )
        )
    }

    func testFeedConfigurationReadsFreshPlistAndRejectsNonStringID()
        throws
    {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "xdial-update-info-\(UUID().uuidString).app",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        try writeInfoPlist([
            AppUpdateFeedConfiguration.acceptanceInfoKey: "acceptance-a",
        ], to: bundleURL)
        XCTAssertEqual(
            try AppUpdateFeedConfiguration.current(at: bundleURL)
                .acceptanceID,
            "acceptance-a"
        )

        try writeInfoPlist([
            AppUpdateFeedConfiguration.acceptanceInfoKey: 42,
        ], to: bundleURL)
        XCTAssertThrowsError(
            try AppUpdateFeedConfiguration.current(at: bundleURL)
        ) { error in
            XCTAssertEqual(
                error as? AppUpdateFeedConfigurationError,
                .invalidAcceptanceID
            )
        }
    }

    func testManifestParserAcceptsExactReleaseAndWithdrawal()
        throws
    {
        let data = manifestData()
        let manifest = try AppUpdateManifestParser.parse(data)
        XCTAssertEqual(manifest.schemaVersion, 1)
        XCTAssertEqual(manifest.revision, 1)
        XCTAssertEqual(manifest.channel, "stable")
        XCTAssertEqual(manifest.release?.version, "0.8.0")
        XCTAssertEqual(manifest.release?.build, "1789130088")
        XCTAssertEqual(
            manifest.release?.releaseNotes,
            "- Pages update"
        )
        XCTAssertNil(
            try AppUpdateManifestParser.parse(
                manifestData(release: nil)
            ).release
        )
    }

    func testManifestParserRejectsUnknownMissingAndInvalidFields()
        throws
    {
        var unknown = try manifestObject()
        unknown["unexpected"] = true
        assertManifestError(.unexpectedFields, data: jsonData(unknown))

        var missing = try manifestObject()
        missing.removeValue(forKey: "generatedAt")
        assertManifestError(.unexpectedFields, data: jsonData(missing))

        var badSchema = try manifestObject()
        badSchema["schemaVersion"] = 2
        assertManifestError(.unsupportedSchema, data: jsonData(badSchema))

        var badRevision = try manifestObject()
        badRevision["revision"] = 0
        assertManifestError(.invalidRevision, data: jsonData(badRevision))

        var badChannel = try manifestObject()
        badChannel["channel"] = "beta"
        assertManifestError(.invalidChannel, data: jsonData(badChannel))

        var badRelease = try manifestObject()
        var release = try XCTUnwrap(
            badRelease["release"] as? [String: Any]
        )
        release.removeValue(forKey: "archiveSHA256")
        badRelease["release"] = release
        assertManifestError(.unexpectedFields, data: jsonData(badRelease))

        XCTAssertThrowsError(
            try AppUpdateManifestParser.parse(
                Data(repeating: 0x20,
                     count: AppUpdateManifestParser.maximumBytes + 1)
            )
        ) { error in
            XCTAssertEqual(error as? AppUpdateManifestError, .tooLarge)
        }
    }

    func testReleaseSelectionValidatesVersionBuildOSNotesURLSizeAndHash()
        throws
    {
        let manifest = try AppUpdateManifestParser.parse(manifestData())
        let candidate = try AppUpdateReleasePolicy.selectCandidate(
            from: try XCTUnwrap(manifest.release),
            generatedAt: manifest.generatedAt,
            configuration: production,
            installed: installed("0.7.0"),
            currentSystemVersion: "15.0"
        )
        XCTAssertEqual(candidate.tag, "v0.8.0")
        XCTAssertEqual(candidate.version, "0.8.0")
        XCTAssertEqual(candidate.build, "1789130088")
        XCTAssertEqual(candidate.minimumSystemVersion, "15.0")
        XCTAssertEqual(candidate.archiveSize, 1234)
        XCTAssertEqual(candidate.archiveSHA256, String(repeating: "a", count: 64))
        XCTAssertEqual(candidate.releaseNotes, "- Pages update")

        let cases: [(AppUpdateReleaseSelectionError, [String: Any])] = [
            (.invalidVersionTag, ["version": "0.8.1"]),
            (.invalidBuild, ["build": "0"]),
            (.invalidMinimumSystemVersion,
             ["minimumSystemVersion": "015.0"]),
            (.releaseNotesMissing, ["releaseNotes": "  \n"]),
            (.archiveSizeInvalid, ["archiveSize": 0]),
            (.archiveSHA256Invalid,
             ["archiveSHA256": String(repeating: "A", count: 64)]),
            (.archiveURLRejected,
             ["archiveURL":
                "https://example.com/XDial-v0.8.0.zip"]),
        ]
        for (expected, changes) in cases {
            let release = try parsedRelease(changes: changes)
            assertSelectionError(expected) {
                _ = try AppUpdateReleasePolicy.selectCandidate(
                    from: release,
                    generatedAt: manifest.generatedAt,
                    configuration: production,
                    installed: installed("0.7.0"),
                    currentSystemVersion: "15.0"
                )
            }
        }
        assertSelectionError(.unsupportedSystemVersion) {
            _ = try AppUpdateReleasePolicy.selectCandidate(
                from: try XCTUnwrap(manifest.release),
                generatedAt: manifest.generatedAt,
                configuration: production,
                installed: installed("0.7.0"),
                currentSystemVersion: "14.7"
            )
        }
        assertSelectionError(.notNewer) {
            _ = try AppUpdateReleasePolicy.selectCandidate(
                from: try XCTUnwrap(manifest.release),
                generatedAt: manifest.generatedAt,
                configuration: production,
                installed: installed("0.8.0"),
                currentSystemVersion: "15.0"
            )
        }
    }

    @MainActor
    func testLookupUsesOnlyPagesFeedAndPersistsValidatedETagCache()
        async throws
    {
        let defaults = try temporaryDefaults()
        let feedURL = production.feedURL
        let firstRecorder = AppUpdateHTTPRecorder(replies: [
            .response(AppUpdateHTTPResult(
                data: manifestData(revision: 4),
                statusCode: 200,
                url: feedURL,
                headers: [
                    "Content-Type": "application/json; charset=utf-8",
                    "ETag": "\"revision-4\"",
                ]
            )),
        ])
        let firstLookup = AppUpdateReleaseLookup(
            configuration: production,
            transport: firstRecorder.transport,
            defaults: defaults
        )
        let checkedAt = Date(timeIntervalSince1970: 1_000)
        let first = try await firstLookup.check(
            installed: installed("0.7.0"),
            currentSystemVersion: "15.0",
            now: checkedAt
        )
        XCTAssertEqual(first.checkedAt, checkedAt)
        XCTAssertEqual(first.revision, 4)
        guard case let .available(candidate) = first.availability else {
            return XCTFail("expected Pages candidate")
        }
        XCTAssertEqual(candidate.version, "0.8.0")
        let firstRequests = await firstRecorder.recordedRequests()
        XCTAssertEqual(firstRequests.map(\.url), [feedURL])
        XCTAssertEqual(
            firstRequests[0].value(forHTTPHeaderField: "Cache-Control"),
            "no-cache, max-age=0"
        )
        XCTAssertEqual(
            firstRequests[0].value(forHTTPHeaderField: "Pragma"),
            "no-cache"
        )
        XCTAssertNil(firstRequests[0].value(
            forHTTPHeaderField: "If-None-Match"
        ))

        let secondRecorder = AppUpdateHTTPRecorder(replies: [
            .response(AppUpdateHTTPResult(
                statusCode: 304,
                url: feedURL
            )),
        ])
        let secondLookup = AppUpdateReleaseLookup(
            configuration: production,
            transport: secondRecorder.transport,
            defaults: defaults
        )
        let second = try await secondLookup.check(
            installed: installed("0.7.0"),
            currentSystemVersion: "15.0",
            now: checkedAt.addingTimeInterval(20)
        )
        XCTAssertEqual(second.availability, first.availability)
        XCTAssertEqual(second.revision, 4)
        let secondRequests = await secondRecorder.recordedRequests()
        XCTAssertEqual(secondRequests.map(\.url), [feedURL])
        XCTAssertEqual(
            secondRequests[0].value(
                forHTTPHeaderField: "If-None-Match"
            ),
            "\"revision-4\""
        )
        let secondCheckedAt = checkedAt.addingTimeInterval(20)
        let persistedCheckedAt = await secondLookup.lastValidatedAt(
            now: secondCheckedAt.addingTimeInterval(1)
        )
        XCTAssertEqual(persistedCheckedAt, secondCheckedAt)
        let checker = makeChecker(
            AppUpdateChannelLookup(
                configuration: production,
                transport: secondRecorder.transport,
                defaults: defaults
            )
        )
        await checker.waitForTasksForTesting()
        XCTAssertEqual(checker.lastCheckedAt, secondCheckedAt)
    }

    func testLookupDistinguishesWithdrawalFromUpToDate() async throws {
        let feedURL = production.feedURL
        let recorder = AppUpdateHTTPRecorder(replies: [
            .response(AppUpdateHTTPResult(
                data: manifestData(release: nil),
                statusCode: 200,
                url: feedURL,
                headers: jsonHeaders(etag: "\"withdrawn\"")
            )),
            .response(AppUpdateHTTPResult(
                data: manifestData(revision: 2),
                statusCode: 200,
                url: feedURL,
                headers: jsonHeaders(etag: "\"available\"")
            )),
        ])
        let defaults = try temporaryDefaults()
        let lookup = AppUpdateReleaseLookup(
            configuration: production,
            transport: recorder.transport,
            defaults: defaults
        )

        let withdrawn = try await lookup.check(
            installed: installed("0.7.0"),
            currentSystemVersion: "15.0",
            now: Date(timeIntervalSince1970: 1_000)
        )
        XCTAssertEqual(withdrawn.availability, .noRelease)

        let upToDate = try await lookup.check(
            installed: installed("0.8.0"),
            currentSystemVersion: "15.0",
            now: Date(timeIntervalSince1970: 1_010)
        )
        XCTAssertEqual(upToDate.availability, .upToDate)
    }

    func testLookupRejectsRedirectOversizeRevisionRollbackAndConflict()
        async throws
    {
        let feedURL = production.feedURL
        let redirected = AppUpdateHTTPRecorder(replies: [
            .response(AppUpdateHTTPResult(
                data: manifestData(),
                statusCode: 200,
                url: URL(string: "https://example.com/stable.json")!,
                headers: jsonHeaders(etag: "\"one\"")
            )),
        ])
        do {
            _ = try await AppUpdateReleaseLookup(
                configuration: production,
                transport: redirected.transport,
                defaults: try temporaryDefaults()
            ).check(
                installed: installed("0.7.0"),
                currentSystemVersion: "15.0"
            )
            XCTFail("redirected manifest accepted")
        } catch let error as AppUpdateReleaseLookupError {
            guard case .responseURLRejected = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        let oversized = AppUpdateHTTPRecorder(replies: [
            .response(AppUpdateHTTPResult(
                data: Data(repeating: 0,
                    count: AppUpdateManifestParser.maximumBytes + 1),
                statusCode: 200,
                url: feedURL
            )),
        ])
        do {
            _ = try await AppUpdateReleaseLookup(
                configuration: production,
                transport: oversized.transport,
                defaults: try temporaryDefaults()
            ).check(
                installed: installed("0.7.0"),
                currentSystemVersion: "15.0"
            )
            XCTFail("oversized manifest accepted")
        } catch let error as AppUpdateReleaseLookupError {
            XCTAssertEqual(error, .responseTooLarge)
        }

        let defaults = try temporaryDefaults()
        let recorder = AppUpdateHTTPRecorder(replies: [
            .response(AppUpdateHTTPResult(
                data: manifestData(revision: 3),
                statusCode: 200,
                url: feedURL,
                headers: jsonHeaders(etag: "\"three\"")
            )),
            .response(AppUpdateHTTPResult(
                data: manifestData(revision: 2),
                statusCode: 200,
                url: feedURL,
                headers: jsonHeaders(etag: "\"two\"")
            )),
        ])
        let lookup = AppUpdateReleaseLookup(
            configuration: production,
            transport: recorder.transport,
            defaults: defaults
        )
        _ = try await lookup.check(
            installed: installed("0.7.0"),
            currentSystemVersion: "15.0",
            now: Date(timeIntervalSince1970: 1_000)
        )
        do {
            _ = try await lookup.check(
                installed: installed("0.7.0"),
                currentSystemVersion: "15.0",
                now: Date(timeIntervalSince1970: 1_010)
            )
            XCTFail("revision rollback accepted")
        } catch let error as AppUpdateReleaseLookupError {
            XCTAssertEqual(
                error,
                .revisionRollback(previous: 3, received: 2)
            )
        }
    }

    func testLookupRejectsSameRevisionWithDifferentRawBytes()
        async throws
    {
        let feedURL = production.feedURL
        let firstData = manifestData(revision: 7)
        var secondData = firstData
        secondData.append(contentsOf: Data("\n".utf8))
        XCTAssertEqual(
            try AppUpdateManifestParser.parse(firstData),
            try AppUpdateManifestParser.parse(secondData)
        )
        let recorder = AppUpdateHTTPRecorder(replies: [
            .response(AppUpdateHTTPResult(
                data: firstData,
                statusCode: 200,
                url: feedURL,
                headers: jsonHeaders(etag: "\"first-seven\"")
            )),
            .response(AppUpdateHTTPResult(
                data: secondData,
                statusCode: 200,
                url: feedURL,
                headers: jsonHeaders(etag: "\"second-seven\"")
            )),
        ])
        let lookup = AppUpdateReleaseLookup(
            configuration: production,
            transport: recorder.transport,
            defaults: try temporaryDefaults()
        )
        _ = try await lookup.check(
            installed: installed("0.7.0"),
            currentSystemVersion: "15.0",
            now: Date(timeIntervalSince1970: 1_000)
        )

        do {
            _ = try await lookup.check(
                installed: installed("0.7.0"),
                currentSystemVersion: "15.0",
                now: Date(timeIntervalSince1970: 1_010)
            )
            XCTFail("same revision with different bytes was accepted")
        } catch let error as AppUpdateReleaseLookupError {
            XCTAssertEqual(error, .revisionConflict(7))
        }
    }

    func testLookupHonorsRetryAfterThenResumesPagesRequest()
        async throws
    {
        let feedURL = production.feedURL
        let now = Date(timeIntervalSince1970: 1_000)
        let recorder = AppUpdateHTTPRecorder(replies: [
            .response(AppUpdateHTTPResult(
                statusCode: 429,
                url: feedURL,
                headers: ["Retry-After": "120"]
            )),
            .response(AppUpdateHTTPResult(
                data: manifestData(),
                statusCode: 200,
                url: feedURL,
                headers: jsonHeaders(etag: "\"one\"")
            )),
        ])
        let defaults = try temporaryDefaults()
        let lookup = AppUpdateReleaseLookup(
            configuration: production,
            transport: recorder.transport,
            defaults: defaults
        )
        do {
            _ = try await lookup.check(
                installed: installed("0.7.0"),
                currentSystemVersion: "15.0",
                now: now
            )
            XCTFail("429 accepted")
        } catch let error as AppUpdateReleaseLookupError {
            XCTAssertEqual(
                error,
                .rateLimited(until: now.addingTimeInterval(120))
            )
        }
        do {
            _ = try await lookup.check(
                installed: installed("0.7.0"),
                currentSystemVersion: "15.0",
                now: now.addingTimeInterval(119)
            )
            XCTFail("cooldown ignored")
        } catch let error as AppUpdateReleaseLookupError {
            XCTAssertEqual(
                error,
                .retryDeferred(until: now.addingTimeInterval(120))
            )
        }
        _ = try await lookup.check(
            installed: installed("0.7.0"),
            currentSystemVersion: "15.0",
            now: now.addingTimeInterval(121)
        )
        let requestCount = await recorder.recordedRequests().count
        XCTAssertEqual(requestCount, 2)
    }

    func testSlowerOldResponseCannotOverwriteNewerRevision()
        async throws
    {
        let feedURL = production.feedURL
        let oldResponse = AppUpdateHTTPResult(
            data: manifestData(revision: 1),
            statusCode: 200,
            url: feedURL,
            headers: jsonHeaders(etag: "\"old\"")
        )
        let newResponse = AppUpdateHTTPResult(
            data: manifestData(
                revision: 2,
                release: [
                    "tag": "v0.8.1",
                    "version": "0.8.1",
                    "archiveURL": productionArchiveURL(
                        tag: "v0.8.1"
                    ).absoluteString,
                ]
            ),
            statusCode: 200,
            url: feedURL,
            headers: jsonHeaders(etag: "\"new\"")
        )
        let transport = AppUpdateReorderingTransport(
            firstResponse: oldResponse,
            secondResponse: newResponse,
            laterResponse: AppUpdateHTTPResult(
                statusCode: 304,
                url: feedURL
            )
        )
        let lookup = AppUpdateReleaseLookup(
            configuration: production,
            transport: transport.transport,
            defaults: try temporaryDefaults()
        )

        let first = Task {
            try await lookup.check(
                installed: installed("0.7.0"),
                currentSystemVersion: "15.0",
                now: Date(timeIntervalSince1970: 1_000)
            )
        }
        await transport.waitUntilFirstRequestStarts()
        let second = try await lookup.check(
            installed: installed("0.7.0"),
            currentSystemVersion: "15.0",
            now: Date(timeIntervalSince1970: 1_001)
        )
        guard case let .available(secondCandidate) = second.availability
        else { return XCTFail("new response was not available") }
        XCTAssertEqual(secondCandidate.version, "0.8.1")

        await transport.releaseFirstResponse()
        do {
            _ = try await first.value
            XCTFail("late old response overwrote the new revision")
        } catch let error as AppUpdateReleaseLookupError {
            XCTAssertEqual(
                error,
                .revisionRollback(previous: 2, received: 1)
            )
        }

        let cached = try await lookup.check(
            installed: installed("0.7.0"),
            currentSystemVersion: "15.0",
            now: Date(timeIntervalSince1970: 1_002)
        )
        guard case let .available(cachedCandidate) = cached.availability
        else { return XCTFail("new cached response was lost") }
        XCTAssertEqual(cached.revision, 2)
        XCTAssertEqual(cachedCandidate.version, "0.8.1")
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(
            requests[2].value(forHTTPHeaderField: "If-None-Match"),
            "\"new\""
        )
    }

    @MainActor
    func testCandidateWithdrawalStopsBeforeDownload() async throws {
        let feedURL = production.feedURL
        let recorder = AppUpdateHTTPRecorder(replies: [
            .response(AppUpdateHTTPResult(
                data: manifestData(revision: 2, release: nil),
                statusCode: 200,
                url: feedURL,
                headers: jsonHeaders(etag: "\"withdrawn-two\"")
            )),
        ])
        let lookup = AppUpdateChannelLookup(
            configuration: production,
            transport: recorder.transport,
            defaults: try temporaryDefaults()
        )
        let candidate = try releaseCandidate()
        let checker = makeChecker(lookup)
        await checker.waitForTasksForTesting()
        checker.configureForTesting(
            candidate: candidate,
            phase: .available
        )

        checker.downloadAndPrepare()
        await checker.waitForTasksForTesting()

        XCTAssertEqual(checker.phase, .failed)
        XCTAssertNil(checker.releaseCandidate)
        XCTAssertEqual(checker.failure?.code, .candidateChanged)
        XCTAssertNotNil(checker.lastCheckedAt)
        let requestCount = await recorder.recordedRequests().count
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(checker.launchAttemptCount, 0)
    }

    @MainActor
    func testInstallFreshnessFailureKeepsStageAndDoesNotLaunch()
        async throws
    {
        let recorder = AppUpdateHTTPRecorder(replies: [
            .failure(.notConnectedToInternet),
        ])
        let lookup = AppUpdateChannelLookup(
            configuration: production,
            transport: recorder.transport,
            defaults: try temporaryDefaults()
        )
        let candidate = try releaseCandidate()
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let staged = StagedAppUpdate(
            rootURL: rootURL,
            applicationURL: rootURL.appendingPathComponent("XDial.app")
        )
        let checker = makeChecker(lookup)
        await checker.waitForTasksForTesting()
        checker.configureForTesting(
            candidate: candidate,
            stagedUpdate: staged,
            phase: .ready
        )

        checker.installPreparedUpdate(reconnectScenarioID: nil)
        await checker.waitForTasksForTesting()

        XCTAssertEqual(checker.phase, .ready)
        XCTAssertEqual(checker.releaseCandidate, candidate)
        XCTAssertEqual(checker.stagedUpdate, staged)
        XCTAssertEqual(checker.failure?.code, .checkUnavailable)
        XCTAssertEqual(checker.launchAttemptCount, 0)
        let requestCount = await recorder.recordedRequests().count
        XCTAssertEqual(requestCount, 1)
    }

    @MainActor
    func testImmediateManualChecksAreCoalesced() async throws {
        let feedURL = production.feedURL
        let recorder = AppUpdateHTTPRecorder(replies: [
            .response(AppUpdateHTTPResult(
                data: manifestData(),
                statusCode: 200,
                url: feedURL,
                headers: jsonHeaders(etag: "\"manual-one\"")
            )),
        ])
        let checker = makeChecker(
            AppUpdateChannelLookup(
                configuration: production,
                transport: recorder.transport,
                defaults: try temporaryDefaults()
            )
        )
        await checker.waitForTasksForTesting()

        await checker.checkNow()
        await checker.checkNow()

        XCTAssertNotNil(checker.lastCheckedAt)
        XCTAssertNil(checker.failure)
        let requestCount = await recorder.recordedRequests().count
        XCTAssertEqual(requestCount, 1)
    }

    func testArchiveIntegrityRequiresExactSizeAndSHA256() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "xdial-update-integrity-\(UUID().uuidString)"
            )
        defer { try? FileManager.default.removeItem(at: url) }
        let data = Data("signed archive".utf8)
        try data.write(to: url)
        let digest = SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()

        XCTAssertNoThrow(
            try AppUpdateArchiveIntegrity.validate(
                fileURL: url,
                expectedSize: Int64(data.count),
                expectedSHA256: digest
            )
        )
        XCTAssertThrowsError(
            try AppUpdateArchiveIntegrity.validate(
                fileURL: url,
                expectedSize: Int64(data.count + 1),
                expectedSHA256: digest
            )
        ) { error in
            guard case AppUpdateDownloadError.archiveSizeMismatch = error
            else { return XCTFail("unexpected error: \(error)") }
        }
        XCTAssertThrowsError(
            try AppUpdateArchiveIntegrity.validate(
                fileURL: url,
                expectedSize: Int64(data.count),
                expectedSHA256: String(repeating: "0", count: 64)
            )
        ) { error in
            guard case AppUpdateDownloadError.archiveIntegrityMismatch = error
            else { return XCTFail("unexpected error: \(error)") }
        }
    }

    private func manifestData(
        revision: Int = 1,
        channel: AppUpdateChannel = .stable,
        release: [String: Any]? = [:]
    ) -> Data {
        jsonData(try! manifestObject(
            revision: revision,
            channel: channel,
            release: release
        ))
    }

    private func installed(
        _ version: String,
        build: String = "1",
        tag: String? = nil
    ) -> InstalledRelease {
        InstalledRelease(
            shortVersion: version,
            build: build,
            releaseTag: tag
        )
    }

    @MainActor
    private func makeChecker(
        _ lookup: AppUpdateChannelLookup,
        installed release: InstalledRelease? = nil,
        preferenceDefaults: UserDefaults? = nil
    ) -> AppUpdateChecker {
        let release = release ?? installed("0.7.0")
        return AppUpdateChecker(
            releaseLookup: lookup,
            automaticUpdatesPermitted: { true },
            installedRelease: { release },
            preferenceDefaults: preferenceDefaults
                ?? (try? temporaryDefaults()) ?? .standard,
            pruneStaleStaging: {}
        )
    }

    private func releaseCandidate() throws -> AppUpdateReleaseCandidate {
        let manifest = try AppUpdateManifestParser.parse(manifestData())
        return try AppUpdateReleasePolicy.selectCandidate(
            from: try XCTUnwrap(manifest.release),
            generatedAt: manifest.generatedAt,
            configuration: production,
            installed: installed("0.7.0"),
            currentSystemVersion: "15.0"
        )
    }

    private func manifestObject(
        revision: Int = 1,
        channel: AppUpdateChannel = .stable,
        release: [String: Any]? = [:]
    ) throws -> [String: Any] {
        [
            "schemaVersion": 1,
            "revision": revision,
            "channel": channel.rawValue,
            "generatedAt": "1970-01-01T00:15:00Z",
            "release": release == nil
                ? NSNull()
                : releaseObject(changes: release ?? [:]),
        ]
    }

    private func releaseObject(
        changes: [String: Any] = [:]
    ) -> [String: Any] {
        var release: [String: Any] = [
            "tag": "v0.8.0",
            "version": "0.8.0",
            "build": "1789130088",
            "minimumSystemVersion": "15.0",
            "publishedAt": "1970-01-01T00:13:20Z",
            "releaseNotes": "- Pages update",
            "archiveURL": productionArchiveURL(
                tag: "v0.8.0"
            ).absoluteString,
            "archiveSize": 1234,
            "archiveSHA256": String(repeating: "a", count: 64),
        ]
        for (key, value) in changes { release[key] = value }
        return release
    }

    private func parsedRelease(
        changes: [String: Any]
    ) throws -> AppUpdateFeedRelease {
        let object = try manifestObject(release: changes)
        return try XCTUnwrap(
            AppUpdateManifestParser.parse(
                jsonData(object)
            ).release
        )
    }

    private func productionArchiveURL(tag: String) -> URL {
        URL(string:
            "https://github.com/kafeifei/XDial/releases/download/"
                + "\(tag)/XDial-\(tag).zip"
        )!
    }

    private func jsonHeaders(etag: String) -> [String: String] {
        ["Content-Type": "application/json", "ETag": etag]
    }

    private func jsonData(_ object: Any) -> Data {
        try! JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
    }

    private func writeInfoPlist(
        _ dictionary: [String: Any],
        to bundleURL: URL
    ) throws {
        let contentsURL = bundleURL.appendingPathComponent(
            "Contents",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: contentsURL,
            withIntermediateDirectories: true
        )
        let data = try PropertyListSerialization.data(
            fromPropertyList: dictionary,
            format: .xml,
            options: 0
        )
        try data.write(
            to: contentsURL.appendingPathComponent("Info.plist"),
            options: .atomic
        )
    }

    private func temporaryDefaults() throws -> UserDefaults {
        let suiteName = "xdial-update-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }

    private func assertManifestError(
        _ expected: AppUpdateManifestError,
        data: Data,
        expectedChannel: AppUpdateChannel = .stable,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try AppUpdateManifestParser.parse(
                data,
                expectedChannel: expectedChannel
            ),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                error as? AppUpdateManifestError,
                expected,
                file: file,
                line: line
            )
        }
    }

    private func assertSelectionError(
        _ expected: AppUpdateReleaseSelectionError,
        operation: () throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try operation(),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                error as? AppUpdateReleaseSelectionError,
                expected,
                file: file,
                line: line
            )
        }
    }
    func testArchivePolicyBoundsAndExactRootShape() {
        XCTAssertFalse(
            AppUpdateArchivePolicy.permitsArchiveByteCount(0)
        )
        XCTAssertTrue(
            AppUpdateArchivePolicy.permitsArchiveByteCount(
                AppUpdateArchivePolicy.maximumArchiveBytes
            )
        )
        XCTAssertFalse(
            AppUpdateArchivePolicy.permitsArchiveByteCount(
                AppUpdateArchivePolicy.maximumArchiveBytes + 1
            )
        )
        XCTAssertTrue(
            AppUpdateArchivePolicy.containsExactlyOneRootApplication(
                [XDialBuildIdentity.applicationBundleName]
            )
        )
        XCTAssertFalse(
            AppUpdateArchivePolicy.containsExactlyOneRootApplication(
                ["README.md", XDialBuildIdentity.applicationBundleName]
            )
        )
    }

    func testAutomaticUpdateBundleMatchesIdentityTeamChannelVersionAndBuild() {
        XCTAssertTrue(
            AutomaticUpdateBundlePolicy.permitsAcceptanceTransition(
                currentAcceptanceID: nil,
                incomingAcceptanceID: nil
            )
        )
        XCTAssertTrue(
            AutomaticUpdateBundlePolicy.permitsAcceptanceTransition(
                currentAcceptanceID: "acceptance-a",
                incomingAcceptanceID: "acceptance-a"
            )
        )
        XCTAssertFalse(
            AutomaticUpdateBundlePolicy.permitsAcceptanceTransition(
                currentAcceptanceID: nil,
                incomingAcceptanceID: "acceptance-a"
            )
        )
        XCTAssertFalse(
            AutomaticUpdateBundlePolicy.permitsAcceptanceTransition(
                currentAcceptanceID: "acceptance-a",
                incomingAcceptanceID: "acceptance-b"
            )
        )
        XCTAssertEqual(
            AutomaticUpdateBundlePolicy.permits(
                currentIdentifier: XDialBuildIdentity.applicationIdentifier,
                currentTeamIdentifier: "TEAM",
                currentAcceptanceID: "acceptance-a",
                incomingIdentifier: XDialBuildIdentity.applicationIdentifier,
                incomingTeamIdentifier: "TEAM",
                incomingAcceptanceID: "acceptance-a",
                incomingVersion: "0.8.0",
                expectedVersion: "0.8.0",
                incomingBuild: "100",
                expectedBuild: "100"
            ),
            XDialBuildIdentity.allowsAutomaticUpdates
        )
        XCTAssertFalse(
            AutomaticUpdateBundlePolicy.permits(
                currentIdentifier: XDialBuildIdentity.applicationIdentifier,
                currentTeamIdentifier: "TEAM",
                currentAcceptanceID: "acceptance-a",
                incomingIdentifier: XDialBuildIdentity.applicationIdentifier,
                incomingTeamIdentifier: "TEAM",
                incomingAcceptanceID: "acceptance-b",
                incomingVersion: "0.8.0",
                expectedVersion: "0.8.0",
                incomingBuild: "100",
                expectedBuild: "100"
            )
        )
        XCTAssertFalse(
            AutomaticUpdateBundlePolicy.permits(
                currentIdentifier: XDialApplicationIdentifierPolicy.release,
                currentTeamIdentifier: "TEAM-A",
                currentAcceptanceID: nil,
                incomingIdentifier: XDialApplicationIdentifierPolicy.release,
                incomingTeamIdentifier: "TEAM-B",
                incomingAcceptanceID: nil,
                incomingVersion: "0.8.0",
                expectedVersion: "0.8.0",
                incomingBuild: "100",
                expectedBuild: "100"
            )
        )
        XCTAssertFalse(
            AutomaticUpdateBundlePolicy.permits(
                currentIdentifier: XDialApplicationIdentifierPolicy.release,
                currentTeamIdentifier: "TEAM",
                currentAcceptanceID: nil,
                incomingIdentifier: XDialApplicationIdentifierPolicy.release,
                incomingTeamIdentifier: "TEAM",
                incomingAcceptanceID: nil,
                incomingVersion: "0.8.0",
                expectedVersion: "0.8.0",
                incomingBuild: "101",
                expectedBuild: "100"
            )
        )
        XCTAssertTrue(
            AutomaticUpdateBundlePolicy.permitsVersionSet(
                expectedVersion: "0.8.0",
                expectedBuild: "100",
                hostVersion: "0.8.0",
                hostBuild: "100",
                settingsVersion: "0.8.0",
                settingsBuild: "100",
                extensionVersion: "0.8.0",
                extensionBuild: "100"
            )
        )
        XCTAssertFalse(
            AutomaticUpdateBundlePolicy.permitsVersionSet(
                expectedVersion: "0.8.0",
                expectedBuild: "100",
                hostVersion: "0.8.0",
                hostBuild: "100",
                settingsVersion: "0.7.0",
                settingsBuild: "100",
                extensionVersion: "0.8.0",
                extensionBuild: "101"
            )
        )
    }

    func testDownloadPolicyAllowsOnlyGitHubReleaseAssetRedirect() {
        XCTAssertTrue(
            AppUpdateDownloadPolicy.permitsRedirect(
                to: URL(
                    string: "https://release-assets.githubusercontent.com/github-production-release-asset/1/file?token=signed"
                )!
            )
        )
        for rejected in [
            "http://release-assets.githubusercontent.com/file",
            "https://github.com/kafeifei/XDial/file",
            "https://objects.githubusercontent.com/file",
            "https://release-assets.githubusercontent.com:444/file",
            "https://user@release-assets.githubusercontent.com/file",
        ] {
            XCTAssertFalse(
                AppUpdateDownloadPolicy.permitsRedirect(
                    to: URL(string: rejected)!
                ),
                rejected
            )
        }
    }

    func testDownloadResponseRequiresSuccessAndBoundedLength() {
        XCTAssertTrue(
            AppUpdateDownloadPolicy.permitsResponse(
                statusCode: 200,
                expectedByteCount: NSURLSessionTransferSizeUnknown
            )
        )
        XCTAssertTrue(
            AppUpdateDownloadPolicy.permitsResponse(
                statusCode: 200,
                expectedByteCount: 4_000_000
            )
        )
        XCTAssertFalse(
            AppUpdateDownloadPolicy.permitsResponse(
                statusCode: 302,
                expectedByteCount: 0
            )
        )
        XCTAssertTrue(
            AppUpdateDownloadPolicy.permitsProgress(
                totalBytesWritten: 4_000_000,
                totalBytesExpectedToWrite:
                    NSURLSessionTransferSizeUnknown
            )
        )
        XCTAssertFalse(
            AppUpdateDownloadPolicy.permitsProgress(
                totalBytesWritten:
                    AppUpdateArchivePolicy.maximumArchiveBytes + 1,
                totalBytesExpectedToWrite:
                    NSURLSessionTransferSizeUnknown
            )
        )
        XCTAssertFalse(
            AppUpdateDownloadPolicy.permitsProgress(
                totalBytesWritten: 1,
                totalBytesExpectedToWrite:
                    AppUpdateArchivePolicy.maximumArchiveBytes + 1
            )
        )
        XCTAssertFalse(
            AppUpdateDownloadPolicy.permitsResponse(
                statusCode: 200,
                expectedByteCount:
                    AppUpdateArchivePolicy.maximumArchiveBytes + 1
            )
        )
    }

    func testStagesExactRootApplicationAndDiscardsOwnedRoot() throws {
        let fixture = try AppUpdateArchiveFixture(
            rootEntries: [XDialBuildIdentity.applicationBundleName]
        )
        defer { fixture.cleanup() }

        let staged = try AppUpdateStager.stageArchive(
            at: fixture.archiveURL,
            fileManager: fixture.fileManager
        ) { applicationURL in
            XCTAssertEqual(
                applicationURL.lastPathComponent,
                XDialBuildIdentity.applicationBundleName
            )
            XCTAssertEqual(
                try String(
                    contentsOf: applicationURL.appendingPathComponent(
                        "marker"
                    ),
                    encoding: .utf8
                ),
                "signed-fixture"
            )
        }

        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: staged.applicationURL.path
            )
        )
        XCTAssertTrue(
            AppUpdateStager.isOwnedStagedApplication(
                staged.applicationURL,
                fileManager: fixture.fileManager
            )
        )
        AppUpdateStager.discard(
            staged,
            fileManager: fixture.fileManager
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: staged.rootURL.path)
        )
    }

    func testAmbiguousArchiveAndValidationFailureCleanOwnedRoot() throws {
        let ambiguous = try AppUpdateArchiveFixture(
            rootEntries: [
                XDialBuildIdentity.applicationBundleName,
                "README.md",
            ]
        )
        XCTAssertThrowsError(
            try AppUpdateStager.stageArchive(
                at: ambiguous.archiveURL,
                fileManager: ambiguous.fileManager
            ) {
                _ in XCTFail("ambiguous archive reached validation")
            }
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: ambiguous.stagingRoot.path)
        )
        ambiguous.cleanup()

        let rejected = try AppUpdateArchiveFixture(
            rootEntries: [XDialBuildIdentity.applicationBundleName]
        )
        struct ValidationFailure: Error {}
        XCTAssertThrowsError(
            try AppUpdateStager.stageArchive(
                at: rejected.archiveURL,
                fileManager: rejected.fileManager
            ) {
                _ in throw ValidationFailure()
            }
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: rejected.stagingRoot.path)
        )
        rejected.cleanup()
    }

    func testRelaunchIntentRestoresConnectionOrDisconnectionOnce() throws {
        let suiteName = "xdial-update-intent-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: suiteName)
        )
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let now = Date(timeIntervalSince1970: 1000)

        try AppUpdateRelaunchIntentStore.write(
            targetVersion: "0.8.0",
            targetBuild: "100",
            reconnectScenarioID: "scenario-office",
            now: now,
            defaults: defaults
        )
        XCTAssertEqual(
            AppUpdateRelaunchIntentStore.loadDecision(
                currentVersion: "0.8.0",
                currentBuild: "100",
                activeScenarioID: "scenario-office",
                now: now.addingTimeInterval(10),
                defaults: defaults
            ),
            .reconnect(scenarioID: "scenario-office")
        )
        AppUpdateRelaunchIntentStore.clear(defaults: defaults)
        XCTAssertNil(
            AppUpdateRelaunchIntentStore.loadDecision(
                currentVersion: "0.8.0",
                currentBuild: "100",
                activeScenarioID: "scenario-office",
                now: now,
                defaults: defaults
            )
        )

        try AppUpdateRelaunchIntentStore.write(
            targetVersion: "0.8.0",
            targetBuild: "100",
            reconnectScenarioID: nil,
            now: now,
            defaults: defaults
        )
        XCTAssertEqual(
            AppUpdateRelaunchIntentStore.loadDecision(
                currentVersion: "0.8.0",
                currentBuild: "100",
                activeScenarioID: "scenario-office",
                now: now,
                defaults: defaults
            ),
            .stayDisconnected
        )
    }

    func testRelaunchIntentRejectsWrongVersionScenarioAndExpiredState()
        throws
    {
        let suiteName = "xdial-update-intent-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: suiteName)
        )
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let now = Date(timeIntervalSince1970: 1000)

        for (version, build, scenario, age) in [
            ("0.8.1", "100", "scenario-office", 10.0),
            ("0.8.0", "101", "scenario-office", 10.0),
            ("0.8.0", "100", "scenario-home", 10.0),
            (
                "0.8.0",
                "100",
                "scenario-office",
                AppUpdateRelaunchIntentPolicy.maximumAge + 1
            ),
        ] {
            try AppUpdateRelaunchIntentStore.write(
                targetVersion: "0.8.0",
                targetBuild: "100",
                reconnectScenarioID: "scenario-office",
                now: now,
                defaults: defaults
            )
            XCTAssertNil(
                AppUpdateRelaunchIntentStore.loadDecision(
                    currentVersion: version,
                    currentBuild: build,
                    activeScenarioID: scenario,
                    now: now.addingTimeInterval(age),
                    defaults: defaults
                )
            )
        }
    }

    func testStagedSuccessorCanRemoveOnlyItsOwnedUpdateRoot() throws {
        let fixture = try AppUpdateArchiveFixture(
            rootEntries: [XDialBuildIdentity.applicationBundleName]
        )
        defer { fixture.cleanup() }
        let staged = try AppUpdateStager.stageArchive(
            at: fixture.archiveURL,
            fileManager: fixture.fileManager
        ) { _ in }

        AppUpdateStager.discardOwnedRoot(
            containing: staged.applicationURL,
            fileManager: fixture.fileManager
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: staged.rootURL.path)
        )

        let unrelated = fixture.sourceRoot.appendingPathComponent(
            XDialBuildIdentity.applicationBundleName,
            isDirectory: true
        )
        AppUpdateStager.discardOwnedRoot(
            containing: unrelated,
            fileManager: fixture.fileManager
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fixture.sourceRoot.path)
        )
    }

    func testStaleStagingCleanupRemovesOnlyOldOwnedUUIDRoots() throws {
        let fileManager = AppUpdateTemporaryFileManager()
        let now = Date(timeIntervalSince1970: 2_000_000)
        let staleRoot = try AppUpdateStager.makeStagingRoot(
            fileManager: fileManager
        )
        let freshRoot = try AppUpdateStager.makeStagingRoot(
            fileManager: fileManager
        )
        let unknownRoot = staleRoot.deletingLastPathComponent()
            .appendingPathComponent(
                "preserve-(UUID().uuidString)",
                isDirectory: true
            )
        defer {
            for url in [staleRoot, freshRoot, unknownRoot]
            where fileManager.fileExists(atPath: url.path) {
                try? fileManager.removeItem(at: url)
            }
        }
        try fileManager.createDirectory(
            at: unknownRoot,
            withIntermediateDirectories: false
        )
        let oldDate = now.addingTimeInterval(
            -AppUpdateStager.staleRootMaximumAge - 1
        )
        for url in [staleRoot, unknownRoot] {
            try fileManager.setAttributes(
                [.modificationDate: oldDate],
                ofItemAtPath: url.path
            )
        }
        try fileManager.setAttributes(
            [.modificationDate: now],
            ofItemAtPath: freshRoot.path
        )

        AppUpdateStager.pruneStaleRoots(
            now: now,
            fileManager: fileManager
        )

        XCTAssertFalse(fileManager.fileExists(atPath: staleRoot.path))
        XCTAssertTrue(fileManager.fileExists(atPath: freshRoot.path))
        XCTAssertTrue(fileManager.fileExists(atPath: unknownRoot.path))
    }

    func testStagedSuccessorRequiresFreshMatchingVersionIntent() throws {
        let suiteName = "xdial-update-successor-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: suiteName)
        )
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let now = Date(timeIntervalSince1970: 1000)

        try AppUpdateRelaunchIntentStore.write(
            targetVersion: "0.8.0",
            targetBuild: "100",
            reconnectScenarioID: nil,
            now: now,
            defaults: defaults
        )
        XCTAssertTrue(
            AppUpdateRelaunchIntentStore.permitsStagedSuccessor(
                targetVersion: "0.8.0",
                targetBuild: "100",
                now: now.addingTimeInterval(10),
                defaults: defaults
            )
        )
        XCTAssertFalse(
            AppUpdateRelaunchIntentStore.permitsStagedSuccessor(
                targetVersion: "0.8.1",
                targetBuild: "100",
                now: now.addingTimeInterval(10),
                defaults: defaults
            )
        )
        XCTAssertFalse(
            AppUpdateRelaunchIntentStore.permitsStagedSuccessor(
                targetVersion: "0.8.0",
                targetBuild: "100",
                now: now.addingTimeInterval(10),
                defaults: defaults
            )
        )

        // Schema 2 binds the build: a beta and its stable release share X.Y.Z.
        try AppUpdateRelaunchIntentStore.write(
            targetVersion: "0.8.0",
            targetBuild: "100",
            reconnectScenarioID: nil,
            now: now,
            defaults: defaults
        )
        XCTAssertFalse(
            AppUpdateRelaunchIntentStore.permitsStagedSuccessor(
                targetVersion: "0.8.0",
                targetBuild: "99",
                now: now.addingTimeInterval(10),
                defaults: defaults
            )
        )
    }

    // MARK: - Release channels

    func testReleaseTagAcceptsOnlyStrictTagsAndOrdersBySemVer() {
        for accepted in [
            "v0.0.0", "v1.2.3", "v10.20.30",
            "v1.4.0-beta.1", "v1.4.0-beta.12",
        ] {
            XCTAssertEqual(
                ReleaseTag(accepted)?.description,
                accepted,
                accepted
            )
        }
        for rejected in [
            "", "1.2.3", "V1.2.3", "v1.2", "v1.2.3.4", "v01.2.3",
            "v1.02.3", "v1.2.03", "v1.2.3-rc.1", "v1.2.3-beta.0",
            "v1.2.3-beta.01", "v1.2.3-beta", "v1.2.3-beta.",
            "v1.2.3-Beta.1", "v1.2.3-beta.1.2", "v1.2.3-",
            "v1.2.3+1", "v1.2.3 ", " v1.2.3", "v1.2.3-beta.-1",
            "v99999999999999999999.0.0", "v\u{FF11}.2.3",
        ] {
            XCTAssertNil(ReleaseTag(rejected), rejected)
        }
        let ordered = [
            "v0.9.6", "v0.10.0-beta.1", "v0.10.0-beta.2",
            "v0.10.0-beta.10", "v0.10.0", "v0.10.1-beta.1",
            "v0.10.1", "v1.0.0",
        ].compactMap(ReleaseTag.init)
        XCTAssertEqual(ordered.count, 8)
        XCTAssertEqual(ordered.sorted(), ordered)
        for (index, tag) in ordered.enumerated() {
            for later in ordered[(index + 1)...] {
                XCTAssertLessThan(tag, later)
                XCTAssertFalse(later < tag)
            }
        }
        XCTAssertEqual(ReleaseTag("v0.10.0-beta.3")?.version, "0.10.0")
        XCTAssertEqual(ReleaseTag("v0.10.0-beta.3")?.isBeta, true)
        XCTAssertEqual(ReleaseTag("v0.10.0")?.isBeta, false)
    }

    func testStableFeedURLCacheKeyAndNamespaceAreFrozen() async throws {
        XCTAssertEqual(
            production.feedURL.absoluteString,
            "https://saymiao.github.io/xdial-updates/stable.json"
        )
        XCTAssertEqual(production.cacheNamespace, "production")
        XCTAssertEqual(production.channel, .stable)
        XCTAssertNil(production.acceptanceID)
        XCTAssertEqual(production.archiveOwner, "kafeifei")
        XCTAssertEqual(production.archiveRepository, "XDial")
        XCTAssertEqual(production.configuration(for: .stable), production)

        let beta = production.configuration(for: .beta)
        XCTAssertEqual(beta, .productionBeta)
        XCTAssertEqual(
            beta.feedURL.absoluteString,
            "https://saymiao.github.io/xdial-updates/beta.json"
        )
        XCTAssertEqual(beta.cacheNamespace, "production-beta")
        XCTAssertEqual(beta.archiveOwner, "kafeifei")
        XCTAssertEqual(beta.archiveRepository, "XDial")
        XCTAssertEqual(beta.configuration(for: .stable), production)

        let acceptance = try AppUpdateFeedConfiguration.acceptance(
            id: "pages-a"
        )
        XCTAssertEqual(
            acceptance.feedURL.absoluteString,
            "https://saymiao.github.io/xdial-updates/acceptance/"
                + "pages-a/stable.json"
        )
        XCTAssertEqual(acceptance.cacheNamespace, "acceptance-pages-a")
        let acceptanceBeta = acceptance.configuration(for: .beta)
        XCTAssertEqual(
            acceptanceBeta.feedURL.absoluteString,
            "https://saymiao.github.io/xdial-updates/acceptance/"
                + "pages-a/beta.json"
        )
        XCTAssertEqual(acceptanceBeta.acceptanceID, "pages-a")
        XCTAssertEqual(acceptanceBeta.archiveOwner, "saymiao")
        XCTAssertEqual(
            acceptanceBeta.cacheNamespace,
            "acceptance-pages-a.beta"
        )
        XCTAssertNotEqual(
            acceptanceBeta.cacheNamespace,
            try AppUpdateFeedConfiguration.acceptance(id: "pages-a-beta")
                .cacheNamespace
        )

        let defaults = try temporaryDefaults()
        let router = AppUpdateFeedRouter([
            production.feedURL: [
                feedReply(production, revision: 3, release: nil),
            ],
            AppUpdateFeedConfiguration.productionBeta.feedURL: [
                feedReply(.productionBeta, revision: 1, release: nil),
            ],
        ])
        _ = try await AppUpdateChannelLookup(
            configuration: production,
            transport: router.transport,
            defaults: defaults
        ).check(
            installed: installed("0.9.6"),
            receivesBeta: true,
            currentSystemVersion: "15.0",
            now: Date(timeIntervalSince1970: 1_000)
        )
        let stableRecord = try XCTUnwrap(
            defaults.data(forKey: "xdial.update.pages-cache.production")
        )
        let stableObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: stableRecord)
                as? [String: Any]
        )
        XCTAssertEqual(
            Set(stableObject.keys),
            ["endpoint", "etag", "manifestData", "validatedAt"]
        )
        XCTAssertEqual(
            stableObject["endpoint"] as? String,
            "https://saymiao.github.io/xdial-updates/stable.json"
        )
        XCTAssertNotNil(
            defaults.data(forKey: "xdial.update.pages-cache.production-beta")
        )
    }

    func testTagOrderingMatchesReleasedComparisonForStableVersions() {
        let numbers = [0, 1, 2, 10]
        let versions = numbers.flatMap { major in
            numbers.flatMap { minor in
                numbers.map { "\(major).\(minor).\($0)" }
            }
        }
        for current in versions {
            let release = installed(current, build: "1789130088")
            for candidate in versions {
                let tag = "v\(candidate)"
                let expected = VersionUpdatePolicy.isNewer(
                    latestTag: tag,
                    than: current
                )
                do {
                    _ = try AppUpdateReleasePolicy.selectCandidate(
                        from: feedRelease(
                            tag: tag,
                            build: "1789130089"
                        ),
                        generatedAt: Date(timeIntervalSince1970: 900),
                        configuration: production,
                        installed: release,
                        currentSystemVersion: "15.0"
                    )
                    XCTAssertTrue(expected, "\(current) -> \(tag)")
                } catch {
                    XCTAssertFalse(expected, "\(current) -> \(tag)")
                    XCTAssertEqual(
                        error as? AppUpdateReleaseSelectionError,
                        .notNewer,
                        "\(current) -> \(tag)"
                    )
                }
            }
        }
    }

    func testEachFeedAcceptsOnlyItsOwnTagForm() throws {
        let beta = AppUpdateFeedConfiguration.productionBeta
        let selected = try AppUpdateReleasePolicy.selectCandidate(
            from: feedRelease(tag: "v0.10.0-beta.1", build: "300"),
            generatedAt: Date(timeIntervalSince1970: 900),
            configuration: beta,
            installed: installed("0.9.6", build: "200"),
            currentSystemVersion: "15.0"
        )
        XCTAssertEqual(selected.channel, .beta)
        XCTAssertEqual(selected.tag, "v0.10.0-beta.1")
        XCTAssertEqual(selected.version, "0.10.0")
        XCTAssertEqual(
            selected.archiveName,
            "XDial-v0.10.0-beta.1.zip"
        )

        for (configuration, tag) in [
            (production, "v0.10.0-beta.1"),
            (beta, "v0.10.0"),
            (beta, "v0.10.0-beta.0"),
            (beta, "v0.10.0-rc.1"),
        ] {
            assertSelectionError(.invalidVersionTag) {
                _ = try AppUpdateReleasePolicy.selectCandidate(
                    from: self.feedRelease(tag: tag, build: "300"),
                    generatedAt: Date(timeIntervalSince1970: 900),
                    configuration: configuration,
                    installed: self.installed("0.9.6", build: "200"),
                    currentSystemVersion: "15.0"
                )
            }
        }
        assertSelectionError(.invalidVersionTag) {
            _ = try AppUpdateReleasePolicy.selectCandidate(
                from: self.feedRelease(
                    tag: "v0.10.0-beta.1",
                    version: "0.10.1",
                    build: "300"
                ),
                generatedAt: Date(timeIntervalSince1970: 900),
                configuration: beta,
                installed: self.installed("0.9.6", build: "200"),
                currentSystemVersion: "15.0"
            )
        }

        XCTAssertEqual(
            try AppUpdateManifestParser.parse(
                manifestData(channel: .beta),
                expectedChannel: .beta
            ).channel,
            "beta"
        )
        assertManifestError(
            .invalidChannel,
            data: manifestData(channel: .stable),
            expectedChannel: .beta
        )
    }

    @MainActor
    func testReversedBuildIsReportedAsBuildNotNewer() async throws {
        for build in ["400", "500"] {
            assertSelectionError(.buildNotNewer) {
                _ = try AppUpdateReleasePolicy.selectCandidate(
                    from: self.feedRelease(tag: "v0.9.7", build: build),
                    generatedAt: Date(timeIntervalSince1970: 900),
                    configuration: self.production,
                    installed: self.installed("0.9.6", build: "500"),
                    currentSystemVersion: "15.0"
                )
            }
        }
        // An older tag stays "up to date" whatever its build.
        assertSelectionError(.notNewer) {
            _ = try AppUpdateReleasePolicy.selectCandidate(
                from: self.feedRelease(tag: "v0.9.5", build: "900"),
                generatedAt: Date(timeIntervalSince1970: 900),
                configuration: self.production,
                installed: self.installed("0.9.6", build: "500"),
                currentSystemVersion: "15.0"
            )
        }

        let router = AppUpdateFeedRouter([
            production.feedURL: [
                feedReply(
                    production,
                    revision: 2,
                    release: release(tag: "v0.9.7", build: "400")
                ),
            ],
        ])
        let checker = makeChecker(
            AppUpdateChannelLookup(
                configuration: production,
                transport: router.transport,
                defaults: try temporaryDefaults()
            ),
            installed: installed("0.9.6", build: "500")
        )
        await checker.waitForTasksForTesting()
        await checker.checkNow()

        XCTAssertEqual(checker.phase, .failed)
        XCTAssertNil(checker.releaseCandidate)
        XCTAssertEqual(checker.failure?.code, .buildNotNewer)
        XCTAssertEqual(
            checker.lastBuildNotNewer?.detail,
            AppUpdateBuildNotNewer(
                channel: .stable,
                tag: "v0.9.7",
                build: "400",
                installedBuild: "500"
            )
        )
        XCTAssertNotNil(checker.lastCheckedAt)
    }

    @MainActor
    func testPreferenceOffRequestsOnlyStableFeed() async throws {
        let defaults = try temporaryDefaults()
        let router = AppUpdateFeedRouter([
            production.feedURL: [
                feedReply(production, revision: 1),
                feedReply(production, revision: 1),
            ],
            AppUpdateFeedConfiguration.productionBeta.feedURL: [
                feedReply(
                    .productionBeta,
                    revision: 1,
                    release: release(tag: "v0.9.0-beta.1", build: "1789130089")
                ),
            ],
        ])
        let preferences = try temporaryDefaults()
        XCTAssertFalse(
            AppUpdateChannelPreference.receivesBeta(defaults: preferences)
        )
        preferences.set("stable", forKey: AppUpdateChannelPreference.key)
        XCTAssertFalse(
            AppUpdateChannelPreference.receivesBeta(defaults: preferences)
        )
        let checker = makeChecker(
            AppUpdateChannelLookup(
                configuration: production,
                transport: router.transport,
                defaults: defaults
            ),
            preferenceDefaults: preferences
        )
        await checker.waitForTasksForTesting()
        XCTAssertFalse(checker.receivesBetaUpdates)

        await checker.checkNow()

        XCTAssertEqual(checker.phase, .available)
        XCTAssertEqual(checker.releaseCandidate?.channel, .stable)
        let urls = await router.recordedURLs()
        XCTAssertEqual(urls, [production.feedURL])
        XCTAssertEqual(
            urls.map(\.absoluteString),
            ["https://saymiao.github.io/xdial-updates/stable.json"]
        )
        XCTAssertNil(
            defaults.data(forKey: "xdial.update.pages-cache.production-beta")
        )
    }

    @MainActor
    func testEnablingBetaChecksAtOnceAndOffersTheHigherFeed() async throws {
        let betaURL = AppUpdateFeedConfiguration.productionBeta.feedURL
        let router = AppUpdateFeedRouter([
            production.feedURL: [
                feedReply(
                    production,
                    revision: 1,
                    release: release(tag: "v0.9.7", build: "200")
                ),
            ],
            betaURL: [
                feedReply(
                    .productionBeta,
                    revision: 1,
                    release: release(tag: "v0.10.0-beta.1", build: "300")
                ),
            ],
        ])
        let preferences = try temporaryDefaults()
        let checker = makeChecker(
            AppUpdateChannelLookup(
                configuration: production,
                transport: router.transport,
                defaults: try temporaryDefaults()
            ),
            installed: installed("0.9.6", build: "100"),
            preferenceDefaults: preferences
        )
        await checker.waitForTasksForTesting()

        XCTAssertTrue(checker.setReceivesBetaUpdates(true))
        await checker.waitForTasksForTesting()

        XCTAssertTrue(checker.receivesBetaUpdates)
        XCTAssertEqual(
            preferences.string(forKey: "xdial.update.channel"),
            "beta"
        )
        XCTAssertEqual(checker.phase, .available)
        XCTAssertEqual(checker.releaseCandidate?.tag, "v0.10.0-beta.1")
        XCTAssertEqual(checker.releaseCandidate?.channel, .beta)
        let urls = await router.recordedURLs()
        XCTAssertEqual(urls, [production.feedURL, betaURL])

        // When stable is higher than the beta line, stable wins.
        let merged = AppUpdateReleaseAvailability.merged([
            .available(try candidate(
                .productionBeta,
                tag: "v0.10.0-beta.2",
                build: "300"
            )),
            .available(try candidate(
                production,
                tag: "v0.10.0",
                build: "400"
            )),
            .upToDate,
        ])
        guard case let .available(best) = merged else {
            return XCTFail("expected a merged candidate")
        }
        XCTAssertEqual(best.tag, "v0.10.0")
        XCTAssertEqual(best.channel, .stable)
    }

    @MainActor
    func testWithdrawnBetaFallsBackToStable() async throws {
        let betaURL = AppUpdateFeedConfiguration.productionBeta.feedURL
        let stableRelease = release(tag: "v0.9.7", build: "200")
        let router = AppUpdateFeedRouter([
            production.feedURL: [
                feedReply(production, revision: 1, release: stableRelease),
                feedReply(production, revision: 1, release: stableRelease),
            ],
            betaURL: [
                feedReply(
                    .productionBeta,
                    revision: 1,
                    release: release(tag: "v0.10.0-beta.1", build: "300")
                ),
                feedReply(.productionBeta, revision: 2, release: nil),
            ],
        ])
        let preferences = try temporaryDefaults()
        AppUpdateChannelPreference.setReceivesBeta(
            true,
            defaults: preferences
        )
        let checker = makeChecker(
            AppUpdateChannelLookup(
                configuration: production,
                transport: router.transport,
                defaults: try temporaryDefaults()
            ),
            installed: installed("0.9.6", build: "100"),
            preferenceDefaults: preferences
        )
        await checker.waitForTasksForTesting()
        await checker.checkNow()
        XCTAssertEqual(checker.releaseCandidate?.tag, "v0.10.0-beta.1")

        // Download revalidates first; the withdrawn beta yields to stable.
        checker.downloadAndPrepare()
        await checker.waitForTasksForTesting()

        XCTAssertEqual(checker.phase, .available)
        XCTAssertEqual(checker.failure?.code, .candidateChanged)
        XCTAssertEqual(checker.releaseCandidate?.tag, "v0.9.7")
        XCTAssertEqual(checker.releaseCandidate?.channel, .stable)
        XCTAssertNil(checker.stagedUpdate)
    }

    @MainActor
    func testBetaFeedFailureIsSecondaryWhileStableConcludes() async throws {
        let betaURL = AppUpdateFeedConfiguration.productionBeta.feedURL
        let preferences = try temporaryDefaults()
        AppUpdateChannelPreference.setReceivesBeta(
            true,
            defaults: preferences
        )

        let betaDown = AppUpdateFeedRouter([
            production.feedURL: [
                feedReply(
                    production,
                    revision: 1,
                    release: release(tag: "v0.9.6", build: "100")
                ),
            ],
            betaURL: [
                .response(AppUpdateHTTPResult(statusCode: 500, url: betaURL)),
            ],
        ])
        let concluded = makeChecker(
            AppUpdateChannelLookup(
                configuration: production,
                transport: betaDown.transport,
                defaults: try temporaryDefaults()
            ),
            installed: installed("0.9.6", build: "100"),
            preferenceDefaults: preferences
        )
        await concluded.waitForTasksForTesting()
        await concluded.checkNow()
        XCTAssertEqual(concluded.phase, .upToDate)
        XCTAssertNil(concluded.failure)
        XCTAssertNotNil(concluded.secondaryNotice)
        XCTAssertNotNil(concluded.lastCheckedAt)

        let stableDown = AppUpdateFeedRouter([
            production.feedURL: [
                .response(AppUpdateHTTPResult(
                    statusCode: 500,
                    url: production.feedURL
                )),
            ],
            betaURL: [
                feedReply(
                    .productionBeta,
                    revision: 1,
                    release: release(tag: "v0.10.0-beta.1", build: "300")
                ),
            ],
        ])
        let blocked = makeChecker(
            AppUpdateChannelLookup(
                configuration: production,
                transport: stableDown.transport,
                defaults: try temporaryDefaults()
            ),
            installed: installed("0.9.6", build: "100"),
            preferenceDefaults: preferences
        )
        await blocked.waitForTasksForTesting()
        await blocked.checkNow()
        XCTAssertEqual(blocked.phase, .failed)
        XCTAssertEqual(blocked.failure?.code, .checkUnavailable)
        XCTAssertNil(blocked.releaseCandidate)
        XCTAssertNil(blocked.lastCheckedAt)

        // Download requires the candidate's own feed to confirm it again.
        let ownFeedDown = AppUpdateFeedRouter([
            production.feedURL: [
                feedReply(
                    production,
                    revision: 1,
                    release: release(tag: "v0.9.6", build: "100")
                ),
            ],
            betaURL: [
                .response(AppUpdateHTTPResult(statusCode: 503, url: betaURL)),
            ],
        ])
        let unconfirmed = makeChecker(
            AppUpdateChannelLookup(
                configuration: production,
                transport: ownFeedDown.transport,
                defaults: try temporaryDefaults()
            ),
            installed: installed("0.9.6", build: "100"),
            preferenceDefaults: preferences
        )
        await unconfirmed.waitForTasksForTesting()
        let betaCandidate = try candidate(
            .productionBeta,
            tag: "v0.10.0-beta.1",
            build: "300"
        )
        unconfirmed.configureForTesting(
            candidate: betaCandidate,
            phase: .available
        )
        unconfirmed.downloadAndPrepare()
        await unconfirmed.waitForTasksForTesting()
        XCTAssertEqual(unconfirmed.phase, .available)
        XCTAssertEqual(unconfirmed.failure?.code, .checkUnavailable)
        XCTAssertEqual(unconfirmed.releaseCandidate, betaCandidate)
        XCTAssertNil(unconfirmed.stagedUpdate)
    }

    func testOtherFeedFailureDoesNotBlockCandidateRevalidation()
        async throws
    {
        let betaURL = AppUpdateFeedConfiguration.productionBeta.feedURL
        let router = AppUpdateFeedRouter([
            production.feedURL: [
                .response(AppUpdateHTTPResult(
                    statusCode: 500,
                    url: production.feedURL
                )),
            ],
            betaURL: [
                feedReply(
                    .productionBeta,
                    revision: 1,
                    release: release(tag: "v0.10.0-beta.1", build: "300")
                ),
            ],
        ])
        let result = try await AppUpdateChannelLookup(
            configuration: production,
            transport: router.transport,
            defaults: try temporaryDefaults()
        ).check(
            installed: installed("0.9.6", build: "100"),
            receivesBeta: true,
            currentSystemVersion: "15.0",
            now: Date(timeIntervalSince1970: 1_000)
        )
        XCTAssertNotNil(result.stable.error)
        XCTAssertNil(result.outcome(for: .beta)?.error)
        guard case let .available(confirmed) = result.availability else {
            return XCTFail("beta candidate was not confirmed")
        }
        XCTAssertEqual(
            confirmed.identity,
            try candidate(
                .productionBeta,
                tag: "v0.10.0-beta.1",
                build: "300"
            ).identity
        )
    }

    @MainActor
    func testInstalledBetaWithPreferenceOffAwaitsStableWithoutDowngrade()
        async throws
    {
        let betaURL = AppUpdateFeedConfiguration.productionBeta.feedURL
        let router = AppUpdateFeedRouter([
            production.feedURL: [
                feedReply(
                    production,
                    revision: 1,
                    release: release(tag: "v0.9.7", build: "200")
                ),
            ],
            betaURL: [
                feedReply(
                    .productionBeta,
                    revision: 1,
                    release: release(tag: "v0.10.0-beta.1", build: "300")
                ),
            ],
        ])
        let checker = makeChecker(
            AppUpdateChannelLookup(
                configuration: production,
                transport: router.transport,
                defaults: try temporaryDefaults()
            ),
            installed: installed(
                "0.10.0",
                build: "300",
                tag: "v0.10.0-beta.1"
            )
        )
        await checker.waitForTasksForTesting()
        XCTAssertFalse(checker.receivesBetaUpdates)
        await checker.checkNow()

        XCTAssertEqual(checker.phase, .awaitingStable)
        XCTAssertNil(checker.releaseCandidate)
        XCTAssertNil(checker.failure)
        let urls = await router.recordedURLs()
        XCTAssertEqual(urls, [production.feedURL, betaURL])
    }

    @MainActor
    func testInstalledBetaFollowsItsLineUntilStablePassesIt()
        async throws
    {
        let betaURL = AppUpdateFeedConfiguration.productionBeta.feedURL
        let router = AppUpdateFeedRouter([
            production.feedURL: [
                feedReply(
                    production,
                    revision: 1,
                    release: release(tag: "v0.9.7", build: "200")
                ),
                feedReply(
                    production,
                    revision: 2,
                    release: release(tag: "v0.10.0", build: "400")
                ),
            ],
            betaURL: [
                feedReply(
                    .productionBeta,
                    revision: 2,
                    release: release(tag: "v0.10.0-beta.2", build: "310")
                ),
            ],
        ])
        let lookup = AppUpdateChannelLookup(
            configuration: production,
            transport: router.transport,
            defaults: try temporaryDefaults()
        )
        let onBeta1 = makeChecker(
            lookup,
            installed: installed(
                "0.10.0",
                build: "300",
                tag: "v0.10.0-beta.1"
            )
        )
        await onBeta1.waitForTasksForTesting()
        await onBeta1.checkNow()
        XCTAssertEqual(onBeta1.phase, .available)
        XCTAssertEqual(onBeta1.releaseCandidate?.tag, "v0.10.0-beta.2")
        XCTAssertEqual(onBeta1.releaseCandidate?.channel, .beta)

        // Once stable passes the installed beta, beta.json is no longer read
        // and the same short version still moves forward to stable.
        let onBeta2 = makeChecker(
            lookup,
            installed: installed(
                "0.10.0",
                build: "310",
                tag: "v0.10.0-beta.2"
            )
        )
        await onBeta2.waitForTasksForTesting()
        await onBeta2.checkNow()
        XCTAssertEqual(onBeta2.phase, .available)
        XCTAssertEqual(onBeta2.releaseCandidate?.tag, "v0.10.0")
        XCTAssertEqual(onBeta2.releaseCandidate?.version, "0.10.0")
        XCTAssertEqual(onBeta2.releaseCandidate?.channel, .stable)
        let urls = await router.recordedURLs()
        XCTAssertEqual(
            urls,
            [production.feedURL, betaURL, production.feedURL]
        )
    }

    func testBetaAndStableReleasesReplaceEachOther() throws {
        // stable -> beta: the same signed identity, a higher tag and build.
        let intoBeta = try AppUpdateReleasePolicy.selectCandidate(
            from: feedRelease(tag: "v0.10.0-beta.1", build: "300"),
            generatedAt: Date(timeIntervalSince1970: 900),
            configuration: .productionBeta,
            installed: installed("0.9.6", build: "200"),
            currentSystemVersion: "15.0"
        )
        XCTAssertEqual(intoBeta.channel, .beta)

        // beta -> stable with the same X.Y.Z: the tag, not the short version,
        // decides, and the relaunch intent tells the two builds apart.
        let backToStable = try AppUpdateReleasePolicy.selectCandidate(
            from: feedRelease(tag: "v0.10.0", build: "400"),
            generatedAt: Date(timeIntervalSince1970: 900),
            configuration: production,
            installed: installed(
                "0.10.0",
                build: "300",
                tag: "v0.10.0-beta.1"
            ),
            currentSystemVersion: "15.0"
        )
        XCTAssertEqual(backToStable.channel, .stable)
        XCTAssertEqual(backToStable.version, "0.10.0")
        XCTAssertFalse(VersionUpdatePolicy.isNewer(
            latestTag: "v0.10.0",
            than: "0.10.0"
        ))

        let suiteName = "xdial-update-intent-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let now = Date(timeIntervalSince1970: 1_000)
        try AppUpdateRelaunchIntentStore.write(
            targetVersion: backToStable.version,
            targetBuild: backToStable.build,
            reconnectScenarioID: nil,
            now: now,
            defaults: defaults
        )
        XCTAssertFalse(
            AppUpdateRelaunchIntentStore.permitsStagedSuccessor(
                targetVersion: "0.10.0",
                targetBuild: "300",
                now: now,
                defaults: defaults
            )
        )
        try AppUpdateRelaunchIntentStore.write(
            targetVersion: backToStable.version,
            targetBuild: backToStable.build,
            reconnectScenarioID: nil,
            now: now,
            defaults: defaults
        )
        XCTAssertTrue(
            AppUpdateRelaunchIntentStore.permitsStagedSuccessor(
                targetVersion: "0.10.0",
                targetBuild: "400",
                now: now,
                defaults: defaults
            )
        )

        // Installation sees one product either way: a higher build replaces,
        // whichever channel published it.
        for (source, destination) in [("300", "200"), ("400", "300")] {
            XCTAssertEqual(
                ApplicationRelocationDecision.decide(
                    currentIsCanonical: false,
                    destinationExists: true,
                    destinationMatchesIdentity: true,
                    sourceBuild: source,
                    destinationBuild: destination
                ),
                .replace
            )
        }
    }

    func testRelaunchIntentAcceptsBytesWrittenByV096() throws {
        // Produced by encoding v0.9.6's AppUpdateRelaunchIntent (from
        // `git show v0.9.6:macos/Sources/XDial/AppUpdateTransaction.swift`)
        // with JSONEncoder() for target 0.9.7 at 1_792_000_000.25. Key order
        // is not stable across runs; these are one run's exact bytes.
        let reconnect = Data(
            #"{"reconnectScenarioID":"scenario-office","targetVersion":"0.9.7","schemaVersion":1,"createdAt":813692800.25}"#
                .utf8
        )
        let disconnected = Data(
            #"{"targetVersion":"0.9.7","schemaVersion":1,"createdAt":813692800.25}"#
                .utf8
        )
        let key = "xdial.update.relaunch-intent"
        let written = Date(timeIntervalSince1970: 1_792_000_000.25)
        let suiteName = "xdial-update-v096-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // The staged successor, launched by v0.9.6, sees the intent first.
        defaults.set(reconnect, forKey: key)
        XCTAssertTrue(
            AppUpdateRelaunchIntentStore.permitsStagedSuccessor(
                targetVersion: "0.9.7",
                targetBuild: "1792000001",
                now: written.addingTimeInterval(5),
                defaults: defaults
            )
        )
        // The final /Applications launch then restores the Scenario.
        XCTAssertEqual(
            AppUpdateRelaunchIntentStore.loadDecision(
                currentVersion: "0.9.7",
                currentBuild: "1792000001",
                activeScenarioID: "scenario-office",
                now: written.addingTimeInterval(20),
                defaults: defaults
            ),
            .reconnect(scenarioID: "scenario-office")
        )

        defaults.set(disconnected, forKey: key)
        XCTAssertEqual(
            AppUpdateRelaunchIntentStore.loadDecision(
                currentVersion: "0.9.7",
                currentBuild: "1792000001",
                activeScenarioID: "scenario-office",
                now: written.addingTimeInterval(20),
                defaults: defaults
            ),
            .stayDisconnected
        )

        defaults.set(reconnect, forKey: key)
        XCTAssertFalse(
            AppUpdateRelaunchIntentStore.permitsStagedSuccessor(
                targetVersion: "0.9.8",
                targetBuild: "1792000001",
                now: written.addingTimeInterval(5),
                defaults: defaults
            )
        )

        // A schema newer than this build understands is never trusted.
        defaults.set(
            Data(
                #"{"targetVersion":"0.9.7","targetBuild":"1792000001","schemaVersion":3,"createdAt":813692800.25}"#
                    .utf8
            ),
            forKey: key
        )
        XCTAssertFalse(
            AppUpdateRelaunchIntentStore.permitsStagedSuccessor(
                targetVersion: "0.9.7",
                targetBuild: "1792000001",
                now: written.addingTimeInterval(5),
                defaults: defaults
            )
        )

        // Schema 2 is what this build writes, and it binds the build.
        try AppUpdateRelaunchIntentStore.write(
            targetVersion: "0.9.7",
            targetBuild: "1792000001",
            reconnectScenarioID: "scenario-office",
            now: written,
            defaults: defaults
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: XCTUnwrap(defaults.data(forKey: key))
            ) as? [String: Any]
        )
        XCTAssertEqual(object["schemaVersion"] as? Int, 2)
        XCTAssertEqual(object["targetBuild"] as? String, "1792000001")
        XCTAssertNil(
            AppUpdateRelaunchIntentStore.loadDecision(
                currentVersion: "0.9.7",
                currentBuild: "1792000002",
                activeScenarioID: "scenario-office",
                now: written.addingTimeInterval(20),
                defaults: defaults
            )
        )
    }

    func testReleaseTagNeverSelectsFeedOrAuthorizesUpdate() throws {
        let betaTag = [InstalledRelease.releaseTagInfoKey: "v0.10.0-beta.1"]
        XCTAssertEqual(
            try AppUpdateFeedConfiguration.current(infoDictionary: betaTag),
            .production
        )
        XCTAssertEqual(
            try AppUpdateFeedConfiguration.current(
                infoDictionary: betaTag.merging([
                    AppUpdateFeedConfiguration.acceptanceInfoKey: "pages-a",
                ]) { current, _ in current }
            ),
            try AppUpdateFeedConfiguration.acceptance(id: "pages-a")
        )

        let beta = InstalledRelease.current(infoDictionary: [
            "CFBundleShortVersionString": "0.10.0",
            "CFBundleVersion": "300",
            InstalledRelease.releaseTagInfoKey: "v0.10.0-beta.1",
        ])
        XCTAssertTrue(beta.isBeta)
        XCTAssertEqual(beta.displayTag, "v0.10.0-beta.1")
        XCTAssertEqual(beta.build, "300")
        for tag: Any in ["", "v0.10.0", "v0.10.1-beta.1", "beta", 42] {
            let release = InstalledRelease.current(infoDictionary: [
                "CFBundleShortVersionString": "0.10.0",
                "CFBundleVersion": "300",
                InstalledRelease.releaseTagInfoKey: tag,
            ])
            XCTAssertFalse(release.isBeta, "\(tag)")
            XCTAssertEqual(release.displayTag, "v0.10.0", "\(tag)")
        }
        XCTAssertEqual(
            InstalledRelease.current(infoDictionary: [
                "CFBundleShortVersionString": "0.10.0",
                "CFBundleVersion": "300",
            ]).displayTag,
            "v0.10.0"
        )
    }

    @MainActor
    func testChannelSwitchIsRefusedWhileAnUpdateIsBusy() throws {
        let preferences = try temporaryDefaults()
        let checker = makeChecker(
            AppUpdateChannelLookup(
                configuration: production,
                transport: AppUpdateHTTPRecorder(replies: []).transport,
                defaults: try temporaryDefaults()
            ),
            preferenceDefaults: preferences
        )
        for phase: AppUpdatePhase in [
            .checking, .downloading, .validating, .handingOff,
        ] {
            checker.configureForTesting(
                candidate: try releaseCandidate(),
                phase: phase
            )
            XCTAssertFalse(checker.canChangeChannel, phase.rawValue)
            XCTAssertFalse(checker.setReceivesBetaUpdates(true))
            XCTAssertFalse(checker.receivesBetaUpdates)
            XCTAssertNil(
                preferences.string(forKey: AppUpdateChannelPreference.key)
            )
        }
    }

    @MainActor
    func testTurningBetaOffDropsOnlyAStableToBetaEntry() async throws {
        let betaURL = AppUpdateFeedConfiguration.productionBeta.feedURL
        let betaCandidate = try candidate(
            .productionBeta,
            tag: "v0.10.0-beta.1",
            build: "300"
        )

        // A stable install would enter the beta line: drop the staged beta.
        let stableRouter = AppUpdateFeedRouter([
            production.feedURL: [
                feedReply(
                    production,
                    revision: 1,
                    release: release(tag: "v0.9.6", build: "100")
                ),
            ],
        ])
        let preferences = try temporaryDefaults()
        AppUpdateChannelPreference.setReceivesBeta(
            true,
            defaults: preferences
        )
        let leaving = makeChecker(
            AppUpdateChannelLookup(
                configuration: production,
                transport: stableRouter.transport,
                defaults: try temporaryDefaults()
            ),
            installed: installed("0.9.6", build: "100"),
            preferenceDefaults: preferences
        )
        await leaving.waitForTasksForTesting()
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        leaving.configureForTesting(
            candidate: betaCandidate,
            stagedUpdate: StagedAppUpdate(
                rootURL: rootURL,
                applicationURL: rootURL.appendingPathComponent("XDial.app")
            ),
            phase: .ready
        )
        XCTAssertTrue(leaving.setReceivesBetaUpdates(false))
        XCTAssertNil(leaving.releaseCandidate)
        XCTAssertNil(leaving.stagedUpdate)
        await leaving.waitForTasksForTesting()
        XCTAssertNil(
            preferences.string(forKey: AppUpdateChannelPreference.key)
        )
        XCTAssertEqual(leaving.phase, .upToDate)
        let stableURLs = await stableRouter.recordedURLs()
        XCTAssertEqual(stableURLs, [production.feedURL])

        // An installed beta keeps its pending fix on the same line.
        let betaRouter = AppUpdateFeedRouter([
            production.feedURL: [
                feedReply(
                    production,
                    revision: 1,
                    release: release(tag: "v0.9.6", build: "100")
                ),
            ],
            betaURL: [
                feedReply(
                    .productionBeta,
                    revision: 1,
                    release: release(tag: "v0.10.0-beta.2", build: "310")
                ),
            ],
        ])
        let betaPreferences = try temporaryDefaults()
        AppUpdateChannelPreference.setReceivesBeta(
            true,
            defaults: betaPreferences
        )
        let staying = makeChecker(
            AppUpdateChannelLookup(
                configuration: production,
                transport: betaRouter.transport,
                defaults: try temporaryDefaults()
            ),
            installed: installed(
                "0.10.0",
                build: "300",
                tag: "v0.10.0-beta.1"
            ),
            preferenceDefaults: betaPreferences
        )
        await staying.waitForTasksForTesting()
        let fix = try candidate(
            .productionBeta,
            tag: "v0.10.0-beta.2",
            build: "310"
        )
        staying.configureForTesting(candidate: fix, phase: .available)
        XCTAssertTrue(staying.setReceivesBetaUpdates(false))
        XCTAssertEqual(staying.releaseCandidate, fix)
        await staying.waitForTasksForTesting()
        XCTAssertEqual(staying.phase, .available)
        XCTAssertEqual(staying.releaseCandidate?.identity, fix.identity)
        let betaURLs = await betaRouter.recordedURLs()
        XCTAssertEqual(betaURLs, [production.feedURL, betaURL])
    }

    private func feedRelease(
        tag: String,
        version: String? = nil,
        build: String
    ) -> AppUpdateFeedRelease {
        AppUpdateFeedRelease(
            tag: tag,
            version: version ?? ReleaseTag(tag)?.version
                ?? String(tag.dropFirst()),
            build: build,
            minimumSystemVersion: "15.0",
            publishedAt: Date(timeIntervalSince1970: 800),
            releaseNotes: "- Pages update",
            archiveURL: productionArchiveURL(tag: tag),
            archiveSize: 1234,
            archiveSHA256: String(repeating: "a", count: 64)
        )
    }

    private func release(tag: String, build: String) -> [String: Any] {
        [
            "tag": tag,
            "version": ReleaseTag(tag)?.version ?? "",
            "build": build,
            "archiveURL": productionArchiveURL(tag: tag).absoluteString,
        ]
    }

    private func candidate(
        _ configuration: AppUpdateFeedConfiguration,
        tag: String,
        build: String
    ) throws -> AppUpdateReleaseCandidate {
        try AppUpdateReleasePolicy.selectCandidate(
            from: feedRelease(tag: tag, build: build),
            generatedAt: Date(timeIntervalSince1970: 900),
            configuration: configuration,
            installed: installed("0.0.1", build: "1"),
            currentSystemVersion: "15.0"
        )
    }

    private func feedReply(
        _ configuration: AppUpdateFeedConfiguration,
        revision: Int,
        release: [String: Any]? = [:]
    ) -> AppUpdateHTTPReply {
        .response(AppUpdateHTTPResult(
            data: manifestData(
                revision: revision,
                channel: configuration.channel,
                release: release
            ),
            statusCode: 200,
            url: configuration.feedURL,
            headers: jsonHeaders(
                etag: "\"\(configuration.channel.rawValue)-\(revision)\""
            )
        ))
    }
}

private enum AppUpdateHTTPReply: Sendable {
    case response(AppUpdateHTTPResult)
    case failure(URLError.Code)
    case cancelled
}

private actor AppUpdateHTTPRecorder {
    private var replies: [AppUpdateHTTPReply]
    private var requests: [URLRequest] = []

    init(replies: [AppUpdateHTTPReply]) {
        self.replies = replies
    }

    nonisolated var transport: AppUpdateHTTPTransport {
        AppUpdateHTTPTransport { [self] request in
            try await perform(request)
        }
    }

    func recordedRequests() -> [URLRequest] {
        requests
    }

    private func perform(_ request: URLRequest) throws
        -> AppUpdateHTTPResult
    {
        requests.append(request)
        guard !replies.isEmpty else {
            throw URLError(.resourceUnavailable)
        }
        switch replies.removeFirst() {
        case let .response(response):
            return response
        case let .failure(code):
            throw URLError(code)
        case .cancelled:
            throw CancellationError()
        }
    }
}

/// Answers each feed URL from its own queue, so tests that read stable.json
/// and beta.json do not depend on request order.
private actor AppUpdateFeedRouter {
    private var replies: [URL: [AppUpdateHTTPReply]]
    private var requests: [URLRequest] = []

    init(_ replies: [URL: [AppUpdateHTTPReply]]) {
        self.replies = replies
    }

    nonisolated var transport: AppUpdateHTTPTransport {
        AppUpdateHTTPTransport { [self] request in
            try await perform(request)
        }
    }

    func recordedURLs() -> [URL] {
        requests.compactMap(\.url)
    }

    private func perform(_ request: URLRequest) throws
        -> AppUpdateHTTPResult
    {
        requests.append(request)
        guard let url = request.url,
              var queue = replies[url],
              !queue.isEmpty else {
            throw URLError(.resourceUnavailable)
        }
        let reply = queue.removeFirst()
        replies[url] = queue
        switch reply {
        case let .response(response):
            return response
        case let .failure(code):
            throw URLError(code)
        case .cancelled:
            throw CancellationError()
        }
    }
}

private actor AppUpdateReorderingTransport {
    private let firstResponse: AppUpdateHTTPResult
    private let secondResponse: AppUpdateHTTPResult
    private let laterResponse: AppUpdateHTTPResult
    private var requests: [URLRequest] = []
    private var firstStarted = false
    private var firstStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstRelease: CheckedContinuation<Void, Never>?

    init(
        firstResponse: AppUpdateHTTPResult,
        secondResponse: AppUpdateHTTPResult,
        laterResponse: AppUpdateHTTPResult
    ) {
        self.firstResponse = firstResponse
        self.secondResponse = secondResponse
        self.laterResponse = laterResponse
    }

    nonisolated var transport: AppUpdateHTTPTransport {
        AppUpdateHTTPTransport { [self] request in
            await perform(request)
        }
    }

    func waitUntilFirstRequestStarts() async {
        if firstStarted { return }
        await withCheckedContinuation { continuation in
            firstStartWaiters.append(continuation)
        }
    }

    func releaseFirstResponse() {
        firstRelease?.resume()
        firstRelease = nil
    }

    func recordedRequests() -> [URLRequest] {
        requests
    }

    private func perform(_ request: URLRequest) async
        -> AppUpdateHTTPResult
    {
        requests.append(request)
        switch requests.count {
        case 1:
            firstStarted = true
            let waiters = firstStartWaiters
            firstStartWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            await withCheckedContinuation { continuation in
                firstRelease = continuation
            }
            return firstResponse
        case 2:
            return secondResponse
        default:
            return laterResponse
        }
    }
}

private final class AppUpdateArchiveFixture {
    let fileManager = AppUpdateTemporaryFileManager()
    let sourceRoot: URL
    let stagingRoot: URL
    let archiveURL: URL

    init(rootEntries: [String]) throws {
        sourceRoot = fileManager.temporaryDirectory
            .appendingPathComponent(
                "xdial-update-source-\(UUID().uuidString)",
                isDirectory: true
            )
        try fileManager.createDirectory(
            at: sourceRoot,
            withIntermediateDirectories: true
        )
        for entry in rootEntries {
            let entryURL = sourceRoot.appendingPathComponent(entry)
            if entry == XDialBuildIdentity.applicationBundleName {
                try fileManager.createDirectory(
                    at: entryURL,
                    withIntermediateDirectories: true
                )
                try Data("signed-fixture".utf8).write(
                    to: entryURL.appendingPathComponent("marker")
                )
            } else {
                try Data("extra".utf8).write(to: entryURL)
            }
        }

        stagingRoot = try AppUpdateStager.makeStagingRoot(
            fileManager: fileManager
        )
        archiveURL = AppUpdateStager.archiveURL(in: stagingRoot)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = [
            "-c",
            "-k",
            sourceRoot.path,
            archiveURL.path,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    func cleanup() {
        for url in [sourceRoot, stagingRoot]
        where fileManager.fileExists(atPath: url.path) {
            try? fileManager.removeItem(at: url)
        }
    }
}

private final class AppUpdateTemporaryFileManager: FileManager {
    private let isolatedTemporaryDirectory: URL

    override var temporaryDirectory: URL {
        isolatedTemporaryDirectory
    }

    override init() {
        isolatedTemporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "xdial-update-tests-\(UUID().uuidString)",
                isDirectory: true
            )
        super.init()
        try! createDirectory(
            at: isolatedTemporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    deinit {
        try? FileManager.default.removeItem(
            at: isolatedTemporaryDirectory
        )
    }
}
