import CryptoKit
import Foundation

enum ProfileLibraryMigration {
    /// Pre-shared Next libraries already contain user edits and multiple Profiles.
    /// Preserve the whole latest library before considering older single Profiles.
    static func initialLibrary(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        readLibrary: ((ConfigurationStorage.LegacyLocation) throws -> ProfileLibrary?)? = nil,
        readProfile: ((ConfigurationStorage.LegacyLocation) throws -> Profile?)? = nil,
        convertProfile: (Profile, String) throws -> Profile
    ) throws -> ProfileLibrary? {
        func modified(_ path: String) -> Date {
            (try? home.appendingPathComponent(path).resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
        }
        let libraries = ConfigurationStorage.legacyLocations.filter {
            FileManager.default.fileExists(atPath: home.appendingPathComponent($0.dataPath + "/profiles.enc").path)
        }.sorted {
            modified($0.dataPath + "/profiles.enc") > modified($1.dataPath + "/profiles.enc")
        }
        if let source = libraries.first {
            let library: ProfileLibrary?
            if let readLibrary { library = try readLibrary(source) }
            else {
                library = try ProfileLibraryStore(directory: home.appendingPathComponent(source.dataPath),
                                                  keychainService: source.keychainService).load()
            }
            guard let library else {
                throw ProfileLibraryError.invalid("旧配置库在转换期间发生变化，请稍后重试")
            }
            return library
        }
        let candidates = try ConfigurationStorage.legacyLocations.filter {
            try ExistingXDialProfileReader.profileData(at: $0, home: home) != nil
        }.sorted { modified($0.preferencesPath) > modified($1.preferencesPath) }
        guard let source = candidates.first else { return nil }
        let original: Profile?
        if let readProfile { original = try readProfile(source) }
        else { original = try ExistingXDialProfileReader.read(source, home: home) }
        guard let original else {
            throw ProfileLibraryError.invalid("旧版配置在转换期间发生变化，请稍后重试")
        }
        let id = UUID().uuidString.lowercased()
        return try library(with: ProfileRecord(id: id, name: "默认配置", profile: convertProfile(original, id)))
    }

    /// An empty library is created from the seed as is: its Scenarios keep their own names.
    static func seedLibrary(
        _ seed: SeedProfile?,
        importDocument: (String, String) throws -> Profile
    ) throws -> ProfileLibrary? {
        guard let seed else { return nil }
        let id = UUID().uuidString.lowercased()
        let imported = try importDocument(seed.text, id)
        return try library(with: ProfileRecord(id: id, name: seed.name, profile: imported, baseline: imported))
    }

    /// Adds the seed beside existing Profiles like a file import, without changing
    /// the active Scenario or the edited Profile. A Wi-Fi trigger already owned by
    /// an existing Scenario stays there instead of rejecting the whole seed.
    static func merging(_ seed: Profile, named name: String, id: String,
                        into library: ProfileLibrary) throws -> ProfileLibrary {
        var imported = seed
        let claimed = Set(library.scenarios.flatMap(\.matchSSIDs))
        for index in imported.scenarios.indices {
            imported.scenarios[index].matchSSIDs.removeAll(where: claimed.contains)
        }
        var result = library
        try result.insert(ProfileRecord(id: id, name: name, profile: imported, baseline: imported))
        result.editingProfileID = library.editingProfileID
        return result
    }

    /// A newer seed overwrites the content it owns, like a subscription refresh, but
    /// keeps what only the user can supply: credentials, Scenario names and triggers
    /// claimed by other Scenarios. The active Scenario and the edited Profile stay.
    static func refreshingSeed(_ seed: Profile, profileID: String, named name: String,
                               in library: ProfileLibrary) throws -> ProfileLibrary {
        guard let old = library.profiles.first(where: { $0.id == profileID }) else {
            throw ProfileLibraryError.invalid("预置配置已被删除")
        }
        let owned = Set(library.scenarioSources.filter { $0.value == profileID }.keys)
        // Routing is replaced below; detaching it first lets the seed drop a bound rule.
        var detached = library
        if let index = detached.profiles.firstIndex(where: { $0.id == profileID }), old.baseline == nil {
            // Without a recorded baseline the seed's Scenarios would look foreign and be duplicated.
            var baseline = old.profile
            baseline.scenarios = library.scenarios.filter { owned.contains($0.id) }
            detached.profiles[index].baseline = baseline
        }
        for index in detached.scenarios.indices where owned.contains(detached.scenarios[index].id) {
            detached.scenarios[index].bindings = []
            detached.scenarios[index].matchOrder = []
        }
        var result = try detached.refreshing(profileID: profileID, incoming: seed)
        guard let index = result.profiles.firstIndex(where: { $0.id == profileID }),
              let incoming = result.profiles[index].baseline else {
            throw ProfileLibraryError.invalid("无法刷新预置配置")
        }
        for lineIndex in result.profiles[index].profile.lines.indices {
            let line = result.profiles[index].profile.lines[lineIndex]
            guard let saved = old.profile.lines.first(where: { $0.id == line.id }) else { continue }
            result.profiles[index].profile.lines[lineIndex] = line.keepingCredentials(of: saved)
        }
        let claimed = Set(library.scenarios.filter { !owned.contains($0.id) }.flatMap(\.matchSSIDs))
        for var scene in incoming.scenarios {
            scene.matchSSIDs.removeAll(where: claimed.contains)
            if let existing = result.scenarios.firstIndex(where: { $0.id == scene.id }) {
                guard owned.contains(scene.id) else { continue }
                scene.name = result.scenarios[existing].name
                scene.iconOverride = result.scenarios[existing].iconOverride
                result.scenarios[existing] = scene
            } else {
                if library.profiles.count > 1 { scene.name = name + " · " + scene.name }
                result.scenarios.append(scene)
                result.scenarioSources[scene.id] = profileID
            }
        }
        // Scenarios the seed no longer declares stay as the user's own, routing intact.
        for scene in library.scenarios where owned.contains(scene.id) && !incoming.scenarios.contains(where: { $0.id == scene.id }) {
            if let existing = result.scenarios.firstIndex(where: { $0.id == scene.id }) { result.scenarios[existing] = scene }
        }
        result.editingProfileID = library.editingProfileID
        try result.validateReferences(allowEmptyGroups: true)
        return result
    }

    private static func library(with record: ProfileRecord) throws -> ProfileLibrary {
        var library = ProfileLibrary()
        library.schemaVersion = 2
        library.groups = []; library.scenarios = []; library.activeScenarioID = ""
        library.profiles = [record]
        library.activeProfileID = record.id
        library.editingProfileID = record.id
        return try library.validated()
    }
}

/// A Profile document embedded by an enterprise build. Its file name is the
/// Profile name, as with "Import from File".
struct SeedProfile: Equatable {
    let name: String
    let text: String

    var digest: String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func load(
        directory: URL? = Bundle.main.resourceURL?.appendingPathComponent("SeedProfile", isDirectory: true)
    ) throws -> SeedProfile? {
        guard let directory, FileManager.default.fileExists(atPath: directory.path) else { return nil }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        guard files.count == 1, let file = files.first else {
            throw ProfileLibraryError.invalid("预置配置必须恰好是一个 JSON 文件")
        }
        let data = try Data(contentsOf: file)
        let name = file.deletingPathExtension().lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard data.count <= 4 * 1024 * 1024, let text = String(data: data, encoding: .utf8), !name.isEmpty else {
            throw ProfileLibraryError.invalid("预置配置必须为有名称的 UTF-8 文本，且不能超过 4 MiB")
        }
        return SeedProfile(name: name, text: text)
    }
}

/// Which library Profile each seed became and which content it last applied.
/// It lives beside the shared library rather than inside it, because older
/// versions rewrite the library without fields they do not know.
struct SeedProfileLedger: Codable, Equatable {
    struct Entry: Codable, Equatable {
        var profileID: String
        var digest: String
    }

    var entries: [String: Entry] = [:]

    static func url(directory: URL = ConfigurationStorage.directory()) -> URL {
        directory.appendingPathComponent("seed-profiles.json")
    }

    static func load(from url: URL = url()) throws -> SeedProfileLedger {
        guard FileManager.default.fileExists(atPath: url.path) else { return SeedProfileLedger() }
        return try JSONDecoder().decode(SeedProfileLedger.self, from: Data(contentsOf: url))
    }

    func save(to url: URL = url()) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

private extension Line {
    /// Seeds never carry secrets; a value the user saved survives a seed refresh.
    func keepingCredentials(of saved: Line) -> Line {
        var line = self
        func keep(_ field: WritableKeyPath<Line, String>) {
            if line[keyPath: field].isEmpty { line[keyPath: field] = saved[keyPath: field] }
        }
        for field in [\Line.vpnUsername, \.vpnPassword, \.trojanPassword, \.ssPassword, \.vmessUUID, \.anytlsPassword] {
            keep(field)
        }
        return line
    }
}
