import Network
import XCTest

final class LocalSOCKSShareTests: XCTestCase {
    private func reader(_ bytes: [UInt8]) -> LocalSOCKSHandshake.Read {
        var remaining = Data(bytes)
        return { count in
            guard remaining.count >= count else { throw CocoaError(.fileReadCorruptFile) }
            let chunk = remaining.prefix(count)
            remaining.removeFirst(count)
            return Data(chunk)
        }
    }

    func testGreetingRequiresNoAuthenticationMethod() async throws {
        try await LocalSOCKSHandshake.readGreeting(reader([0x05, 0x02, 0x02, 0x00]))
        do {
            try await LocalSOCKSHandshake.readGreeting(reader([0x05, 0x01, 0x02]))
            XCTFail("username/password only must be refused")
        } catch let failure as LocalSOCKSHandshake.Failure {
            XCTAssertEqual(failure, .noAcceptableMethod)
            XCTAssertNil(failure.replyCode)
        }
        do {
            try await LocalSOCKSHandshake.readGreeting(reader([0x04, 0x01, 0x00]))
            XCTFail("SOCKS4 must be refused")
        } catch let failure as LocalSOCKSHandshake.Failure {
            XCTAssertEqual(failure, .invalidVersion)
        }
    }

    func testConnectRequestAddressForms() async throws {
        let ipv4 = try await LocalSOCKSHandshake.readRequest(
            reader([0x05, 0x01, 0x00, 0x01, 1, 2, 3, 4, 0x01, 0xBB])
        )
        XCTAssertEqual(ipv4, .init(host: "1.2.3.4", port: 443))

        var ipv6Bytes: [UInt8] = [0x05, 0x01, 0x00, 0x04]
        ipv6Bytes += [0x20, 0x01, 0x0d, 0xb8] + Array(repeating: 0, count: 11) + [1]
        ipv6Bytes += [0x00, 0x50]
        let ipv6 = try await LocalSOCKSHandshake.readRequest(reader(ipv6Bytes))
        XCTAssertEqual(ipv6.port, 80)
        // The upstream negotiation re-encodes literal hosts as IPv6.
        XCTAssertEqual(IPv6Address(ipv6.host), IPv6Address("2001:db8::1"))

        let name = Array("example.com".utf8)
        let domain = try await LocalSOCKSHandshake.readRequest(
            reader([0x05, 0x01, 0x00, 0x03, UInt8(name.count)] + name + [0x1F, 0x90])
        )
        XCTAssertEqual(domain, .init(host: "example.com", port: 8080))
    }

    func testClientCannotForgeProviderFlowMetadata() async {
        // Provider metadata envelopes start with NUL; only the Provider may send them.
        let envelope: [UInt8] = [0x00, 0x58, 0x44, 0x02, 0x04, 0x65, 0x6E, 0x30]
        await assertRequest(
            [0x05, 0x01, 0x00, 0x03, UInt8(envelope.count)] + envelope + [0x00, 0x50],
            fails: .invalidDestination
        )
        let spaced = Array("a b".utf8)
        await assertRequest(
            [0x05, 0x01, 0x00, 0x03, UInt8(spaced.count)] + spaced + [0x00, 0x50],
            fails: .invalidDestination
        )
    }

    func testOnlyTCPConnectIsSupported() async {
        await assertRequest([0x05, 0x03, 0x00, 0x01, 0, 0, 0, 0, 0, 0], fails: .commandNotSupported)
        await assertRequest([0x05, 0x02, 0x00, 0x01, 1, 2, 3, 4, 0, 80], fails: .commandNotSupported)
        await assertRequest([0x05, 0x01, 0x00, 0x05, 0, 80], fails: .addressTypeNotSupported)
        await assertRequest([0x05, 0x01, 0x00, 0x01, 1, 2, 3, 4, 0, 0], fails: .invalidDestination)
        XCTAssertEqual(LocalSOCKSHandshake.Failure.commandNotSupported.replyCode, 0x07)
        XCTAssertEqual(LocalSOCKSHandshake.Failure.addressTypeNotSupported.replyCode, 0x08)
    }

    func testRequestAndPolicyValidation() {
        XCTAssertTrue(LocalSOCKSShareRequest(transactionID: "tx", port: 5181).isValid)
        XCTAssertTrue(LocalSOCKSShareRequest(transactionID: "tx", port: nil).isValid)
        XCTAssertFalse(LocalSOCKSShareRequest(transactionID: "tx", port: 80).isValid)
        XCTAssertFalse(LocalSOCKSShareRequest(transactionID: "", port: 5181).isValid)

        let request = LocalSOCKSShareRequest(transactionID: "tx", port: 5181)
        XCTAssertNil(LocalSOCKSSharePolicy.rejection(request: request, transactionID: "tx", committed: true))
        XCTAssertEqual(LocalSOCKSSharePolicy.rejection(request: request, transactionID: "other", committed: true),
                       "transaction-mismatch")
        XCTAssertEqual(LocalSOCKSSharePolicy.rejection(request: request, transactionID: "tx", committed: false),
                       "session-not-committed")
        XCTAssertEqual(LocalSOCKSShareStatus.failureCode(for: .posix(.EADDRINUSE)), "address-in-use")
    }

    private func assertRequest(
        _ bytes: [UInt8],
        fails expected: LocalSOCKSHandshake.Failure,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await LocalSOCKSHandshake.readRequest(reader(bytes))
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? LocalSOCKSHandshake.Failure, expected, file: file, line: line)
        }
    }
}

@MainActor
final class LocalSOCKSShareControllerTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName = ""
    private var sent: [(LocalSOCKSShareRequest, (Result<LocalSOCKSShareResponse, Error>) -> Void)] = []

    override func setUp() async throws {
        suiteName = "LocalSOCKSShareControllerTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        sent = []
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeController() -> LocalSOCKSShareController {
        LocalSOCKSShareController(defaults: defaults) { [unowned self] request, completion in
            self.sent.append((request, completion))
        }
    }

    private func respond(_ index: Int, _ status: LocalSOCKSShareStatus) async {
        let request = sent[index].0
        sent[index].1(.success(LocalSOCKSShareResponse(
            requestID: request.requestID, transactionID: request.transactionID,
            code: "ok", status: status)))
        for _ in 0..<5 { await Task.yield() }
    }

    func testDefaultsToOffAndNeverContactsProvider() {
        let controller = makeController()
        XCTAssertFalse(controller.isEnabled)
        XCTAssertEqual(controller.port, LocalSOCKSSharePort.defaultValue)
        controller.connectionChanged(transactionID: "tx", ingress: .system)
        XCTAssertEqual(controller.phase, .off)
        XCTAssertTrue(sent.isEmpty)
    }

    func testEnabledPreferenceWaitsForCommittedConnection() async {
        let controller = makeController()
        controller.isEnabled = true
        XCTAssertEqual(controller.phase, .waitingForConnection)
        XCTAssertTrue(sent.isEmpty)

        controller.connectionChanged(transactionID: "tx", ingress: .system)
        XCTAssertEqual(sent.map(\.0.port), [UInt16(LocalSOCKSSharePort.defaultValue)])
        XCTAssertEqual(controller.phase, .applying)
        await respond(0, .listening(UInt16(LocalSOCKSSharePort.defaultValue)))
        XCTAssertEqual(controller.phase, .listening)

        // A Switch commits a new transaction; the Provider keeps the listener.
        controller.connectionChanged(transactionID: "tx-2", ingress: .system)
        XCTAssertEqual(sent.last?.0.transactionID, "tx-2")

        XCTAssertTrue(makeController().isEnabled, "preference persists")
    }

    func testDisablingWhileConnectedClosesListener() async {
        let controller = makeController()
        controller.isEnabled = true
        controller.connectionChanged(transactionID: "tx", ingress: .system)
        await respond(0, .listening(UInt16(LocalSOCKSSharePort.defaultValue)))

        controller.isEnabled = false
        XCTAssertEqual(sent.count, 2)
        XCTAssertNil(sent[1].0.port)
        await respond(1, .off)
        XCTAssertEqual(controller.phase, .off)

        controller.connectionChanged(transactionID: nil, ingress: nil)
        controller.connectionChanged(transactionID: "tx-2", ingress: .system)
        XCTAssertEqual(sent.count, 2, "a confirmed-off Provider needs no further message")
    }

    func testPortConflictIsReportedAndStaleResultsIgnored() async {
        let controller = makeController()
        controller.isEnabled = true
        controller.connectionChanged(transactionID: "tx", ingress: .system)
        XCTAssertFalse(controller.setPort(80))
        XCTAssertTrue(controller.setPort(6000))
        XCTAssertEqual(sent.map(\.0.port), [UInt16(LocalSOCKSSharePort.defaultValue), 6000])

        await respond(0, .listening(UInt16(LocalSOCKSSharePort.defaultValue)))
        XCTAssertEqual(controller.phase, .applying, "superseded response must not win")
        await respond(1, .failed(6000, code: "address-in-use"))
        XCTAssertEqual(controller.phase, .failed(code: "address-in-use"))

        controller.retry()
        XCTAssertEqual(sent.count, 3)
        sent[2].1(.failure(CocoaError(.userCancelled)))
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(controller.phase, .unavailable)
    }

    func testProxyOnlyIngressIsTheTransactionsOwnListener() {
        let controller = makeController()
        controller.ingressMode = .localSOCKS
        XCTAssertEqual(
            LocalSOCKSShareController.preferredIngress(defaults: defaults),
            .localSOCKS(port: UInt16(LocalSOCKSSharePort.defaultValue))
        )
        XCTAssertEqual(controller.phase, .waitingForConnection)

        controller.connectionChanged(
            transactionID: "tx",
            ingress: .localSOCKS(port: UInt16(LocalSOCKSSharePort.defaultValue))
        )
        XCTAssertEqual(controller.phase, .listening)
        XCTAssertTrue(sent.isEmpty, "the committed transaction owns the port")
        XCTAssertFalse(controller.ingressRequiresReconnect)

        // Changing the port of a proxy-only connection waits for reconnect.
        XCTAssertTrue(controller.setPort(6000))
        XCTAssertTrue(sent.isEmpty)
        XCTAssertTrue(controller.ingressRequiresReconnect)
    }

    func testChangingModeWhileConnectedRequiresReconnect() async {
        let controller = makeController()
        controller.connectionChanged(transactionID: "tx", ingress: .system)
        XCTAssertFalse(controller.ingressRequiresReconnect)

        controller.ingressMode = .localSOCKS
        XCTAssertTrue(controller.ingressRequiresReconnect)
        // The existing system-wide session opens the port right away.
        XCTAssertEqual(sent.map(\.0.port), [UInt16(LocalSOCKSSharePort.defaultValue)])

        controller.ingressMode = .system
        XCTAssertFalse(controller.ingressRequiresReconnect)
        controller.connectionChanged(transactionID: nil, ingress: nil)
        XCTAssertFalse(controller.ingressRequiresReconnect, "nothing to reconnect while disconnected")
        XCTAssertEqual(
            LocalSOCKSShareController.preferredIngress(defaults: defaults),
            .system
        )
    }
}

final class ConnectionIngressTests: XCTestCase {
    func testValidity() {
        XCTAssertTrue(ConnectionIngress.system.isValid)
        XCTAssertTrue(ConnectionIngress.localSOCKS(port: 5181).isValid)
        XCTAssertFalse(ConnectionIngress(mode: .localSOCKS, localSOCKSPort: nil).isValid)
        XCTAssertFalse(ConnectionIngress(mode: .localSOCKS, localSOCKSPort: 80).isValid)
        XCTAssertFalse(ConnectionIngress(mode: .system, localSOCKSPort: 5181).isValid)
    }

    func testReportCarriesIngressAndOldReportsMeanSystemWide() throws {
        let plan = ConnectionPlan(
            schemaVersion: 3,
            scenario: ConnectionPlanScenario(id: "s", name: "S"),
            configurationFingerprint: "f",
            tasks: []
        )
        let report = ConnectionReport(
            transactionID: "tx", plan: plan, ingress: .localSOCKS(port: 5181))
        let encoded = try ConnectionReportCodec.encode(report)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let ingress = try XCTUnwrap(object["ingress"] as? [String: Any])
        XCTAssertEqual(ingress["mode"] as? String, "local-socks")
        XCTAssertEqual(ingress["local_socks_port"] as? Int, 5181)
        XCTAssertEqual(try ConnectionReportCodec.decode(encoded).ingress, .localSOCKS(port: 5181))

        var legacy = object
        legacy.removeValue(forKey: "ingress")
        let legacyData = try JSONSerialization.data(withJSONObject: legacy)
        XCTAssertEqual(try ConnectionReportCodec.decode(legacyData).ingress, .system)

        var invalid = object
        invalid["ingress"] = ["mode": "local-socks"]
        XCTAssertThrowsError(try ConnectionReportCodec.decode(
            JSONSerialization.data(withJSONObject: invalid)))
    }
}
