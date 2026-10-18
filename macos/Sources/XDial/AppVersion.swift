import Foundation

/// A published release tag: `vX.Y.Z` for the stable channel and
/// `vX.Y.Z-beta.N` for beta. Ordering follows SemVer: X.Y.Z first, a beta
/// sorts below the release with the same X.Y.Z, and betas order by N.
struct ReleaseTag: Comparable, Hashable, Sendable,
    CustomStringConvertible
{
    let major: Int
    let minor: Int
    let patch: Int
    /// nil for a stable release.
    let beta: Int?

    /// Accepts exactly
    /// `^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-beta\.[1-9][0-9]*)?$`.
    init?(_ tag: String) {
        guard tag.first == "v" else { return nil }
        let value = tag.dropFirst()
        let core: Substring
        var beta: Int?
        if let dash = value.firstIndex(of: "-") {
            core = value[..<dash]
            let suffix = value[value.index(after: dash)...]
            guard suffix.hasPrefix("beta."),
                  let number = Self.number(
                      suffix.dropFirst("beta.".count),
                      allowsZero: false
                  ) else {
                return nil
            }
            beta = number
        } else {
            core = value
        }
        let parts = core.split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        guard parts.count == 3,
              let major = Self.number(parts[0], allowsZero: true),
              let minor = Self.number(parts[1], allowsZero: true),
              let patch = Self.number(parts[2], allowsZero: true) else {
            return nil
        }
        self.major = major
        self.minor = minor
        self.patch = patch
        self.beta = beta
    }

    var isBeta: Bool { beta != nil }

    /// The X.Y.Z every component of the release reports as its short version.
    var version: String { "\(major).\(minor).\(patch)" }

    var description: String {
        "v\(version)" + (beta.map { "-beta.\($0)" } ?? "")
    }

    static func < (lhs: ReleaseTag, rhs: ReleaseTag) -> Bool {
        let left = (lhs.major, lhs.minor, lhs.patch)
        let right = (rhs.major, rhs.minor, rhs.patch)
        if left != right { return left < right }
        switch (lhs.beta, rhs.beta) {
        case let (left?, right?): return left < right
        case (.some, nil): return true
        case (nil, _): return false
        }
    }

    private static func number(
        _ value: Substring,
        allowsZero: Bool
    ) -> Int? {
        guard let first = value.utf8.first,
              value.utf8.allSatisfy({ (48 ... 57).contains($0) }),
              first != 48 || (allowsZero && value.utf8.count == 1) else {
            return nil
        }
        return Int(value)
    }
}

enum VersionUpdatePolicy {
    static func stableReleaseVersion(fromTag tag: String) -> String? {
        guard tag.first == "v" else { return nil }
        let value = tag.dropFirst()
        let parts = value.split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        guard parts.count == 3,
              parts.allSatisfy({ part in
                  !part.isEmpty
                      && part.utf8.allSatisfy { (48 ... 57).contains($0) }
                      && (part == "0" || part.first != "0")
              }) else {
            return nil
        }
        return String(value)
    }

    static func stableVersion(fromTag tag: String) -> String? {
        var value = tag.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if value.first == "v" || value.first == "V" {
            value.removeFirst()
        }
        let parts = value.split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        guard !parts.isEmpty,
              parts.allSatisfy({ !$0.isEmpty && Int($0) != nil }) else {
            return nil
        }
        return value
    }

    /// The comparison stable clients used before release tags carried a
    /// channel. It remains the fallback for an installed short version that is
    /// not a canonical X.Y.Z, and the reference the tag ordering must match.
    static func isNewer(
        latestTag: String,
        than currentVersion: String
    ) -> Bool {
        guard let latest = NumericVersion(latestTag),
              let current = NumericVersion(currentVersion) else {
            return false
        }
        return current < latest
    }

    private struct NumericVersion: Comparable {
        let components: [Int]

        init?(_ rawValue: String) {
            var value = rawValue.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if value.first == "v" || value.first == "V" {
                value.removeFirst()
            }
            guard let core = value.split(
                separator: "-",
                maxSplits: 1,
                omittingEmptySubsequences: true
            ).first else {
                return nil
            }
            let parts = core.split(
                separator: ".",
                omittingEmptySubsequences: false
            )
            guard !parts.isEmpty else { return nil }
            let parsed = parts.compactMap { Int($0) }
            guard parsed.count == parts.count else { return nil }
            components = parsed
        }

        static func < (lhs: NumericVersion, rhs: NumericVersion) -> Bool {
            let count = max(lhs.components.count, rhs.components.count)
            for index in 0..<count {
                let left = index < lhs.components.count
                    ? lhs.components[index]
                    : 0
                let right = index < rhs.components.count
                    ? rhs.components[index]
                    : 0
                if left != right { return left < right }
            }
            return false
        }
    }
}
