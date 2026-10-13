import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @Binding var selectedTab: MobileTab
    @State private var showingConfigurationIssues = false
    @State private var tailscaleLoginLineID: String?
    @State private var tailscaleLoginError: String?
    @State private var trafficRate = TrafficRate.unavailable

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    statusHero
                    powerButton
                    scenarioList

                    if app.requiresUserAction {
                        tailscaleSignInCard
                    }

                    if app.hasPendingRuntimeChanges {
                        PendingRuntimeChangesBanner()
                    }

                    if !app.isConnectionConfigured && !app.hasActiveTunnel {
                        warningCard(
                            title: app.tr("连接配置尚未完成", "Connection setup is incomplete"),
                            detail: app.activeConfigurationIssues.prefix(3).joined(separator: app.tr("；", "; "))
                        )
                    }

                    activeLinesCard
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("XDial")
        }
    }

    private var statusHero: some View {
        VStack(spacing: 10) {
            Image(systemName: statusIcon)
                .font(.system(size: 66, weight: .medium))
                .foregroundStyle(statusColor)
                .symbolEffect(.pulse, isActive: app.isBusy)
                .accessibilityHidden(true)

            Text(app.statusText)
                .font(.title2.bold())
                .multilineTextAlignment(.center)

            Text(app.activeScenario?.name ?? app.tr("未选择场景", "No scenario selected"))
                .foregroundStyle(.secondary)

            if app.hasFormalTunnel, let connectedAt = app.engine.connectedAt {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(formatDuration(context.date.timeIntervalSince(connectedAt)))
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            if app.isConnected {
                trafficRateCapsule
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
        .task(id: samplesTraffic) {
            await sampleTraffic()
        }
    }

    /// 只在首页可见、App 在前台且已连接时每秒采样；切页、退后台或断开即停。
    private var samplesTraffic: Bool {
        app.isConnected && scenePhase == .active
    }

    private func sampleTraffic() async {
        guard samplesTraffic else {
            trafficRate = .unavailable
            return
        }
        var estimator = TrafficRateEstimator()
        while !Task.isCancelled {
            let totals = await app.trafficTotals()
            guard !Task.isCancelled else { return }
            if let rate = estimator.update(totals, sampledAt: Date()) {
                trafficRate = rate
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private var trafficRateCapsule: some View {
        let download = TrafficRate.format(trafficRate.downloadBytesPerSecond)
        let upload = TrafficRate.format(trafficRate.uploadBytesPerSecond)
        return HStack(spacing: 0) {
            trafficMetric(symbol: "arrow.down", value: download)
            Divider()
                .frame(height: 14)
                .padding(.horizontal, 10)
            trafficMetric(symbol: "arrow.up", value: upload)
        }
        .padding(.horizontal, 14)
        .frame(height: 32)
        .background(Color.primary.opacity(0.04), in: Capsule())
        .overlay {
            Capsule().stroke(Color.primary.opacity(0.07), lineWidth: 0.5)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(app.tr(
            "下载 \(download)，上传 \(upload)",
            "Download \(download), upload \(upload)"
        ))
        .accessibilityIdentifier("traffic-rate")
    }

    private func trafficMetric(symbol: String, value: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.footnote, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 88, alignment: .trailing)
        }
    }

    private var powerButton: some View {
        Button {
            if app.hasFormalTunnel {
                app.disconnect()
            } else if app.tailscaleSetupLineID != nil {
                app.finishTailscaleSetup()
            } else if app.canConnect {
                app.connect()
            } else {
                showingConfigurationIssues = true
            }
        } label: {
            Image(systemName: app.hasActiveTunnel ? "stop.fill" : "power")
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 112, height: 112)
                .background(app.hasActiveTunnel ? Color.red : Color.accentColor)
                .clipShape(Circle())
                .shadow(color: (app.hasActiveTunnel ? Color.red : Color.accentColor).opacity(0.28), radius: 16, y: 8)
        }
        .disabled(app.isBusy)
        .alert(
            app.tr("连接前请先补齐线路", "Complete Line Setup Before Connecting"),
            isPresented: $showingConfigurationIssues
        ) {
            Button(app.tr("前往配置", "Open Configuration")) {
                selectedTab = .configuration
            }
            Button(app.tr("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(app.activeConfigurationIssues.joined(separator: app.tr("；", "; ")))
        }
        .opacity(app.isBusy || (!app.hasActiveTunnel && !app.canConnect) ? 0.45 : 1)
        .accessibilityLabel(
            app.tailscaleSetupLineID != nil
                && !app.hasFormalTunnel
                    ? app.tr("取消 Tailscale 设置", "Cancel Tailscale Setup")
                    : (app.hasFormalTunnel
                        ? app.tr("断开", "Disconnect")
                        : app.tr("连接", "Connect"))
        )
        .accessibilityIdentifier("connection-toggle")
    }

    private var scenarioList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(app.tr("场景", "Scenarios"))
                    .font(.headline)
                Spacer()
                if app.hasActiveTunnel {
                    Text(app.tr("断开后可切换", "Disconnect to switch"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()

            if app.profile.scenarios.isEmpty {
                Divider()
                Text(app.tr("暂无场景，请在「配置 › 场景」中新建。", "No scenarios yet. Create one in Configuration › Scenes."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding()
            }

            ForEach(app.profile.scenarios) { scenario in
                Divider()
                    .padding(.leading)
                scenarioRow(scenario)
            }
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func scenarioRow(_ scenario: Scenario) -> some View {
        let isActive = scenario.id == app.profile.activeScenarioID
        let issueCount = app.configurationIssues(for: scenario).count
        return Button {
            guard app.canMutateConfiguration, !isActive else { return }
            app.profile.activeScenarioID = scenario.id
            app.save()
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(scenario.name)
                        .foregroundStyle(.primary)
                    if issueCount > 0 {
                        Text(app.tr("需补齐 \(issueCount) 项配置", "\(issueCount) setup item(s) required"))
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                Spacer()
                if isActive {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(app.hasActiveTunnel || app.isBusy)
        .opacity((app.hasActiveTunnel || app.isBusy) && !isActive ? 0.45 : 1)
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .accessibilityIdentifier("home-scenario-\(scenario.id)")
    }

    private var tailscaleSignInCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(
                app.tr("需要登录 Tailscale", "Tailscale Sign-in Required"),
                systemImage: "person.crop.circle.badge.exclamationmark"
            )
            .font(.headline)
            .foregroundStyle(.orange)

            Text(app.tr(
                "这是 XDial 内置线路的独立授权，与手机上的 Tailscale App 登录状态不共享。完成一次授权后，XDial 会自动继续连接验收。",
                "This authorizes XDial's built-in route separately from the Tailscale app. After the one-time sign-in, XDial automatically resumes connection checks."
            ))
            .font(.footnote)
            .foregroundStyle(.secondary)

            ForEach(app.tailscaleAuthRequests) { request in
                Button {
                    startTailscaleLogin(request)
                } label: {
                    if tailscaleLoginLineID == request.lineID {
                        HStack {
                            ProgressView()
                            Text(app.tr("正在准备登录…", "Preparing sign-in…"))
                        }
                        .frame(maxWidth: .infinity)
                    } else {
                        Label(
                            app.tailscaleAuthRequests.count == 1
                                ? app.tr("登录 Tailscale", "Sign In to Tailscale")
                                : app.tr("登录 \(request.lineName)", "Sign In to \(request.lineName)"),
                            systemImage: "safari"
                        )
                        .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(tailscaleLoginLineID != nil)
            }

            if let tailscaleLoginError {
                Label(tailscaleLoginError, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.orange.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func startTailscaleLogin(_ request: TailscaleAuthRequest) {
        guard tailscaleLoginLineID == nil else { return }
        tailscaleLoginLineID = request.lineID
        tailscaleLoginError = nil
        app.beginTailscaleLogin(lineID: request.lineID) { result in
            Task { @MainActor in
                tailscaleLoginLineID = nil
                switch result {
                case .success(let status):
                    let backendState = status.backendState.lowercased()
                    guard app.applyTailscaleRuntimeStatus(
                        lineID: request.lineID,
                        status: status
                    ) else {
                        tailscaleLoginError = app.tr(
                            "Tailscale 登录状态无法保存。",
                            "The Tailscale sign-in state could not be saved."
                        )
                        return
                    }
                    if backendState == "running" {
                        return
                    }
                    guard let url = AppState.validTailscaleAuthURL(status.authURL) else {
                        tailscaleLoginError = app.tr(
                            "没有取得有效的登录入口，请重试。",
                            "No valid sign-in link was returned. Please retry."
                        )
                        return
                    }
                    openURL(url)
                case .failure(let error):
                    tailscaleLoginError = userFacingConnectionText(error.localizedDescription)
                }
            }
        }
    }

    private var activeLinesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(
                app.isConnected
                    ? app.tr("本场景活动出口", "Active routes in this scenario")
                    : app.tr("连接后使用的出口", "Routes used after connecting")
            )
                .font(.headline)

            if activeTargets.isEmpty {
                Text(app.tr("没有活动出口", "No active routes"))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(activeTargets) { target in
                    HStack {
                        Image(systemName: target.isSubscription
                              ? "antenna.radiowaves.left.and.right"
                              : lineSymbol(target.type))
                            .foregroundStyle(target.type == "tailscale" ? Color.orange : Color.accentColor)
                            .frame(width: 24)
                        VStack(alignment: .leading) {
                            Text(target.name)
                            Text(target.isSubscription
                                 ? app.tr("订阅", "Subscription")
                                 : mobileLineTypeLabel(target.type))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: app.isConnected ? "checkmark.circle.fill" : "circle.dashed")
                            .foregroundStyle(app.isConnected ? Color.green : Color.secondary)
                    }
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func warningCard(title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.bold())
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
        .background(Color.orange.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var activeTargets: [ActiveRouteTargetSummary] {
        guard let scenario = app.activeScenario else { return [] }
        return app.profile.activeRouteTargetSummaries(for: scenario)
    }

    private var statusIcon: String {
        if app.tailscaleSetupLineID != nil { return "gearshape.2.fill" }
        if app.isConnected { return "checkmark.shield.fill" }
        if app.requiresUserAction { return "person.crop.circle.badge.exclamationmark" }
        if app.isBusy { return "arrow.triangle.2.circlepath" }
        return "shield.slash"
    }

    private var statusColor: Color {
        if app.tailscaleSetupLineID != nil { return .orange }
        if app.isConnected { return .green }
        if app.requiresUserAction { return .orange }
        if app.isBusy { return .orange }
        return .secondary
    }

    private func formatDuration(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}

struct PendingRuntimeChangesBanner: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                app.tr("配置已保存，等待重新连接后应用", "Configuration saved; reconnect to apply"),
                systemImage: "arrow.triangle.2.circlepath"
            )
            .font(.subheadline.bold())

            Text(app.tr(
                "当前连接继续使用启动时的配置，不会在后台静默切换线路。",
                "The current connection keeps its startup configuration and will not switch routes silently."
            ))
            .font(.footnote)
            .foregroundStyle(.secondary)

            Button {
                app.reconnectToApplyChanges()
            } label: {
                Label(app.tr("重新连接并应用", "Reconnect and Apply"), systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!app.isConnected || app.isBusy)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.orange.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

func lineSymbol(_ type: String) -> String {
    switch type {
    case "direct": return "arrow.right"
    case "vpn": return "building.2"
    case "tailscale": return "point.3.connected.trianglepath.dotted"
    default: return "network"
    }
}
