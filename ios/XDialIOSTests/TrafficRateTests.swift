import XCTest
@testable import XDial

final class TrafficRateTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)

    func testFirstSampleShowsZeroThenDifferencesTotals() {
        var estimator = TrafficRateEstimator()
        XCTAssertEqual(
            estimator.update(TrafficTotals(uploadBytes: 100, downloadBytes: 1_000), sampledAt: start),
            TrafficRate(downloadBytesPerSecond: 0, uploadBytesPerSecond: 0)
        )
        XCTAssertEqual(
            estimator.update(
                TrafficTotals(uploadBytes: 300, downloadBytes: 5_000),
                sampledAt: start.addingTimeInterval(2)
            ),
            TrafficRate(downloadBytesPerSecond: 2_000, uploadBytesPerSecond: 100)
        )
    }

    func testCounterResetAfterTunnelRestartShowsZero() {
        var estimator = TrafficRateEstimator()
        _ = estimator.update(TrafficTotals(uploadBytes: 9_000, downloadBytes: 9_000), sampledAt: start)
        XCTAssertEqual(
            estimator.update(
                TrafficTotals(uploadBytes: 10, downloadBytes: 10),
                sampledAt: start.addingTimeInterval(1)
            ),
            TrafficRate(downloadBytesPerSecond: 0, uploadBytesPerSecond: 0)
        )
    }

    func testMissingSampleClearsRateAndHistory() {
        var estimator = TrafficRateEstimator()
        _ = estimator.update(TrafficTotals(uploadBytes: 1, downloadBytes: 1), sampledAt: start)
        XCTAssertEqual(estimator.update(nil, sampledAt: start.addingTimeInterval(1)), .unavailable)
        XCTAssertEqual(
            estimator.update(
                TrafficTotals(uploadBytes: 500, downloadBytes: 500),
                sampledAt: start.addingTimeInterval(2)
            ),
            TrafficRate(downloadBytesPerSecond: 0, uploadBytesPerSecond: 0)
        )
    }

    func testFormatMatchesMenuBarUnits() {
        XCTAssertEqual(TrafficRate.format(nil), "—")
        XCTAssertEqual(TrafficRate.format(0), "0.0 B/s")
        XCTAssertEqual(TrafficRate.format(1_350_000), "1.4 MB/s")
    }
}
