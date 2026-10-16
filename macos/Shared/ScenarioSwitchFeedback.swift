import Foundation

/// An allowlisted observation for the developer feedback loop. This is never
/// a ConnectionReport and must not become input to the connection state machine.
struct ScenarioSwitchFeedback: Codable, Equatable {
    let id: String
    let startedAt: Date
    var observedAt: Date
    var status: String
    var inFlight: Bool
    var activeRelationship: String
    var candidateState: String
    var cancellationRequested: Bool
    var timedOut: Bool
    var errorCode: String?
    var failedTaskKinds: [String]
    var transitions: [String]
    let sameScenario: Bool?
    let channel: String
    let sourceRevision: String
    let buildVersion: String

    static let statuses: Set<String> = [
        "capturing-underlay", "preparing", "cancelling", "cancelling-after-timeout",
        "reconciling", "committed", "failed", "cancelled", "timed-out", "no-op", "rejected", "interrupted",
    ]
    // Codes outside this set are represented without copying arbitrary text.
    static let errorCodes: Set<String> = [
        "switch-cancelled", "switch-timeout", "switch-host-failed",
        "switch-source-changed", "switch-outcome-unknown", "underlay-capture-failed",
        "network-superseded", "provider-session-lost", "switch-in-progress",
        "line-readiness-transient", "full-reconnect-required", "switch-failed",
        "switch-invalid-response", "switch-unavailable", "switch-plan-invalid", "user-disconnected",
        "switch-anyconnect-rebuild-required", "switch-rule-set-preflight-unavailable",
    ]
    static let taskKinds: Set<String> = [
        "line", "rule-set", "ruleset", "ingress", "data-plane", "resource",
        "engine", "dns", "route", "box", "runtime", "system",
    ]

    init(
        id: String, startedAt: Date, observedAt: Date = Date(),
        status: String, inFlight: Bool, sourceTransactionID: String,
        targetTransactionID: String, activeTransactionID: String,
        candidate: ConnectionReport?, sameScenario: Bool?,
        cancellationRequested: Bool = false, timedOut: Bool = false,
        code: String? = nil, channel: String = XDialBuildIdentity.tailscaleDeviceChannel
    ) {
        self.id = id
        self.startedAt = startedAt
        self.observedAt = observedAt
        self.status = Self.statuses.contains(status) ? status : "unknown"
        self.inFlight = inFlight
        if activeTransactionID.isEmpty {
            activeRelationship = "unknown"
        } else if activeTransactionID == targetTransactionID {
            activeRelationship = "target"
        } else if activeTransactionID == sourceTransactionID {
            activeRelationship = "source"
        } else {
            activeRelationship = "other"
        }
        candidateState = candidate?.state.rawValue ?? "unavailable"
        self.cancellationRequested = cancellationRequested
        self.timedOut = timedOut
        errorCode = code.map { Self.errorCodes.contains($0) ? $0 : "unclassified" }
        failedTaskKinds = Array(Set((candidate?.tasks ?? []).filter { $0.error != nil }.map {
            Self.taskKinds.contains($0.kind) ? $0.kind : "other"
        })).sorted()
        transitions = [self.status]
        self.sameScenario = sameScenario
        self.channel = ["debug", "next", "stable"].contains(channel) ? channel : "unknown"
        let revision = Bundle.main.object(forInfoDictionaryKey: "XDialSourceRevision") as? String ?? ""
        sourceRevision = revision.range(of: "^[a-f0-9]{40}$", options: .regularExpression) != nil
            ? revision : "unversioned"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        buildVersion = build.range(of: "^[0-9]{1,20}$", options: .regularExpression) != nil
            ? build : "unknown"
    }
}

struct ScenarioSwitchFeedbackHistory: Codable, Equatable {
    var schemaVersion = 1
    var observations: [ScenarioSwitchFeedback] = []

    /// Progress polling is frequent. Persist only meaningful transitions and
    /// terminal facts, and never let a late progress sample reopen an attempt.
    mutating func record(_ observation: ScenarioSwitchFeedback, limit: Int = 200) -> Bool {
        if let index = observations.firstIndex(where: { $0.id == observation.id }) {
            let previous = observations[index]
            guard previous.inFlight else { return false }
            guard previous.status != observation.status
                || previous.inFlight != observation.inFlight else { return false }
            var updated = observation
            updated.cancellationRequested = previous.cancellationRequested || observation.cancellationRequested
            updated.timedOut = previous.timedOut || observation.timedOut
            updated.transitions = Array((previous.transitions + [observation.status]).suffix(20))
            observations[index] = updated
        } else {
            observations.append(observation)
        }
        if observations.count > max(1, limit) {
            observations.removeFirst(observations.count - max(1, limit))
        }
        return true
    }
}

/// Host-only asynchronous persistence. No API keys, model calls, GitHub access,
/// raw profiles, source/scenario identities, fingerprints, names or messages.
final class ScenarioSwitchFeedbackRecorder {
    static let shared = ScenarioSwitchFeedbackRecorder()
    static var directoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs")
            .appendingPathComponent(XDialBuildIdentity.logDirectoryName)
            .appendingPathComponent("jev", isDirectory: true)
    }
    private let queue = DispatchQueue(label: "com.kafeifei.xdial.switch-feedback", qos: .utility)
    private let fileURL: URL
    private var history: ScenarioSwitchFeedbackHistory?

    init(directory: URL = ScenarioSwitchFeedbackRecorder.directoryURL) {
        fileURL = directory.appendingPathComponent("scenario-switch-observations.json")
    }

    func record(_ observation: ScenarioSwitchFeedback) {
        queue.async { [self] in
            do { try persist(observation) }
            catch {
                // Keep failure reporting free of file contents and error text.
                NSLog("XDial scenario switch feedback could not be persisted")
            }
        }
    }

    // Synchronous entry also permits deterministic tests using temporary paths.
    func persist(_ observation: ScenarioSwitchFeedback) throws {
        let fm = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        if history == nil {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if fm.fileExists(atPath: fileURL.path) {
                // A corrupt journal must not silently destroy prior evidence.
                history = try decoder.decode(ScenarioSwitchFeedbackHistory.self,
                                             from: Data(contentsOf: fileURL))
            } else {
                history = ScenarioSwitchFeedbackHistory()
            }
        }
        var updated = history!
        guard updated.record(observation) else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(updated).write(to: fileURL, options: [.atomic])
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        history = updated
    }
}
