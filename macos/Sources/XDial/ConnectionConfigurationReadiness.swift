import Foundation

/// 连接前能在宿主侧确定的配置缺口。它只回答“这个场景现在能不能发起连接、
/// 缺的是什么”，判定与 Go 生成器拒绝的条件一致：AnyConnect 只认启用的线路，
/// 服务器与用户名去掉空白后不能为空，密码不能为空。
struct ConnectionConfigurationBlocker: Equatable {
    enum MissingField: Equatable {
        case server
        case username
        case password
    }

    enum Reason: Equatable {
        /// 空场景是合法草稿，但没有默认出口时不能连接。
        case noDefaultTarget
        case incompleteAnyConnect(lineID: String, lineName: String, missing: [MissingField])
    }

    let scenarioID: String
    let scenarioName: String
    let reason: Reason

    var lineID: String? {
        if case let .incompleteAnyConnect(lineID, _, _) = reason { return lineID }
        return nil
    }

    static func evaluate(_ scenario: Scenario, in profile: Profile) -> ConnectionConfigurationBlocker? {
        func blocked(_ reason: Reason) -> ConnectionConfigurationBlocker {
            ConnectionConfigurationBlocker(scenarioID: scenario.id, scenarioName: scenario.name, reason: reason)
        }
        guard !scenario.defaultLineID.isEmpty || !scenario.defaultSubscriptionID.isEmpty else {
            return blocked(.noDefaultTarget)
        }
        var lineIDs = scenario.bindings.map(\.lineID)
        lineIDs.append(scenario.defaultLineID)
        for lineID in lineIDs where !lineID.isEmpty {
            guard let line = profile.lines.first(where: { $0.id == lineID }),
                  line.enabled, line.type == "vpn" else { continue }
            var missing: [MissingField] = []
            if line.vpnServer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { missing.append(.server) }
            if line.vpnUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { missing.append(.username) }
            if line.vpnPassword.isEmpty { missing.append(.password) }
            if !missing.isEmpty {
                return blocked(.incompleteAnyConnect(lineID: line.id, lineName: line.name, missing: missing))
            }
        }
        return nil
    }

    func title(_ tr: (String, String) -> String) -> String {
        tr("“\(scenarioName)”无法连接", "“\(scenarioName)” cannot connect")
    }

    func detail(_ tr: (String, String) -> String) -> String {
        switch reason {
        case .noDefaultTarget:
            return tr("这个场景还没有设置默认出口。", "This scenario has no default route yet.")
        case let .incompleteAnyConnect(_, lineName, missing):
            let zh = missing.map { field -> String in
                switch field {
                case .server: return "服务器"
                case .username: return "用户名"
                case .password: return "密码"
                }
            }.joined(separator: "、")
            let en = missing.map { field -> String in
                switch field {
                case .server: return "server"
                case .username: return "username"
                case .password: return "password"
                }
            }.joined(separator: ", ")
            return tr(
                "AnyConnect 线路“\(lineName)”未填写\(zh)。",
                "AnyConnect line “\(lineName)” is missing its \(en)."
            )
        }
    }

    func actionTitle(_ tr: (String, String) -> String) -> String {
        switch reason {
        case .noDefaultTarget: return tr("去设置", "Set Up")
        case .incompleteAnyConnect: return tr("去填写", "Fill In")
        }
    }
}
