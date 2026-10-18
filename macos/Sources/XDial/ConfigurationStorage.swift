import Foundation

/// Configuration belongs to the product, not its formal or Debug identity.
/// Runtime directories and system component identities remain identity-owned.
enum ConfigurationStorage {
    static let keychainService = "com.kafeifei.xdial.configuration"
    static let directoryPath = ".xdial/configuration"

    static func directory(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(directoryPath)
    }

    struct LegacyLocation: Equatable {
        let preferencesPath: String
        let dataPath: String
        let keychainService: String
    }

    static let desktopLocations: [LegacyLocation] = [
        .init(preferencesPath: "Library/Preferences/com.kafeifei.xdial.plist",
              dataPath: ".xdial", keychainService: "com.kafeifei.xdial"),
        .init(preferencesPath: "Library/Preferences/com.kafeifei.xdial.debug.plist",
              dataPath: ".xdial-debug", keychainService: "com.kafeifei.xdial.debug"),
        // The retired Next identity is still a read-only migration source and
        // part of "delete data": developer machines can hold its library.
        .init(preferencesPath: "Library/Preferences/com.kafeifei.xdial.next.plist",
              dataPath: ".xdial-next", keychainService: "com.kafeifei.xdial.next"),
    ]

    static let legacyLocations = desktopLocations + [
        LegacyLocation(
            preferencesPath: "Library/Containers/com.kafeifei.xdial/Data/Library/Preferences/com.kafeifei.xdial.plist",
            dataPath: "Library/Containers/com.kafeifei.xdial/Data/.xdial",
            keychainService: "com.kafeifei.xdial"
        ),
    ]

    static var preferenceDomains: [String] { desktopLocations.map(\.keychainService) }
    static var keychainServices: [String] { preferenceDomains + [keychainService] }
}
