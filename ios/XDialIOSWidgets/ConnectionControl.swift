import AppIntents
@preconcurrency import NetworkExtension
import SwiftUI
import WidgetKit

/// 控制中心 / 锁屏 / 操作按钮上的连接开关。
///
/// 本扩展只负责展示：状态读系统 VPN 连接，读不到时退回主 App 发布的快照；
/// 开关动作 SetXDialConnectionIntent 在主 App 进程执行。
struct ConnectionControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(
            kind: XDialWidgetSnapshot.connectionControlKind,
            provider: Provider()
        ) { isOn in
            ControlWidgetToggle(
                "XDial",
                isOn: isOn,
                action: SetXDialConnectionIntent()
            ) { isOn in
                Label(isOn ? "已连接" : "未连接", systemImage: "power")
            }
            .tint(.green)
        }
        .displayName("XDial 连接")
        .description("连接或断开 XDial。")
    }
}

extension ConnectionControl {
    struct Provider: ControlValueProvider {
        var previewValue: Bool { false }

        func currentValue() async throws -> Bool {
            if let systemValue = await Self.systemTunnelIsActive() {
                return systemValue
            }
            return XDialWidgetSnapshot.load()?.isConnectionActive ?? false
        }

        private static func systemTunnelIsActive() async -> Bool? {
            guard let managers = try? await NETunnelProviderManager.loadAllFromPreferences() else {
                return nil
            }
            guard let manager = managers.first(where: {
                ($0.protocolConfiguration as? NETunnelProviderProtocol)?
                    .providerBundleIdentifier == XDialWidgetSnapshot.tunnelBundleIdentifier
            }) else {
                return false
            }
            switch manager.connection.status {
            case .connected, .connecting, .reasserting:
                return true
            default:
                return false
            }
        }
    }
}
