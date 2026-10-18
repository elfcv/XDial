import Foundation

struct AppUpdateReleaseCandidate: Equatable, Sendable {
    let channel: AppUpdateChannel
    let tag: String
    let version: String
    let build: String
    let minimumSystemVersion: String
    let publishedAt: Date
    let archiveName: String
    let archiveURL: URL
    let archiveSize: Int64
    let archiveSHA256: String
    let releaseNotes: String

    var identity: AppUpdateCandidateIdentity {
        AppUpdateCandidateIdentity(
            channel: channel,
            version: version,
            build: build,
            archiveSHA256: archiveSHA256
        )
    }

    var releaseTag: ReleaseTag? { ReleaseTag(tag) }
}

struct AppUpdateCandidateIdentity: Equatable, Sendable {
    let channel: AppUpdateChannel
    let version: String
    let build: String
    let archiveSHA256: String
}

/// A feed offered a newer tag whose build would not replace the active
/// System Extension. Reported as a failure, never as "up to date".
struct AppUpdateBuildNotNewer: Equatable, Sendable {
    let channel: AppUpdateChannel
    let tag: String
    let build: String
    let installedBuild: String
}

enum AppUpdateReleaseSelectionError: Error, Equatable {
    case invalidVersionTag
    case invalidBuild
    case invalidMinimumSystemVersion
    case unsupportedSystemVersion
    case invalidPublishedAt
    case releaseNotesMissing
    case notNewer
    case buildNotNewer
    case archiveSizeInvalid
    case archiveSHA256Invalid
    case archiveURLRejected
}

enum AppUpdateReleasePolicy {
    static func selectCandidate(
        from release: AppUpdateFeedRelease,
        generatedAt: Date,
        configuration: AppUpdateFeedConfiguration,
        installed: InstalledRelease,
        currentSystemVersion: String
    ) throws -> AppUpdateReleaseCandidate {
        guard permitsTag(
            release.tag,
            version: release.version,
            channel: configuration.channel
        ) else {
            throw AppUpdateReleaseSelectionError.invalidVersionTag
        }
        guard isPositiveInteger(release.build) else {
            throw AppUpdateReleaseSelectionError.invalidBuild
        }
        guard let minimumSystemVersion = NumericSystemVersion(
            release.minimumSystemVersion
        ) else {
            throw AppUpdateReleaseSelectionError
                .invalidMinimumSystemVersion
        }
        guard let currentSystemVersion = NumericSystemVersion(
            currentSystemVersion
        ), currentSystemVersion >= minimumSystemVersion else {
            throw AppUpdateReleaseSelectionError.unsupportedSystemVersion
        }
        guard release.publishedAt <= generatedAt else {
            throw AppUpdateReleaseSelectionError.invalidPublishedAt
        }

        let releaseNotes = release.releaseNotes.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !releaseNotes.isEmpty else {
            throw AppUpdateReleaseSelectionError.releaseNotesMissing
        }
        guard AppUpdateArchivePolicy.permitsArchiveByteCount(
            release.archiveSize
        ) else {
            throw AppUpdateReleaseSelectionError.archiveSizeInvalid
        }
        guard release.archiveSHA256.count == 64,
              release.archiveSHA256.utf8.allSatisfy({
                  (48 ... 57).contains($0) || (97 ... 102).contains($0)
              }) else {
            throw AppUpdateReleaseSelectionError.archiveSHA256Invalid
        }

        let archiveName = "XDial-\(release.tag).zip"
        guard configuration.permitsArchiveURL(
            release.archiveURL,
            tag: release.tag,
            archiveName: archiveName
        ) else {
            throw AppUpdateReleaseSelectionError.archiveURLRejected
        }
        guard installed.precedes(tag: release.tag) else {
            throw AppUpdateReleaseSelectionError.notNewer
        }
        // A lower build cannot replace the active System Extension, so a newer
        // tag with an older build is a publishing fault, not an update.
        guard BundleBuildNumber.compare(release.build, installed.build)
                .map({ $0 == .orderedDescending }) ?? true else {
            throw AppUpdateReleaseSelectionError.buildNotNewer
        }

        return AppUpdateReleaseCandidate(
            channel: configuration.channel,
            tag: release.tag,
            version: release.version,
            build: release.build,
            minimumSystemVersion: release.minimumSystemVersion,
            publishedAt: release.publishedAt,
            archiveName: archiveName,
            archiveURL: release.archiveURL,
            archiveSize: release.archiveSize,
            archiveSHA256: release.archiveSHA256,
            releaseNotes: releaseNotes
        )
    }

    /// Each feed carries only its own tag form: stable keeps the exact rule
    /// released clients apply, and beta accepts only `vX.Y.Z-beta.N`.
    private static func permitsTag(
        _ tag: String,
        version: String,
        channel: AppUpdateChannel
    ) -> Bool {
        switch channel {
        case .stable:
            VersionUpdatePolicy.stableReleaseVersion(fromTag: tag) == version
        case .beta:
            ReleaseTag(tag).map { $0.isBeta && $0.version == version }
                ?? false
        }
    }

    private static func isPositiveInteger(_ value: String) -> Bool {
        guard let first = value.utf8.first,
              (49 ... 57).contains(first) else {
            return false
        }
        return value.utf8.dropFirst().allSatisfy {
            (48 ... 57).contains($0)
        }
    }

    private struct NumericSystemVersion: Comparable {
        let components: [Int]

        init?(_ value: String) {
            let parts = value.split(
                separator: ".",
                omittingEmptySubsequences: false
            )
            guard (2 ... 3).contains(parts.count),
                  parts.allSatisfy({
                      !$0.isEmpty
                          && $0.utf8.allSatisfy {
                              (48 ... 57).contains($0)
                          }
                          && ($0 == "0" || $0.first != "0")
                  }) else {
                return nil
            }
            components = parts.compactMap { Int($0) }
            guard components.count == parts.count else { return nil }
        }

        static func < (
            lhs: NumericSystemVersion,
            rhs: NumericSystemVersion
        ) -> Bool {
            let count = max(lhs.components.count, rhs.components.count)
            for index in 0..<count {
                let left = index < lhs.components.count
                    ? lhs.components[index] : 0
                let right = index < rhs.components.count
                    ? rhs.components[index] : 0
                if left != right { return left < right }
            }
            return false
        }
    }
}
enum AppUpdateArchivePolicy {
    static let maximumArchiveBytes: Int64 = 512 * 1024 * 1024

    static func permitsArchiveByteCount(_ byteCount: Int64) -> Bool {
        byteCount > 0 && byteCount <= maximumArchiveBytes
    }

    static func containsExactlyOneRootApplication(
        _ names: [String]
    ) -> Bool {
        names == [XDialBuildIdentity.applicationBundleName]
    }
}

enum AppUpdateDownloadPolicy {
    static func permitsRedirect(to url: URL) -> Bool {
        url.scheme?.lowercased() == "https"
            && url.host?.lowercased()
                == "release-assets.githubusercontent.com"
            && url.port == nil
            && url.user == nil
            && url.password == nil
    }

    static func permitsResponse(
        statusCode: Int,
        expectedByteCount: Int64
    ) -> Bool {
        guard statusCode == 200 else { return false }
        return expectedByteCount == NSURLSessionTransferSizeUnknown
            || AppUpdateArchivePolicy.permitsArchiveByteCount(
                expectedByteCount
            )
    }

    static func permitsProgress(
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) -> Bool {
        guard totalBytesWritten >= 0,
              totalBytesWritten
                <= AppUpdateArchivePolicy.maximumArchiveBytes else {
            return false
        }
        return totalBytesExpectedToWrite
            == NSURLSessionTransferSizeUnknown
            || AppUpdateArchivePolicy.permitsArchiveByteCount(
                totalBytesExpectedToWrite
            )
    }
}

enum AppUpdatePhase: String, Equatable {
    case idle
    case checking
    case upToDate = "up_to_date"
    case noRelease = "no_release"
    /// An installed beta with the beta preference off: it keeps following
    /// its beta line and returns to stable once stable passes it.
    case awaitingStable = "awaiting_stable"
    case available
    case downloading
    case validating
    case ready
    case handingOff = "handing_off"
    case failed
}

enum AppUpdateFailureCode: String, Equatable {
    case checkUnavailable = "check_unavailable"
    case candidateChanged = "candidate_changed"
    case buildNotNewer = "build_not_newer"
    case downloadFailed = "download_failed"
    case validationFailed = "validation_failed"
}

struct AppUpdateFailure: Equatable {
    let code: AppUpdateFailureCode
    let detail: String
}

struct AppUpdateRelaunchIntent: Codable, Equatable {
    /// Schema 2 adds targetBuild: a beta and its stable release share X.Y.Z.
    /// Every earlier schema stays readable, because the outgoing app that
    /// wrote the intent may be any released version.
    static let schemaVersion = 2

    let schemaVersion: Int
    let targetVersion: String
    let targetBuild: String?
    let reconnectScenarioID: String?
    let createdAt: Date
}

enum AppUpdateRelaunchDecision: Equatable {
    case reconnect(scenarioID: String)
    case stayDisconnected
}

enum AppUpdateRelaunchIntentPolicy {
    static let maximumAge: TimeInterval = 30 * 60

    static func decision(
        for intent: AppUpdateRelaunchIntent,
        currentVersion: String,
        currentBuild: String,
        activeScenarioID: String,
        now: Date
    ) -> AppUpdateRelaunchDecision? {
        guard permitsTarget(
            intent,
            version: currentVersion,
            build: currentBuild,
            now: now
        ) else {
            return nil
        }
        guard let scenarioID = intent.reconnectScenarioID else {
            return .stayDisconnected
        }
        guard !scenarioID.isEmpty,
              scenarioID == activeScenarioID else {
            return nil
        }
        return .reconnect(scenarioID: scenarioID)
    }

    /// Accepts every schema up to the current one. Schema 1, written by
    /// v0.9.x and earlier, binds only the version; later schemas also bind
    /// the build.
    static func permitsTarget(
        _ intent: AppUpdateRelaunchIntent,
        version: String,
        build: String,
        now: Date
    ) -> Bool {
        let age = now.timeIntervalSince(intent.createdAt)
        guard (1 ... AppUpdateRelaunchIntent.schemaVersion)
                .contains(intent.schemaVersion),
              intent.targetVersion == version,
              age >= 0,
              age <= maximumAge else {
            return false
        }
        return intent.schemaVersion == 1 || intent.targetBuild == build
    }
}

enum AppUpdateRelaunchIntentStore {
    private static let key = "xdial.update.relaunch-intent"

    static func write(
        targetVersion: String,
        targetBuild: String,
        reconnectScenarioID: String?,
        now: Date = Date(),
        defaults: UserDefaults = xdialDefaults
    ) throws {
        let intent = AppUpdateRelaunchIntent(
            schemaVersion: AppUpdateRelaunchIntent.schemaVersion,
            targetVersion: targetVersion,
            targetBuild: targetBuild,
            reconnectScenarioID: reconnectScenarioID,
            createdAt: now
        )
        defaults.set(try JSONEncoder().encode(intent), forKey: key)
    }

    static func loadDecision(
        currentVersion: String,
        currentBuild: String,
        activeScenarioID: String,
        now: Date = Date(),
        defaults: UserDefaults = xdialDefaults
    ) -> AppUpdateRelaunchDecision? {
        guard let data = defaults.data(forKey: key),
              let intent = try? JSONDecoder().decode(
                  AppUpdateRelaunchIntent.self,
                  from: data
              ),
              let decision = AppUpdateRelaunchIntentPolicy.decision(
                  for: intent,
                  currentVersion: currentVersion,
                  currentBuild: currentBuild,
                  activeScenarioID: activeScenarioID,
                  now: now
              ) else {
            defaults.removeObject(forKey: key)
            return nil
        }
        return decision
    }

    static func permitsStagedSuccessor(
        targetVersion: String,
        targetBuild: String,
        now: Date = Date(),
        defaults: UserDefaults = xdialDefaults
    ) -> Bool {
        guard let data = defaults.data(forKey: key),
              let intent = try? JSONDecoder().decode(
                  AppUpdateRelaunchIntent.self,
                  from: data
              ),
              AppUpdateRelaunchIntentPolicy.permitsTarget(
                  intent,
                  version: targetVersion,
                  build: targetBuild,
                  now: now
              ) else {
            defaults.removeObject(forKey: key)
            return false
        }
        return true
    }

    static func clear(
        defaults: UserDefaults = xdialDefaults
    ) {
        defaults.removeObject(forKey: key)
    }
}

enum AutomaticUpdateBundlePolicy {
    static let releaseHelperIdentifier =
        XDialBuildIdentity.helperIdentifier
    static let releaseExtensionIdentifier =
        XDialBuildIdentity.transparentProxyIdentifier

    static func permits(
        currentIdentifier: String,
        currentTeamIdentifier: String,
        currentAcceptanceID: String?,
        incomingIdentifier: String,
        incomingTeamIdentifier: String,
        incomingAcceptanceID: String?,
        incomingVersion: String,
        expectedVersion: String,
        incomingBuild: String,
        expectedBuild: String
    ) -> Bool {
        XDialBuildIdentity.allowsAutomaticUpdates
            && currentIdentifier == XDialBuildIdentity.applicationIdentifier
            && incomingIdentifier == XDialBuildIdentity.applicationIdentifier
            && !currentTeamIdentifier.isEmpty
            && currentTeamIdentifier == incomingTeamIdentifier
            && permitsAcceptanceTransition(
                currentAcceptanceID: currentAcceptanceID,
                incomingAcceptanceID: incomingAcceptanceID
            )
            && incomingVersion == expectedVersion
            && incomingBuild == expectedBuild
    }

    static func permitsAcceptanceTransition(
        currentAcceptanceID: String?,
        incomingAcceptanceID: String?
    ) -> Bool {
        currentAcceptanceID == incomingAcceptanceID
    }

    static func permitsVersionSet(
        expectedVersion: String,
        expectedBuild: String,
        hostVersion: String,
        hostBuild: String,
        settingsVersion: String,
        settingsBuild: String,
        extensionVersion: String,
        extensionBuild: String
    ) -> Bool {
        hostBuild == expectedBuild
            && hostVersion == expectedVersion
            && settingsVersion == expectedVersion
            && extensionVersion == expectedVersion
            && settingsBuild == hostBuild
            && extensionBuild == hostBuild
    }
}
