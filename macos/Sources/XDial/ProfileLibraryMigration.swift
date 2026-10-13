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
        return try library(with: ProfileRecord(id: id, name: seed.name, profile: importDocument(seed.text, id)))
    }

    /// Adds the seed beside existing Profiles like a file import, without changing
    /// the active Scenario or the edited Profile. A Wi-Fi trigger already owned by
    /// an existing Scenario stays there instead of rejecting the whole seed.
    static func merging(_ seed: Profile, named name: String, id: String,
                        into library: ProfileLibrary) throws -> ProfileLibrary {
        var record = ProfileRecord(id: id, name: name, profile: seed)
        let claimed = Set(library.scenarios.flatMap(\.matchSSIDs))
        for index in record.profile.scenarios.indices {
            record.profile.scenarios[index].matchSSIDs.removeAll(where: claimed.contains)
        }
        var result = library
        try result.insert(record)
        result.editingProfileID = library.editingProfileID
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
    static let appliedDefaultsKey = "xdial.appliedSeedProfiles"

    let name: String
    let text: String

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
