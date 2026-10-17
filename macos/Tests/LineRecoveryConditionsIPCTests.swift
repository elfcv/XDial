import XCTest

final class LineRecoveryConditionsIPCTests: XCTestCase {
    private func encoded(_ conditions: ProviderLineRecoveryConditions) throws -> Data {
        try JSONEncoder().encode(conditions)
    }

    private func object(_ json: String) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
    }

    func testEncodingUsesLibboxContractAndLeasePerCondition() throws {
        let asleep = ProviderLineRecoveryConditions(
            source: "host", sequence: 3, systemAsleep: true, underlayUsable: true
        )
        let fields = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded(asleep)) as? [String: Any]
        )
        XCTAssertEqual(fields["kind"] as? String, "line-recovery-conditions")
        XCTAssertEqual(fields["version"] as? Int, 1)
        XCTAssertEqual(fields["source"] as? String, "host")
        XCTAssertEqual(fields["sequence"] as? Int, 3)
        XCTAssertEqual(fields["system_asleep"] as? Bool, true)
        XCTAssertEqual(fields["underlay_usable"] as? Bool, true)
        XCTAssertEqual(fields["lease_ms"] as? Int, 15 * 60 * 1000)
        XCTAssertNil(fields["transaction_id"], "power facts are not transaction content")

        let offline = ProviderLineRecoveryConditions(
            source: "host", sequence: 4, systemAsleep: false, underlayUsable: false
        )
        XCTAssertTrue(offline.gated)
        XCTAssertEqual(offline.leaseMS, 5 * 60 * 1000)

        let open = ProviderLineRecoveryConditions(
            source: "host", sequence: 5, systemAsleep: false, underlayUsable: true
        )
        XCTAssertFalse(open.gated)
        XCTAssertEqual(open.leaseMS, 0)
        XCTAssertTrue(asleep.isValid && offline.isValid && open.isValid)

        let decoded = try JSONDecoder().decode(
            ProviderLineRecoveryConditions.self, from: encoded(offline)
        )
        XCTAssertEqual(decoded, offline)
    }

    func testValidationRejectsMalformedReports() throws {
        func decode(_ json: String) throws -> ProviderLineRecoveryConditions {
            try JSONDecoder().decode(
                ProviderLineRecoveryConditions.self, from: Data(json.utf8)
            )
        }
        let base = #""kind":"line-recovery-conditions","version":1"#
        XCTAssertFalse(try decode(
            "{\(base),\"source\":\"\",\"sequence\":1,\"system_asleep\":false,\"underlay_usable\":true,\"lease_ms\":0}"
        ).isValid)
        XCTAssertFalse(try decode(
            "{\(base),\"source\":\"h\",\"sequence\":0,\"system_asleep\":false,\"underlay_usable\":true,\"lease_ms\":0}"
        ).isValid)
        XCTAssertFalse(try decode(
            "{\(base),\"source\":\"h\",\"sequence\":1,\"system_asleep\":true,\"underlay_usable\":true,\"lease_ms\":0}"
        ).isValid, "a closed gate without a lease could wait forever")
        XCTAssertFalse(try decode(
            "{\(base),\"source\":\"h\",\"sequence\":1,\"system_asleep\":true,\"underlay_usable\":true,\"lease_ms\":900001}"
        ).isValid)
        XCTAssertFalse(try decode(
            "{\(base),\"source\":\"h\",\"sequence\":1,\"system_asleep\":false,\"underlay_usable\":true,\"lease_ms\":10}"
        ).isValid)
        XCTAssertFalse(try decode(
            "{\"kind\":\"local-socks-share\",\"version\":1,\"source\":\"h\",\"sequence\":1,\"system_asleep\":false,\"underlay_usable\":true,\"lease_ms\":0}"
        ).isValid)
        XCTAssertFalse(try decode(
            "{\(base),\"source\":\"\(String(repeating: "x", count: 65))\",\"sequence\":1,\"system_asleep\":false,\"underlay_usable\":true,\"lease_ms\":0}"
        ).isValid)
    }

    func testRemainingLeaseExpiresOnlyClosedReports() {
        let asleep = ProviderLineRecoveryConditions(
            source: "h", sequence: 1, systemAsleep: true, underlayUsable: true
        )
        XCTAssertEqual(asleep.remaining(after: 60)?.leaseMS, 14 * 60 * 1000)
        XCTAssertNil(asleep.remaining(after: 15 * 60))
        let open = ProviderLineRecoveryConditions(
            source: "h", sequence: 2, systemAsleep: false, underlayUsable: true
        )
        XCTAssertEqual(open.remaining(after: 3600), open)
    }

    func testRelayOrdersReportsAndAppliesThemToTheAttachedEngine() throws {
        var now: TimeInterval = 100
        let relay = LineRecoveryConditionsRelay(uptime: { now })
        var applied: [String] = []
        relay.attach { applied.append($0) }

        let sleep = ProviderLineRecoveryConditions(
            source: "host-a", sequence: 2, systemAsleep: true, underlayUsable: true
        )
        let first = try XCTUnwrap(relay.receive(encoded(sleep)))
        XCTAssertEqual(first.response.code, "ok")
        XCTAssertTrue(first.response.delivered)
        XCTAssertEqual(first.conditions, sleep)
        XCTAssertEqual(applied.count, 1)
        let sent = try object(applied[0])
        XCTAssertEqual(sent["system_asleep"] as? Bool, true)
        XCTAssertEqual(sent["sequence"] as? Int, 2)

        let older = ProviderLineRecoveryConditions(
            source: "host-a", sequence: 1, systemAsleep: false, underlayUsable: true
        )
        let stale = try XCTUnwrap(relay.receive(encoded(older)))
        XCTAssertEqual(stale.response.code, "stale")
        XCTAssertTrue(stale.response.delivered)
        XCTAssertEqual(applied.count, 1, "an older report must not reopen the gate")

        // A relaunched host starts a new sequence under a new source.
        now += 1
        let relaunched = ProviderLineRecoveryConditions(
            source: "host-b", sequence: 1, systemAsleep: false, underlayUsable: true
        )
        XCTAssertEqual(try relay.receive(encoded(relaunched))?.response.code, "ok")
        XCTAssertEqual(applied.count, 2)

        relay.detach()
        let afterDetach = ProviderLineRecoveryConditions(
            source: "host-b", sequence: 2, systemAsleep: true, underlayUsable: true
        )
        XCTAssertEqual(try relay.receive(encoded(afterDetach))?.response.code, "ok")
        XCTAssertEqual(applied.count, 2)
    }

    func testRelayReplaysRemainingLeaseToANewEngine() throws {
        var now: TimeInterval = 10
        let relay = LineRecoveryConditionsRelay(uptime: { now })
        let offline = ProviderLineRecoveryConditions(
            source: "h", sequence: 1, systemAsleep: false, underlayUsable: false
        )
        XCTAssertEqual(try relay.receive(encoded(offline))?.response.code, "ok")

        now += 60
        var applied: [String] = []
        relay.attach { applied.append($0) }
        XCTAssertEqual(applied.count, 1)
        let replayed = try object(applied[0])
        XCTAssertEqual(replayed["underlay_usable"] as? Bool, false)
        XCTAssertEqual(replayed["lease_ms"] as? Int, 4 * 60 * 1000)

        // An expired closed report is not replayed: a vanished host must not
        // keep a later engine waiting.
        relay.detach()
        now += 5 * 60
        var late: [String] = []
        relay.attach { late.append($0) }
        XCTAssertTrue(late.isEmpty)
    }

    func testRelayRejectsInvalidReportsWithoutApplyingThem() throws {
        let relay = LineRecoveryConditionsRelay(uptime: { 0 })
        var applied = 0
        relay.attach { _ in applied += 1 }
        XCTAssertNil(relay.receive(Data("not json".utf8)))
        XCTAssertNil(relay.receive(Data(repeating: 0x20, count: 5000)))
        let invalid = #"{"kind":"line-recovery-conditions","version":1,"source":"h","sequence":1,"system_asleep":true,"underlay_usable":true,"lease_ms":0}"#
        let receipt = try XCTUnwrap(relay.receive(Data(invalid.utf8)))
        XCTAssertEqual(receipt.response.code, "invalid-request")
        XCTAssertFalse(receipt.response.delivered)
        XCTAssertEqual(applied, 0)
    }

    func testPublisherStateReportsOnlyProviderVisibleChanges() {
        var state = LineRecoveryConditionsPublisherState(source: "host")
        // The first observation always reports, clearing a gate a previous
        // host instance may have left closed.
        XCTAssertTrue(state.observeUnderlay(usable: true))
        XCTAssertFalse(state.observeUnderlay(usable: true))
        var message = state.makeMessage()
        XCTAssertEqual(message.sequence, 1)
        XCTAssertFalse(message.gated)

        XCTAssertTrue(state.noteSystemWillSleep())
        XCTAssertFalse(state.noteSystemWillSleep())
        message = state.makeMessage()
        XCTAssertTrue(message.systemAsleep)
        XCTAssertEqual(message.sequence, 2)

        // Path changes during sleep (including Dark Wake) do not reopen the gate.
        XCTAssertFalse(state.observeUnderlay(usable: false))
        XCTAssertFalse(state.observeUnderlay(usable: true))
        XCTAssertTrue(state.gated)

        // Only the full wake reopens it, with the freshly sampled path.
        XCTAssertTrue(state.noteSystemDidWake(underlayUsable: false))
        message = state.makeMessage()
        XCTAssertFalse(message.systemAsleep)
        XCTAssertFalse(message.underlayUsable)
        XCTAssertTrue(message.gated)

        XCTAssertTrue(state.observeUnderlay(usable: true))
        message = state.makeMessage()
        XCTAssertFalse(message.gated)
        XCTAssertEqual(message.sequence, 4)
        XCTAssertTrue(message.isValid)
    }

    func testDecodesAnyConnectLineWaitingStatus() throws {
        let raw = """
        {
          "status": "line_waiting",
          "line_type": "vpn",
          "attempt": 1,
          "max_attempts": 3,
          "reason": "system-asleep"
        }
        """
        let status = try JSONDecoder().decode(
            AnyConnectLineRuntimeStatus.self,
            from: Data(raw.utf8)
        )
        XCTAssertEqual(status.state, .waiting)
        XCTAssertEqual(status.reason, "system-asleep")
        XCTAssertEqual(status.attempt, 1)
        XCTAssertTrue(status.isAnyConnect)

        var gate = EngineCallbackRuntimeGate()
        gate.consumeStatus(#"{"status":"connected"}"#)
        gate.consumeStatus(raw)
        XCTAssertEqual(gate.phase, .running, "waiting must not look like a stopped data plane")
    }
}
