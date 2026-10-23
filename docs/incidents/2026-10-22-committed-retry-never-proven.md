# 自动重连已提交仍永久显示“正在重连”

## 现场与边界

时间为本机 PDT，取自系统统一日志；App 日志与事故记录用 UTC，对应 2026-10-23 02:04–02:05Z。

Debug（PID 6848）唤醒后自动连接 7EC85CFF 失败，随后第 2 次尝试 D9E2074D 也失败，
code 都是 `line-readiness-transient`。第 3 次尝试是 684A0DF0（日志记为 attempt 2、3）。

看到的：
- 19:05:15.128：事故记录写入 684A0DF0 的 `retry-started`，这条记录紧接在 `startConnection` 之前。
- App 主线程大约每 0.2 s 做一串 App Group 容器查找，19:05:15.642 多出一串。
- 19:05:17.643：nesessionmanager 记录收到 XDial 的 start 命令，状态变为 connecting；
  17.646 App 主线程出现下一串查找。
- 19:05:24.624：Provider `started generation=684A0DF0`；19:05:24.626 NE 会话变为 connected。
- 之后 App 一直是 `reconnecting`，事故 3ECAEFED 没有 `recovered`。UI 显示 7/7 就绪、
  “系统网络接管 已提交”，流量由 XDial 承载。
- 用 Swift 反射读取运行中 Host 的 `TransparentProxyManager`：`currentTransactionID` 和
  `automaticReconnectTransactionID` 都是 684A0DF0，`networkExtensionSessionTransactionID`
  为 nil，`startAttemptID` 为 nil。

推的：
- 每 0.2 s 一串的查找是报告轮询读日志；17.646 那串是 App 在处理 connecting 状态变化。
- Host 约在 15.13 调用了 `startVPNTunnel`。依据是 `retry-started` 之后的代码是同步执行的。
- 15.642 那串查找是启动监视器 0.5 s 的首检：它读到 `disconnected`，并走了 inactive 分支。
  依据是时间正好在调用后 0.5 s，而 nesessionmanager 到 17.643 才开始处理 start。
- start 晚到 2.5 s 的原因未证实。15–18 s 之间 App 主线程最大间隔 0.2 s，状态变化约 3 ms
  后 App 就在处理。如果原因在 Host 侧，应在 NE 框架发出请求的路径上。

同样的症状还出现在 10-08、10-12、10-19：重试已 `transaction-committed`，却没有恢复，
直到用户断开时记下 `stop() called, status=reconnecting`。从发起到提交，这三次分别用了
9 s、136 s、109 s，10-22 是 9 s。10-12 和 10-19 里，`fetchLastDisconnectError` 的回调
（`system-disconnect-reason`）分别晚到约 202 s、106 s。那几天没有亚秒级证据，机制相同
是推断。

## 确定的缺口

恢复期间，连接证明除了事务本身，还要求 Host 记下“交给 NE 会话的事务”与重试事务一致。
这个标记在 `startConnection` 写入，却会被任何一次 inactive 读数无条件清掉。

系统会话状态不带事务。`startVPNTunnel` 返回后，它可能过数秒才变化，这段时间读到的
`disconnected` 是启动之前的会话，不是这次尝试的结果。恢复进行中时，这次读数静默返回，
监视器也随之停止。此后没有任何路径能恢复标记，提交后的 connected 永远证明不了；
Underlay 监控和稳定重置也一起停摆。

同一类判断还有几处：
- 普通连接里，同样的早期读数会把上一会话的 `lastDisconnectError` 当成本次失败，
  把一次健康的启动报成失败。
- 恢复中，Provider 接手事务后若没写落定报告就结束，或者以回滚未完成的失败报告结束，
  结果门都会一直等待，同样停在 reconnecting。
- Host 代为落定的事务，会被 Provider 日志里同一事务的非终态副本覆盖回去。
- 断开或改连时，系统尚未处理的 start 没有撤回，可能稍后才拉起会话。

## 修复

- **证明**：只认本次尝试自己的事务。条件是尝试事务等于当前事务、该事务 committed、
  系统会话 connected。尝试事务为这次尝试新生成，只经它的 start 选项送进 Provider，不再
  另存会话标记。开启恢复的失败事务不再写入尝试事务；尝试结果一被裁决，它就失去证明资格。
- **inactive 读数归属**：由 `NetworkExtensionStartAttempt` 按 Host 实际看到的事实判定。
  Provider 校验完启动选项后，在 engineQueue 上把 Host 的种子写进自己的 root 日志，
  Host 经 daemon 读取这份副本。
  - Host 读到副本之后的 inactive，算本事务的会话结束。事务若仍未落定，按
    `provider-session-lost` 收尾。
  - Host 见过系统会话进入活动态，且 Provider 日志有应答但不含该事务，按启动被拒落定。
  - 其余情况下读到的 inactive（包括日志探测没有应答时），不判定任何东西。
- **有界**：尝试被证明或落定前，监视器按电平反复重新评估，每次检查至少间隔 0.5 s。
  - 至少 45 s 后会话仍活动，就停掉它，由它的 inactive 按事实落定；再过至少 10 s 仍未
    停下，按超时失败。
  - 一直 inactive，以超时失败落定，并发 stop 撤回 start。
  - Host 为预算停掉的事务，结果文案显示为启动超时；重试与事故分类仍按报告里的 code。
  - 会话结束后的收尾先重读 Provider 报告；断开错误只用于措辞，最多等 3 s（10-12、10-19
    里它的回调晚到过几分钟）。
- **恢复的收尾**：恢复尝试只经正在等它的结果门收尾；结果门已消费过的事务不再二次落定；
  恢复已在别处结束（如停泊被结束）的尝试按普通启动收尾。会话已 inactive 时，回滚无法再由
  Host 确认的失败报告也作为这一步的结果。
- **其他**：
  - 会话 inactive 时，Host 落定的终态不被同一事务的非终态 Provider 副本覆盖。
  - 断开、改连、超时和 Host 侧失败都会撤回可能尚未被处理的 start；尝试打开期间，一次
    偏好读取失败不判定会话。
  - 尝试期间固定使用启动它的 manager 实例。
  - 场景切换只从已证明的会话开始。

## 剩余边界

- 系统一直没处理 start 的尝试，至少 45 s 后以 `startTimedOut`（`host-start-failed`，
  终止码）报出，恢复随之结束。10-12、10-19 从发起到提交用了 109–136 s，同样的情况现在
  会报超时，而不是永久停在“正在重连”，也不会在约两分钟后连上。撤回用的 stop 假定排在
  那条 start 之后处理，未证实。
- 会话活动但至少 45 s 仍未证明的尝试会被停掉，这与旧的 connecting 超时一样。超过 45 s
  的准备（AnyConnect 恢复等待最长 60 s）以前会被切断，现在也会。
- Provider 写入副本之前就结束（选项校验失败、日志写入失败、扩展未能启动或崩溃）时，若 Host
  没读到活动态，或 Provider 日志探测一直没有应答（包括首次安装还没有日志），要到预算用完
  才以 `startTimedOut` 报出。旧代码在第一次 inactive 读数时就报出，前提是系统已经处理了
  这条 start。
- 同期 App 进程泄漏了约 5070 个 `NETunnelProviderSession`（`heap` 计数，同时只有 2 个
  `NETransparentProxyManager`）。诊断 IPC 每次都重新 `loadAllFromPreferences`。断开错误
  每变化一次，主线程就要为每个泄漏会话各记一行，持续约 7 s（统一日志 19:04:35.5–42.9、
  19:05:24.6–31.4）。它是 start 晚到的首要嫌疑，另开 PR 修复后再对比启动延迟。
