import CryptoKit
import Foundation
import XCTest

final class ProfileLibraryMigrationTests: XCTestCase {
    private func temporaryHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: home) }
        return home
    }

    private func writeLegacy(_ profile: Profile, at source: ConfigurationStorage.LegacyLocation,
                             home: URL, date: Date = Date()) throws -> [URL: Data] {
        let preferences = home.appendingPathComponent(source.preferencesPath)
        let vault = home.appendingPathComponent(source.dataPath + "/vault.json")
        let files = [preferences: try PropertyListSerialization.data(
            fromPropertyList: ["xdial.profile": JSONEncoder().encode(profile), "xdial.autoConnect": true],
            format: .binary, options: 0), vault: try JSONEncoder().encode(["vpn-vpn": "saved-password"])]
        for (url, data) in files {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }
        return files
    }

    private func converted(_ profile: Profile, id: String) -> Profile {
        var value = profile
        value.profileID = id
        return value
    }

    func testFirstLaunchCreatesOneDefaultAndNeverWritesBackToLegacy() throws {
        let home = try temporaryHome()
        let key = SymmetricKey(size: .bits256)
        let store = ProfileLibraryStore(directory: ConfigurationStorage.directory(home: home), keyProvider: { _ in key })
        var old = ProfileRecord.empty(named: "Old").profile
        old.lines.append(Line(id: "vpn", name: "Company", type: "vpn"))
        old.scenarios[0].defaultLineID = "vpn"
        let original = try writeLegacy(old, at: ConfigurationStorage.desktopLocations[0], home: home)
        var conversions = 0
        let library = try store.loadOrCreate {
            try ProfileLibraryMigration.initialLibrary(home: home) { profile, id in
                conversions += 1
                return self.converted(profile, id: id)
            }
        }
        XCTAssertEqual(conversions, 1)
        XCTAssertEqual(library.profiles.count, 1)
        XCTAssertEqual(library.profiles[0].name, "默认配置")
        XCTAssertEqual(library.activeProfileID, ProfileLibrary.configurationID)
        XCTAssertEqual(library.editingProfileID, library.profiles[0].id)
        XCTAssertEqual(library.profiles[0].profile.lines.last?.vpnPassword, "saved-password")
        XCTAssertEqual(library.scenarios, old.scenarios)
        var changed = library
        changed.profiles[0].profile.lines[1].name = "Edited in new version"
        try store.save(changed)
        let relaunched = ProfileLibraryStore(directory: store.directory, keyProvider: { _ in key })
        XCTAssertEqual(try relaunched.loadOrCreate { XCTFail("must not import twice"); return nil }, changed)
        for (url, data) in original { XCTAssertEqual(try Data(contentsOf: url), data) }
    }

    func testNewestSavedConfigurationWinsWithoutAChannelPriority() throws {
        let home = try temporaryHome()
        var old = ProfileRecord.empty(named: "Old").profile
        old.lines[0].name = "older formal"
        _ = try writeLegacy(old, at: ConfigurationStorage.desktopLocations[0], home: home, date: Date(timeIntervalSince1970: 100))
        old.lines[0].name = "newer debug"
        _ = try writeLegacy(old, at: ConfigurationStorage.desktopLocations[1], home: home, date: Date(timeIntervalSince1970: 200))
        let library = try XCTUnwrap(ProfileLibraryMigration.initialLibrary(home: home, convertProfile: converted))
        XCTAssertEqual(library.profiles[0].profile.lines[0].name, "newer debug")
    }

    func testExistingNextLibraryRetainsEveryProfileAndOriginalEncryptedFile() throws {
        let home = try temporaryHome()
        let key = SymmetricKey(size: .bits256)
        let source = ConfigurationStorage.desktopLocations[2]
        let oldStore = ProfileLibraryStore(directory: home.appendingPathComponent(source.dataPath), keyProvider: { _ in key })
        var original = ProfileLibrary()
        try original.insert(.empty(named: "Second"))
        original.activeScenarioID = original.scenarios.last!.id
        try oldStore.save(original)
        let oldFile = oldStore.directory.appendingPathComponent("profiles.enc")
        let bytes = try Data(contentsOf: oldFile)
        let store = ProfileLibraryStore(directory: ConfigurationStorage.directory(home: home), keyProvider: { _ in key })
        let loaded = try store.loadOrCreate {
            try ProfileLibraryMigration.initialLibrary(home: home, readLibrary: { location in
                XCTAssertEqual(location, source)
                return try oldStore.load()
            }, convertProfile: { _, _ in XCTFail("already a Profile library"); return Profile() })
        }
        XCTAssertEqual(loaded, original)
        XCTAssertEqual(try Data(contentsOf: oldFile), bytes)
        XCTAssertEqual(try store.load(), original)
    }

    func testFailedConversionDoesNotCreateEmptyLibraryOrTouchSource() throws {
        let home = try temporaryHome()
        let key = SymmetricKey(size: .bits256)
        let files = try writeLegacy(ProfileRecord.empty(named: "Old").profile,
                                    at: ConfigurationStorage.desktopLocations[0], home: home)
        let store = ProfileLibraryStore(directory: ConfigurationStorage.directory(home: home), keyProvider: { _ in key })
        XCTAssertThrowsError(try store.loadOrCreate {
            try ProfileLibraryMigration.initialLibrary(home: home) { _, _ in
                throw ProfileLibraryError.invalid("cannot convert")
            }
        })
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory.appendingPathComponent("profiles.enc").path))
        for (url, data) in files { XCTAssertEqual(try Data(contentsOf: url), data) }
    }

    func testCorruptSharedLibraryNeverFallsBackToOldConfiguration() throws {
        let home = try temporaryHome()
        let store = ProfileLibraryStore(directory: ConfigurationStorage.directory(home: home), keyProvider: { _ in SymmetricKey(size: .bits256) })
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        let file = store.directory.appendingPathComponent("profiles.enc")
        let original = Data("corrupt shared library".utf8)
        try original.write(to: file)
        XCTAssertThrowsError(try store.loadOrCreate { XCTFail("must not migrate an unreadable existing library"); return ProfileLibrary() })
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testAnotherVersionFinishingMigrationFirstIsRetained() throws {
        let home = try temporaryHome()
        let key = SymmetricKey(size: .bits256)
        let first = ProfileLibraryStore(directory: ConfigurationStorage.directory(home: home), keyProvider: { _ in key })
        let second = ProfileLibraryStore(directory: first.directory, keyProvider: { _ in key })
        var winner = ProfileLibrary()
        winner.profiles[0].name = "Already migrated"
        let result = try first.loadOrCreate {
            try second.save(winner)
            return ProfileLibrary()
        }
        XCTAssertEqual(result, winner)
    }

    func testNoLegacyDataCreatesDefaultOnce() throws {
        let home = try temporaryHome()
        let key = SymmetricKey(size: .bits256)
        let store = ProfileLibraryStore(directory: ConfigurationStorage.directory(home: home), keyProvider: { _ in key })
        let result = try store.loadOrCreate {
            try ProfileLibraryMigration.initialLibrary(home: home) { _, _ in XCTFail(); return Profile() }
        }
        XCTAssertEqual(result.profiles.count, 1)
        XCTAssertEqual(result.profiles[0].name, "默认配置")
        XCTAssertEqual(try store.loadOrCreate { XCTFail(); return nil }, result)
    }

    private func seededProfile(id: String) -> Profile {
        var profile = Profile()
        profile.profileID = id
        profile.lines = [Line(id: "direct", name: "直连", type: "direct"), Line(id: id + "-vpn", name: "Company", type: "vpn")]
        profile.lines[1].vpnServer = "vpn.example.test:8443"
        profile.ruleSets = [RuleSet(id: id + "-intranet", name: "Intranet", type: "manual", domains: ["corp.example"])]
        var office = Scenario(id: id + "-office", name: "Office", defaultLineID: "direct")
        office.matchSSIDs = ["CORP"]
        var remote = Scenario(id: id + "-remote", name: "Remote", defaultLineID: "direct")
        remote.bindings = [RuleBinding(ruleSetID: id + "-intranet", lineID: id + "-vpn")]
        remote.matchSSIDs = ["CORP-GUEST"]
        profile.scenarios = [office, remote]
        profile.activeScenarioID = remote.id
        return profile
    }

    private func existingLibrary(claiming ssids: [String]) throws -> ProfileLibrary {
        var library = ProfileLibrary()
        library.scenarios[0].matchSSIDs = ssids
        return try library.validated()
    }

    func testSeedLoadsOneNamedDocumentAndRejectsAmbiguousDirectories() throws {
        let home = try temporaryHome()
        let directory = home.appendingPathComponent("SeedProfile")
        XCTAssertNil(try SeedProfile.load(directory: directory))
        XCTAssertNil(try SeedProfile.load(directory: nil))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("seed document".utf8).write(to: directory.appendingPathComponent("公司.json"))
        XCTAssertEqual(try SeedProfile.load(directory: directory), SeedProfile(name: "公司", text: "seed document"))
        try Data("{}".utf8).write(to: directory.appendingPathComponent("Other.json"))
        XCTAssertThrowsError(try SeedProfile.load(directory: directory))
    }

    func testSeedCreatesEmptyLibraryOnceWithUnprefixedScenarios() throws {
        let home = try temporaryHome()
        let key = SymmetricKey(size: .bits256)
        let store = ProfileLibraryStore(directory: ConfigurationStorage.directory(home: home), keyProvider: { _ in key })
        var imports = 0
        let library = try store.loadOrCreate {
            try ProfileLibraryMigration.initialLibrary(home: home) { _, _ in XCTFail(); return Profile() }
                ?? ProfileLibraryMigration.seedLibrary(SeedProfile(name: "公司", text: "seed document")) { text, id in
                    imports += 1
                    XCTAssertEqual(text, "seed document")
                    return self.seededProfile(id: id)
                }
        }
        XCTAssertEqual(imports, 1)
        XCTAssertEqual(library.profiles.map(\.name), ["公司"])
        XCTAssertEqual(library.profiles[0].profile.profileID, library.profiles[0].id)
        XCTAssertEqual(library.scenarios.map(\.name), ["Office", "Remote"])
        XCTAssertEqual(library.scenarios[0].matchSSIDs, ["CORP"])
        XCTAssertEqual(library.scenarios.first { $0.id == library.activeScenarioID }?.name, "Remote")
        XCTAssertEqual(library.profiles[0].profile.lines.first { $0.type == "vpn" }?.vpnPassword, "")
        XCTAssertEqual(try store.loadOrCreate { XCTFail("must not seed twice"); return nil }, library)
    }

    func testSeedNeverCreatesLibraryWhenExistingConfigurationIsFound() throws {
        let home = try temporaryHome()
        _ = try writeLegacy(ProfileRecord.empty(named: "Old").profile, at: ConfigurationStorage.desktopLocations[0], home: home)
        let library = try ProfileLibraryMigration.initialLibrary(home: home, convertProfile: converted)
            ?? ProfileLibraryMigration.seedLibrary(SeedProfile(name: "公司", text: "")) { _, _ in XCTFail(); return Profile() }
        XCTAssertEqual(library?.profiles.map(\.name), ["默认配置"])
    }

    func testMissingSeedKeepsBuiltInDefault() throws {
        XCTAssertNil(try ProfileLibraryMigration.seedLibrary(nil) { _, _ in XCTFail(); return Profile() })
    }

    func testInvalidSeedDoesNotCreateLibrary() throws {
        let home = try temporaryHome()
        let store = ProfileLibraryStore(directory: ConfigurationStorage.directory(home: home), keyProvider: { _ in SymmetricKey(size: .bits256) })
        XCTAssertThrowsError(try store.loadOrCreate {
            try ProfileLibraryMigration.seedLibrary(SeedProfile(name: "公司", text: "")) { _, _ in
                throw ProfileLibraryError.invalid("bad seed")
            }
        })
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory.appendingPathComponent("profiles.enc").path))
    }

    func testSeedJoinsExistingLibraryWithoutChangingSelection() throws {
        let original = try existingLibrary(claiming: ["HOME"])
        let merged = try ProfileLibraryMigration.merging(seededProfile(id: "seed"), named: "公司", id: "seed", into: original)
        XCTAssertEqual(merged.profiles.map(\.name), ["默认配置", "公司"])
        XCTAssertEqual(merged.profiles.dropLast().map(\.self), original.profiles)
        XCTAssertEqual(merged.activeScenarioID, original.activeScenarioID)
        XCTAssertEqual(merged.editingProfileID, original.editingProfileID)
        XCTAssertEqual(merged.scenarios.first, original.scenarios.first)
        XCTAssertEqual(merged.scenarios.dropFirst().map(\.name), ["公司 · Office", "公司 · Remote"])
        XCTAssertEqual(merged.scenarios.dropFirst().map(\.matchSSIDs), [["CORP"], ["CORP-GUEST"]])
    }

    func testSeedLeavesClaimedWiFiTriggerWithExistingScenario() throws {
        let original = try existingLibrary(claiming: ["CORP"])
        let merged = try ProfileLibraryMigration.merging(seededProfile(id: "seed"), named: "公司", id: "seed", into: original)
        XCTAssertEqual(merged.scenarios.map(\.matchSSIDs), [["CORP"], [], ["CORP-GUEST"]])
    }

    private func refreshedSeed(id: String) -> Profile {
        var profile = seededProfile(id: id)
        profile.ruleSets[0].domains = ["corp.example", "corp2.example"]
        profile.ruleSets.append(RuleSet(id: id + "-ops", name: "Ops", type: "manual", domains: ["ops.example"]))
        profile.scenarios[0].matchSSIDs = ["CORP", "CORP-5G"]
        profile.scenarios[1].bindings.append(RuleBinding(ruleSetID: id + "-ops", lineID: id + "-vpn"))
        var travel = Scenario(id: id + "-travel", name: "Travel", defaultLineID: id + "-vpn")
        travel.matchSSIDs = ["HOTEL"]
        profile.scenarios.append(travel)
        return profile
    }

    func testSeedRefreshOverwritesOwnedContentButKeepsUserState() throws {
        var library = try ProfileLibraryMigration.merging(seededProfile(id: "seed"), named: "公司", id: "seed",
                                                          into: existingLibrary(claiming: ["HOTEL"]))
        let index = try XCTUnwrap(library.profiles.firstIndex { $0.id == "seed" })
        let vpn = try XCTUnwrap(library.profiles[index].profile.lines.firstIndex { $0.type == "vpn" })
        library.profiles[index].profile.lines[vpn].vpnUsername = "alice"
        library.profiles[index].profile.lines[vpn].vpnPassword = "saved-password"
        let office = try XCTUnwrap(library.scenarios.firstIndex { $0.id == "seed-office" })
        library.scenarios[office].name = "My Office"
        let active = library.activeScenarioID

        let refreshed = try ProfileLibraryMigration.refreshingSeed(refreshedSeed(id: "seed"), profileID: "seed",
                                                                   named: "公司", in: library)
        let record = try XCTUnwrap(refreshed.profiles.first { $0.id == "seed" })
        XCTAssertEqual(record.profile.ruleSets.first { $0.id == "seed-intranet" }?.domains, ["corp.example", "corp2.example"])
        XCTAssertEqual(record.profile.lines.first { $0.type == "vpn" }?.vpnUsername, "alice")
        XCTAssertEqual(record.profile.lines.first { $0.type == "vpn" }?.vpnPassword, "saved-password")
        XCTAssertEqual(refreshed.scenarios.first { $0.id == "seed-office" }?.name, "My Office")
        XCTAssertEqual(refreshed.scenarios.first { $0.id == "seed-office" }?.matchSSIDs, ["CORP", "CORP-5G"])
        XCTAssertEqual(refreshed.scenarios.first { $0.id == "seed-remote" }?.bindings.map(\.ruleSetID), ["seed-intranet", "seed-ops"])
        let travel = try XCTUnwrap(refreshed.scenarios.first { $0.id == "seed-travel" })
        XCTAssertEqual(travel.name, "公司 · Travel")
        XCTAssertEqual(travel.matchSSIDs, [], "HOTEL stays with the user's Scenario")
        XCTAssertEqual(refreshed.activeScenarioID, active)
        XCTAssertEqual(refreshed.editingProfileID, library.editingProfileID)
        XCTAssertEqual(refreshed.profiles.first, library.profiles.first)
    }

    /// The seed ships Lines without credentials; employees must be able to fill them in.
    func testSeedLineCredentialsBelongToTheUserButSubscriptionCredentialsDoNot() throws {
        let library = try ProfileLibraryMigration.merging(seededProfile(id: "seed"), named: "公司", id: "seed",
                                                          into: existingLibrary(claiming: []))
        let seed = try XCTUnwrap(library.profiles.first { $0.id == "seed" })
        XCTAssertNotNil(seed.baseline, "seed Lines stay source-owned")
        XCTAssertTrue(seed.lineCredentialsBelongToUser)

        var subscription = seed
        subscription.source = ProfileSource(url: "https://example.com/sub")
        XCTAssertFalse(subscription.lineCredentialsBelongToUser, "a refresh replaces subscription credentials")

        var line = Line(id: "vpn", name: "VPN", type: "vpn")
        var saved = line
        for field in Line.credentialFields { saved[keyPath: field] = "user" }
        line = line.keepingCredentials(of: saved)
        for field in Line.credentialFields {
            XCTAssertEqual(line[keyPath: field], "user", "\(field) is editable and therefore kept")
        }
    }

    /// Seed and subscription share the refresh merge; employees never subscribed to anything.
    func testSeedRefreshErrorsNameThePresetNotASubscription() throws {
        let library = try ProfileLibraryMigration.merging(seededProfile(id: "seed"), named: "公司", id: "seed",
                                                          into: existingLibrary(claiming: []))
        let warning = try JSONDecoder().decode(SubRule.self, from: Data(#"{"type":"USER-AGENT","value":"Example*","group":"Proxy"}"#.utf8))
        var incoming = refreshedSeed(id: "seed")
        incoming.importWarnings = [warning]
        XCTAssertThrowsError(try ProfileLibraryMigration.refreshingSeed(incoming, profileID: "seed", named: "公司", in: library)) {
            XCTAssertEqual($0.localizedDescription, "预置配置新增了无法执行的规则，已保留原配置")
        }

        var subscribed = library
        let index = try XCTUnwrap(subscribed.profiles.firstIndex { $0.id == "seed" })
        subscribed.profiles[index].source = ProfileSource(url: "https://example.com/sub")
        XCTAssertThrowsError(try subscribed.refreshing(profileID: "seed", incoming: incoming)) {
            XCTAssertEqual($0.localizedDescription, "订阅新增了无法执行的规则，已保留原配置")
        }
    }

    func testSeedRefreshCanDropARuleItsScenarioUsed() throws {
        let library = try ProfileLibraryMigration.merging(refreshedSeed(id: "seed"), named: "公司", id: "seed",
                                                          into: existingLibrary(claiming: []))
        let refreshed = try ProfileLibraryMigration.refreshingSeed(seededProfile(id: "seed"), profileID: "seed",
                                                                   named: "公司", in: library)
        XCTAssertNil(refreshed.profiles.first { $0.id == "seed" }?.profile.ruleSets.first { $0.id == "seed-ops" })
        XCTAssertEqual(refreshed.scenarios.first { $0.id == "seed-remote" }?.bindings.map(\.ruleSetID), ["seed-intranet"])
    }

    func testFirstLaunchSeedRefreshKeepsUnprefixedNames() throws {
        let created = try XCTUnwrap(ProfileLibraryMigration.seedLibrary(SeedProfile(name: "公司", text: "v1")) { _, id in
            self.seededProfile(id: id)
        })
        let id = created.profiles[0].id
        let refreshed = try ProfileLibraryMigration.refreshingSeed(refreshedSeed(id: id), profileID: id, named: "公司", in: created)
        XCTAssertEqual(refreshed.scenarios.map(\.name), ["Office", "Remote", "Travel"])
        XCTAssertEqual(refreshed.scenarios.last?.matchSSIDs, ["HOTEL"])
    }

    func testSeedLedgerRoundTripsAndStartsEmpty() throws {
        let url = SeedProfileLedger.url(directory: try temporaryHome())
        XCTAssertEqual(try SeedProfileLedger.load(from: url), SeedProfileLedger())
        var ledger = SeedProfileLedger()
        ledger.entries["公司"] = .init(profileID: "seed", digest: SeedProfile(name: "公司", text: "v1").digest)
        try ledger.save(to: url)
        XCTAssertEqual(try SeedProfileLedger.load(from: url), ledger)
        XCTAssertNotEqual(SeedProfile(name: "公司", text: "v1").digest, SeedProfile(name: "公司", text: "v2").digest)
    }

    func testSeedRefreshAdoptsARecordWithoutBaseline() throws {
        var library = try ProfileLibraryMigration.merging(seededProfile(id: "seed"), named: "公司", id: "seed",
                                                          into: existingLibrary(claiming: []))
        let index = try XCTUnwrap(library.profiles.firstIndex { $0.id == "seed" })
        library.profiles[index].baseline = nil
        let refreshed = try ProfileLibraryMigration.refreshingSeed(refreshedSeed(id: "seed"), profileID: "seed",
                                                                   named: "公司", in: library)
        XCTAssertEqual(refreshed.scenarios.map(\.id).filter { $0.hasPrefix("seed-") }, ["seed-office", "seed-remote", "seed-travel"])
        XCTAssertEqual(refreshed.scenarios.count, library.scenarios.count + 1)
    }
}
