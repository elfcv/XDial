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

    /// A build may embed one portable Profile document for machines without any
    /// saved configuration. It is never merged into or substituted for an existing library.
    static func seedLibrary(
        resource: URL? = Bundle.main.url(forResource: "SeedProfile", withExtension: "json"),
        importDocument: (String, String) throws -> Profile
    ) throws -> ProfileLibrary? {
        guard let url = resource else { return nil }
        let data = try Data(contentsOf: url)
        guard data.count <= 4 * 1024 * 1024, let text = String(data: data, encoding: .utf8) else {
            throw ProfileLibraryError.invalid("预置配置必须为 UTF-8 文本，且不能超过 4 MiB")
        }
        let id = UUID().uuidString.lowercased()
        return try library(with: ProfileRecord(id: id, name: "默认配置", profile: importDocument(text, id)))
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
