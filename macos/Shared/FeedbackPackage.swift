import Foundation

enum FeedbackKind: String, CaseIterable {
    case problem, diagnosis, configuration, suggestion
}

/// Only these facts cross the feedback boundary. Never encode a full report,
/// profile, raw log, resource name, address, fingerprint or error message.
struct FeedbackRuntimeSnapshot: Encodable {
    let capturedAt: Date
    let connectionStatus: String
    let installationState: InstallationTransactionState
    let hasUnappliedChanges: Bool
    let connection: Report?
    let scenarioSwitch: Switch?

    struct Task: Encodable {
        let kind: String
        let state: ConnectionTaskState
        let errorCode: String?
    }

    struct Event: Encodable {
        let timestamp: Date
        let type: String
        let state: String
        let code: String?
    }

    struct Report: Encodable {
        let state: ConnectionTransactionState
        let startedAt: Date
        let updatedAt: Date
        let rollbackComplete: Bool
        let systemTakeoverRemoved: Bool
        let errorCode: String?
        let tasks: [Task]
        let recentEvents: [Event]

        init(_ report: ConnectionReport) {
            state = report.state
            startedAt = report.startedAt
            updatedAt = report.updatedAt
            rollbackComplete = report.rollbackComplete
            systemTakeoverRemoved = report.systemTakeoverRemoved
            errorCode = FeedbackRuntimeSnapshot.safeCode(report.error?.code)
            tasks = report.tasks.prefix(40).map {
                Task(kind: ScenarioSwitchFeedback.taskKinds.contains($0.kind) ? $0.kind : "other",
                     state: $0.state, errorCode: FeedbackRuntimeSnapshot.safeCode($0.error?.code))
            }
            let states = Set(["planning", "preparing", "ready_to_commit", "committing", "committed",
                              "rolling_back", "rolled_back", "failed", "cancelled", "pending", "running", "ready", "skipped"])
            recentEvents = report.events.suffix(20).map {
                Event(timestamp: $0.timestamp,
                      type: ["transaction", "task", "diagnostic"].contains($0.type) ? $0.type : "other",
                      state: states.contains($0.state) ? $0.state : "unknown",
                      code: FeedbackRuntimeSnapshot.safeCode($0.code.isEmpty ? nil : $0.code))
            }
        }
    }

    struct Switch: Encodable {
        let status: String
        let inFlight: Bool
        let activeRelationship: String
        let errorCode: String?
        let candidate: Report

        init(_ projection: HostScenarioSwitchProjection) {
            status = ScenarioSwitchFeedback.statuses.contains(projection.status) ? projection.status : "unknown"
            inFlight = projection.inFlight
            if projection.activeCommittedTransactionID.isEmpty {
                activeRelationship = "unknown"
            } else if projection.activeCommittedTransactionID == projection.candidateTransactionID {
                activeRelationship = "target"
            } else if projection.activeCommittedTransactionID == projection.sourceCommittedTransactionID {
                activeRelationship = "source"
            } else {
                activeRelationship = "other"
            }
            errorCode = FeedbackRuntimeSnapshot.safeCode(projection.code)
            candidate = Report(projection.candidateReport)
        }
    }

    init(connectionStatus: String, installationState: InstallationTransactionState,
         hasUnappliedChanges: Bool, connection: ConnectionReport?, scenarioSwitch: HostScenarioSwitchProjection?,
         capturedAt: Date = Date()) {
        self.capturedAt = capturedAt
        self.connectionStatus = ["connected", "disconnected", "connecting", "disconnecting", "reconnecting"].contains(connectionStatus)
            ? connectionStatus : "unknown"
        self.installationState = installationState
        self.hasUnappliedChanges = hasUnappliedChanges
        self.connection = connection.map(Report.init)
        self.scenarioSwitch = scenarioSwitch.map(Switch.init)
    }

    private static func safeCode(_ code: String?) -> String? {
        guard let code else { return nil }
        let known = ScenarioSwitchFeedback.errorCodes.union([
            "underlay-egress-unavailable", "scenario-switch-prepare-failed",
            "provider-start-failed", "engine-start-failed", "rollback-network-settings-failed",
            "system-disconnect-confirmed", "invalid-connection-plan",
        ])
        return known.contains(code) ? code : "unclassified"
    }
}

struct FeedbackPackage {
    static let descriptionLimit = 8_000
    let kind: FeedbackKind
    let description: String
    let runtime: FeedbackRuntimeSnapshot?
    let createdAt: Date
    let version: String
    let build: String
    let revision: String
    let channel: String

    init(kind: FeedbackKind, description: String, runtime: FeedbackRuntimeSnapshot?,
         createdAt: Date = Date(), bundle: Bundle = .main) {
        self.kind = kind
        self.description = String(description.prefix(Self.descriptionLimit))
        self.runtime = runtime
        self.createdAt = createdAt
        func metadata(_ key: String, pattern: String) -> String {
            guard let value = bundle.object(forInfoDictionaryKey: key) as? String,
                  value.range(of: pattern, options: .regularExpression) != nil else { return "unknown" }
            return value
        }
        version = metadata("CFBundleShortVersionString", pattern: "^[0-9]+(?:\\.[0-9]+){0,3}$")
        build = metadata("CFBundleVersion", pattern: "^[0-9]{1,20}$")
        revision = metadata("XDialSourceRevision", pattern: "^[a-f0-9]{40}$")
        channel = XDialBuildIdentity.tailscaleDeviceChannel
    }

    func text(english: Bool) throws -> String {
        let goal: String
        switch kind {
        case .problem:
            goal = english ? "Help verify and document a reported XDial problem. Separate observed facts from hypotheses; describe reproduction steps, expected and actual behavior, and missing evidence."
                : "请协助确认并整理 XDial 问题反馈。区分观察事实与推测，整理复现步骤、预期与实际行为，以及仍缺少的证据。"
        case .diagnosis:
            goal = english ? "Help diagnose an XDial failure. Start with the supplied evidence, propose a minimal investigation, record attempted actions and results, and retest before claiming a resolution."
                : "请协助排查 XDial 故障。从附带证据出发，提出最小排查步骤，记录尝试与结果；只有复测通过才能判断已解决。"
        case .suggestion:
            goal = english ? "Help clarify an XDial feature suggestion: the need, current friction, desired behavior, and acceptance examples. Do not classify a suggestion as a confirmed defect."
                : "请协助整理 XDial 功能建议：使用需求、当前不便、期望行为和验收示例。不要把建议直接判定为已确认的故障。"
        case .configuration:
            goal = english ? "Help adjust XDial configuration to match the user's desired traffic behavior. Clarify the goal and explain the proposed changes first. Use XDial's settings UI or a verified supported interface, within the assistant's permissions. Never directly edit the encrypted profile store or Keychain. Saving is separate from applying: the user decides when to apply and reconnect."
                : "请协助调整 XDial 配置，实现用户想要的分流效果。先明确目标并说明修改方案，在助手已有权限内通过 XDial 设置界面或已核实的受支持接口操作。不要直接修改加密配置库或钥匙串。保存配置与应用配置独立，由用户决定何时应用并重连。"
        }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let date = ISO8601DateFormatter().string(from: createdAt)
        var result = """
        XDial — \(english ? "Feedback & Diagnosis" : "反馈与诊断")
        \(goal)

        \(english ? "User description (user-provided text):" : "用户描述（用户自行填写）：")
        ---
        \(description.isEmpty ? (english ? "No description supplied. Ask what happened before drawing conclusions." : "尚未填写描述。请先询问具体现象，不要直接下结论。") : description)
        ---

        \(english ? "Application:" : "应用信息：")
        app=\(XDialBuildIdentity.productTitle) bundle_id=\(XDialBuildIdentity.applicationIdentifier)
        version=\(version) build=\(build) channel=\(channel)
        source=\(revision)
        macOS=\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)
        created_at=\(date)
        """
        if kind == .configuration {
            result += "\n\n" + (english
                ? "Configuration map: Settings → Lines / Rules / Line Groups / Scenarios. A Line provides an exit, a Rule describes matching traffic, and a Scenario binds Rules to Lines and chooses a default exit. Saving changes does not replace the running connection. This package contains no configuration values; ask the user for the necessary context or inspect it through authorized UI access. Do not invent CLI commands, HTTP endpoints or a configuration schema.\n"
                : "配置入口：设置 → 线路／规则／线路组／场景。线路提供出口，规则描述匹配流量，场景把规则绑定到线路并选择默认出口。保存修改不替换当前连接。此文件未附带配置值；请向用户确认必要上下文，或通过已授权的界面访问查看。不要编造 CLI 命令、HTTP 接口或配置格式。\n")
        }
        if let runtime {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            result += "\n\n" + (english ? "Allowlisted runtime facts (snapshot, not live state):\n" : "白名单运行事实（采集时快照，并非实时状态）：\n")
            result += String(decoding: try encoder.encode(runtime), as: UTF8.self)
        }
        result += "\n\n" + (english
            ? "The automatic snapshot excludes profiles, credentials, names, addresses, raw logs and raw errors. User text is included as written. A missing field is not proof of success. Opening the assistant does not submit feedback to the developer.\nBefore changing configuration, disconnecting, restarting, uploading data or submitting an issue, explain the action and obtain the user's authorization. Finish with: confirmed facts; hypotheses; attempted actions and results; resolved and retested / unresolved / insufficient evidence; next step.\n"
            : "自动快照不含配置、凭据、名称、地址、原始日志与原始错误；用户输入按原文保留。缺少字段不代表成功。打开助手不表示已向开发者提交反馈。\n修改配置、断开连接、重启、上传资料或创建问题卡片前，应说明动作并取得用户授权。最后整理：已确认事实、待验证假设、尝试与结果、已解决并复测／未解决／证据不足，以及下一步。\n")
        return result
    }

    /// Each handoff is a new private file, so edits and retries never replace
    /// an earlier problem's evidence. Files remain available after app closure.
    func write(text: String, under root: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent("XDial-feedback.txt")
        try Data(text.utf8).write(to: file, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return file
    }
}
