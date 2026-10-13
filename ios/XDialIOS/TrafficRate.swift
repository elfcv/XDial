import Foundation

/// 首页实时速率。nil 表示当前没有可用采样（未连接、扩展未应答）。
struct TrafficRate: Equatable {
    var downloadBytesPerSecond: Double?
    var uploadBytesPerSecond: Double?

    static let unavailable = TrafficRate()

    /// 与 macOS 菜单栏一致：十进制单位，保留一位小数。
    static func format(_ bytesPerSecond: Double?) -> String {
        guard let bytesPerSecond, bytesPerSecond >= 0 else {
            return "—"
        }
        let units = ["B/s", "KB/s", "MB/s", "GB/s", "TB/s"]
        var value = bytesPerSecond
        var unitIndex = 0
        while value >= 1_000 && unitIndex < units.count - 1 {
            value /= 1_000
            unitIndex += 1
        }
        return String(format: "%.1f %@", value, units[unitIndex])
    }
}

/// 把扩展返回的累计字节数差分成速率。语义对齐 macOS `TrafficInfo.apply`：
/// 读不到就清空；首个样本或计数回退（隧道重启后从 0 计）显示 0。
struct TrafficRateEstimator {
    private var previous: (totals: TrafficTotals, sampledAt: Date)?

    mutating func update(_ totals: TrafficTotals?, sampledAt: Date) -> TrafficRate? {
        guard let totals else {
            previous = nil
            return .unavailable
        }
        defer { previous = (totals, sampledAt) }
        guard
            let previous,
            totals.downloadBytes >= previous.totals.downloadBytes,
            totals.uploadBytes >= previous.totals.uploadBytes
        else {
            return TrafficRate(downloadBytesPerSecond: 0, uploadBytesPerSecond: 0)
        }
        let elapsed = sampledAt.timeIntervalSince(previous.sampledAt)
        // 间隔非正时保留上一次显示，由调用方忽略 nil。
        guard elapsed > 0 else { return nil }
        return TrafficRate(
            downloadBytesPerSecond: Double(totals.downloadBytes - previous.totals.downloadBytes) / elapsed,
            uploadBytesPerSecond: Double(totals.uploadBytes - previous.totals.uploadBytes) / elapsed
        )
    }
}
