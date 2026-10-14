import XCTest

final class ConnectionConfigurationBlockerTests: XCTestCase {
    private func vpn(_ id: String, username: String = "user", password: String = "secret", enabled: Bool = true) -> Line {
        var line = Line(id: id, name: "AnyConnect", type: "vpn")
        line.enabled = enabled
        line.vpnServer = "vpn.example.com:8443"
        line.vpnUsername = username
        line.vpnPassword = password
        return line
    }

    private func profile(_ lines: [Line]) -> Profile {
        var profile = Profile()
        profile.lines = [Line(id: "direct", name: "直连", type: "direct")] + lines
        return profile
    }

    func testBoundAnyConnectWithoutCredentialsNamesMissingFields() {
        let scenario = Scenario(id: "us", name: "美国", bindings: [RuleBinding(ruleSetID: "rule", lineID: "ac")], defaultLineID: "direct")
        let blocker = ConnectionConfigurationBlocker.evaluate(scenario, in: profile([vpn("ac", username: " ", password: "")]))
        XCTAssertEqual(blocker?.reason, .incompleteAnyConnect(lineID: "ac", lineName: "AnyConnect", missing: [.username, .password]))
        XCTAssertEqual(blocker?.lineID, "ac")
        XCTAssertEqual(blocker?.detail { zh, _ in zh }, "AnyConnect 线路“AnyConnect”未填写用户名、密码。")
    }

    func testDefaultAnyConnectWithoutPasswordBlocks() {
        let scenario = Scenario(id: "s", name: "S", defaultLineID: "ac")
        let blocker = ConnectionConfigurationBlocker.evaluate(scenario, in: profile([vpn("ac", password: "")]))
        XCTAssertEqual(blocker?.reason, .incompleteAnyConnect(lineID: "ac", lineName: "AnyConnect", missing: [.password]))
    }

    func testDisabledAnyConnectDoesNotBlockBecauseTheGeneratorFallsBack() {
        let scenario = Scenario(id: "s", name: "S", bindings: [RuleBinding(ruleSetID: "rule", lineID: "ac")], defaultLineID: "direct")
        XCTAssertNil(ConnectionConfigurationBlocker.evaluate(scenario, in: profile([vpn("ac", username: "", password: "", enabled: false)])))
    }

    func testCompleteScenarioIsConnectable() {
        let scenario = Scenario(id: "s", name: "S", bindings: [RuleBinding(ruleSetID: "rule", lineID: "ac")], defaultLineID: "direct")
        XCTAssertNil(ConnectionConfigurationBlocker.evaluate(scenario, in: profile([vpn("ac")])))
    }

    func testScenarioWithoutDefaultRouteBlocks() {
        let scenario = Scenario(id: "s", name: "S")
        let blocker = ConnectionConfigurationBlocker.evaluate(scenario, in: profile([]))
        XCTAssertEqual(blocker?.reason, .noDefaultTarget)
        XCTAssertNil(blocker?.lineID)
    }
}
