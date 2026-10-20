# XDial 精简重构盘点

> 历史记录：2026-10-15 的盘点快照。其中旧数据面与 Next 身份等结论已由 #34–#43 部分落实，以当前代码为准。

2026-10-15，基于 main 的 774829f（v0.9.6）。只读分析，没有改代码。

做法：9 个审计员按子系统只读盘点，共报出 268 项功能和 164 条问题。8 个核实员随后对其中 75 条关键结论做对抗复核：36 条成立，39 条方向对但事实、范围或行数有修正，没有一条被推翻。最后由 1 个审查员检查遗漏。附录 B 中未经复核的 89 条标为「未复核」。行数都按保守口径估算。凡是由代码推出、没有实际运行验证的结论，正文里都注明了「推断」。

## 结论

不算 third_party，Go 和 Swift 合计约 14.3 万行，其中测试约 5 万行。核心功能是：配置编译、盒内数据面、macOS Transparent Proxy 接入、连接与 Switch 事务、安装和更新。这些功能本身是必要的，主干复杂度与 ARCHITECTURE 基本对应。屎山主要不是「多余功能」，而是下面四类。

1. **死掉没删的旧路径**。包括旧原生 TUN 数据面、macOS 上的嵌套订阅、v0.8.0 之后弃用的 gomobile 导出面，以及 Next 配置库切换后留下的旧存储和迁移代码。仓库里没有明确的退役机制：没有声明最低升级起点，补丁栈只增不改，Makefile 里有 42 条 grep 门禁，都是历次事故留下的。
2. **跨层越界与重复**。macOS Swift 复刻了 Go 的 tag、任务 ID、校验和就绪编排。iOS 则用 Swift 另写了一整套 Go 的校验、依赖闭包、tag 和指纹，还有自己的连接验收。
3. **巨型对象**。10 个文件在 2.3k 到 4.2k 行之间，把多个独立事务揉在一起。另外，约 2.8 万行 Swift（大部分是连接编排和 Provider 代码）不在任何测试 target 里。
4. **文档与代码互相漂移**。有的契约被文档重写误删，导致正确的代码看起来像违反了架构；有些不变量没有标注适用平台，而移动端实际上不满足它们。

可删量估计如下。不依赖任何决定、现在就能删的约 5.5k 行。下文 4 个决定拍板后，还能再删约 9k 到 13k 行。两者合计约占全部代码的十分之一。剩下的工作是拆分和下沉，不是删除。

## 一、核心功能地图

| 层 | 职责（必要） | 规模与健康度 |
|---|---|---|
| Go 配置编译（core/config、core/subscription、libbox/configgen） | Profile 模型与引用校验；TP 和 NE 两套 sing-box 编译；ConnectionPlan；运行指纹；Next 导入导出；订阅转 Line/RuleSet；RuleSet 物化与缓存 | 复杂度与功能匹配。generator.go 有 3068 行，其中 400 行的总函数里有 24 处平台分支；还带着已死的「订阅 × TP」和旧桌面 TUN 分支 |
| Go 运行时（core/libbox） | 冷启动与候选 Switch 事务；Line 能力池（AnyConnect/Tailscale 租约与恢复）；就绪证明；DNS 分派；RuleSet 刷新 | 核心事务与 §5.3 一致。v0.8.0 后有一整片导出成了死代码；active/prepared 成对 API 逐份复制；libbox.go 有 3187 行 |
| root helper（cmd/xdial、core/engine） | 存活的部分：注册维护交接、Tailscale 限时配置会话、连接报告转发、resolver 刷新、DNS 残留恢复；AnyConnect 适配与 Underlay 快照（libbox 复用） | 旧原生 TUN 数据面自 v0.7.0 起没有 App 调用方，但仍然随包发布，且仍可被触达（见二.1） |
| macOS Provider（TransparentProxyExtension、Shared relay） | flow 接入；TCP/UDP 经回环 SOCKS relay；换代排空；冷启动、Switch 与回滚；本机 SOCKS5；报告 journal | 主干必要。EmbeddedSingBoxRuntime 的 start 与 prepareSwitch 是双胞胎，被成对修改过 7 次；Swift 复刻了 Go 的格式；Tailscale 就绪判定写在 Swift 里 |
| macOS 宿主（AppState、TransparentProxyManager、GoEngine、Shared 策略） | 连接意图、Switch 编排、network epoch 与 SSID、自动恢复、Tailscale setup、测速、SOCKS 共享 | 能力与 §3、§5、§8 一一对应。问题有：两个上帝对象；状态多份真相（9 个 transactionID 变量，期望场景有 6 处回退链）；恢复逻辑分散在三层，是 fix 最密集的区域 |
| 安装、更新、配置库 | 自安装与同通道替换；helper 注册与维护租约；System Extension；Pages 清单更新；共享加密配置库 | 主干必要且相称。问题是旧版兼容残留分散；Shared 中只供宿主用的约 2.2k 行被编进了以 root 运行的扩展 |
| macOS UI | Popover、五页设置、Profile 管理、安装与更新窗口、菜单栏图标 | 功能必要。SettingsView 2957 行、MainPopover 1827 行，视图里写着业务逻辑；同一呈现有多份实现；本地化有两套机制并存 |
| iOS | Packet Tunnel 加 App | 能用，但停在 8 月前的上一代模型（没有 Profile Next、线路组、AnyTLS、ConnectionPlan/Report、候选 Switch）。CI 不编译 iOS |
| tvOS | 无 | 真机构建注入 NoopTunnelEngine，canConnect 恒为 false，只能当 Simulator 演示 |

逐项功能判定见附录 A。

## 二、先处理的缺陷（不属于重构）

1. **本地提权面（P034）**：已由 #34 修复（root daemon 拒绝已停用的数据面命令）。
2. **iOS 真机连接疑似每次验收后都被自动断开（P028，已复核；推断，未实机验证）**。a5f761f 给 routing probe tracker 加了 DEBUG 门控，但 iOS/tvOS 的 Provider 从未打开这个门控。于是计数恒为 0，验收恒失败，随后触发 `applyProbeFailure(shouldStop:true)`。修法有两种：打开门控，或者整体删掉移动端验收（三.3）。
3. **iOS DNS 不按 Scenario 的 Line 解析（遗漏审查发现）**。非 Tailnet 名字一律交给企业 DNS；没有企业 DNS 时，就经 Underlay 发到 1.1.1.1:53。这违反 §4.1。ARCHITECTURE §4.2 的入口链接指向的恰好就是这个实现。
4. **v0.7.0 及更早版本手动升级到 v0.7.1+ 必然失败（P084，已复核）**。新包要求旧二进制识别一个它根本不认识的参数，结果旧 App 被完整启动一次，5 分钟后被强杀，安装失败。
5. **iOS 在 07-01 到 08-01 期间写入的配置会丢场景（P138，已复核）**。当时存的是 `modes`，改名时没有写迁移。envelope 格式会被静默解成空场景，raw 格式会被判为 corrupt。这只在当时有构建分发出去的情况下才有影响。
6. **Tailscale 就绪以出口展示服务为硬门槛（P121，已复核）**。就绪前会经 Direct 探测 checkip.amazonaws.com 和 1.1.1.1 trace，失败则整笔事务失败。另外，`underlay-egress-unavailable` 只有这一个来源，所以网络变化后的自动重试实际上只对 Tailscale 场景生效。
7. **文档误删了仍在生效的契约（P120，复核后改判）**。Direct 的 IPv6 TLS 冗余探测是 2026-08-21 实机事故的产物，当时已写进 ARCHITECTURE，后来被 63299e8 的纯文档重写删掉了，代码没有变。正确的做法是把契约和事故证据补回 §4.3，不要删代码。审计员原先建议「按接口有无全局 IPv6 判断」，这恰恰是那次事故证明不够用的信号。

## 三、需要你拍板的 4 个决定

1. **旧原生 TUN 数据面退役吗？**（P033、P036、P003、P040）这部分包括 daemon 的 start/stop/kill-session/runtime-lines、core/engine 的连接路径、外置 sing-box、规则预取、DNS 接管、桌面生成分支和 e2e 脚本，约 5k 到 6k 行（含测试）。删除顺序是先删 daemon start，再删 DNS 自愈，否则会出现「能接管、不能自愈」的窗口。RestoreLeftoverDNS 是否保留，取决于决定 2。需要你确认：仓库外（包括预置配置包的分发流程）没有人在用 `xdial start` 或 daemon start。
2. **最低升级起点定在哪个版本？** 推荐 v0.8.0（或 v0.7.1）。v0.7.0 及更早的用户本来就升不上来（二.4），定起点不会造成真实倒退，只需把失败提示改成「请先卸载旧版」。各起点对应的可删内容：
   - ≥ v0.6.0：可删 /Library helper 清理，约 50 行。
   - ≥ v0.7.0：再删 Tailscale 状态迁移约 244 行，以及 v0.6.0 留下的 DNS 残留自愈。
   - ≥ v0.7.1：再删旧身份迁移，约 220 行。
   - ≥ v0.8.0：再删旧 daemon 的空闲窗口交接约 130 行，以及 respawn。

   需要你回答：v0.7.0 及更早的版本有没有公开发布过、有没有外部用户。
3. **移动端怎么定位？** tvOS 有两个选项：删除（约 600 行，共享源搬到 ios/），或者接上真实引擎并加入 CI。iOS 也有两个选项。一是收敛到 Go 的 ConnectionPlan/Report 和 Profile Next：这样可删 Swift 侧的校验、tag、指纹（约 350 行）、固定公网探针验收（约 900 行，P028 随之消失）、无数据来源的迁移（约 400 行）和重复模型（约 300 行），Go 侧的旧 Subscription 运行时编译器（约 900 行，加约 1500 行测试）也能一起删。二是继续维持现状，那就应该在 ARCHITECTURE 里明确写出移动端例外。
4. **HomeDERP 重选删除吗？**（P018、P132、P154）它在 Swift、cmd、DebugServer 里都没有入口，ARCHITECTURE 却写成「显式维护能力」。删除涉及 Go 约 270 行、Swift 约 140 行，以及 tailscale 补丁 0005 里约 1.2k 行的重选部分。注意：0005 和 0009 里混着与重选无关、影响生产的修复（过期 NetInfo 拒绝、旧 client 防护），这些必须保留并迁出；去掉 receipt 会改变 SetNetInfo 的去重行为，需要真实 Tailscale 线路回归。

## 四、现在就能删（不依赖上面的决定，约 5.5k 行）

- **macOS 宿主与 UI 死代码，约 1.2k 行**（已复核）：
  - KeychainStore.swift 整个文件；ProfileVaultProjection 及其测试；比喻命名迁移；
  - AppState 的 add/update/deleteSubscription 和 activeSubscriptions；GoEngine 的 parseSubscription、sendSubRequest、ParseResult、EngineStatus；
  - ProfileRecord.refreshed 及约 130 行测死代码的测试；场景模板；retry-now 链；helperInstalled 旁路；
  - UI 的 sub: 出口目标和恒值开关；SettingsView、MainPopover 中零引用的成员；多 Profile 时代的 profileID 管线（只删 Switch 部分）；
  - ProfileDocumentService 的 4 个迁移包装及对应的 debug-server.md 段落。
- **Go 与 libbox 死代码，约 2.1k 行**（已复核）：
  - 订阅 × TP 整条链路，包括 Swift 侧的 subscription 任务管道和指纹里的订阅用例；
  - Compact、Separate、Reimport 迁移函数及其 libbox 桥；
  - TP 会话的 4 个测试专用或零调用入口；Line.TailscaleAuthKey；
  - v0.8.0 后的死导出：6 个 PrepareSwitch*、4 个 Start* 变体、Status、ProbeStandaloneLineLatency；peer 探测；DNSCaptureDomains；
  - AnyConnect 旧版重连回退；RefreshPreparedSwitchLineRuntimes；installRoutingProbe；从未写入的 TUN 计数；读 /tmp 的手动测试。
- **构建设施，约 2.2k 行**（已复核）：test/macos_ne_probe 和 test/macos_tp_integration（编不过）；tools/inspector.swift；孤儿 helper plist；Makefile 的 assemble_app 宏；macos/Package.swift（编不过）；cmd/xdial 的 Windows 文件（编不过）；cmd/libboxtest。
- **Provider 诊断，约 150 行**：应用归属账本在 Release 中逐流写入，却只有 DEBUG 读取，应包进 `#if DEBUG` 或删除；另有 Session/Reporter 的死字段。

删除时要注意两点：Codable 解码字段必须保留（旧数据要能解码）；附录 B 每条都写了复核时发现的隐患。

## 五、结构性屎山（要拆分或下沉，不是删除）

- **巨型文件**：TransparentProxyManager 4211、libbox.go 3187、EmbeddedSingBoxRuntime 3175、TransparentProxyProvider 3096、generator.go 3068、SettingsView 2957、AppState 2902、tvOS AppState 2808、tvOS TunnelManager 2303、MainPopover 1827（单位：行）。每个文件的职责分块和行号见附录 B 的 P025、P055、P056、P102、P130、P131、P143、P144。
- **测试缺口**：XDialTests 没有 TEST_HOST，TPM、AppState、GoEngine、Provider、EmbeddedSingBoxRuntime、UDP relay 等约 2.8 万行 Swift 都不在测试 target 里，只能通过抽到 Shared 的策略间接测试。拆分时应先把 NE 依赖放到协议后面，让控制器进入测试 target，再做大规模合并。
- **Swift 复刻 Go**：
  - Provider 自己拼 Go 的任务 ID 和 tag，并校验 Go 的格式；
  - 宿主复刻 AnyTLS、线路组环检测和连接缺口校验；
  - 失败重试资格靠 Swift 白名单加错误文本转译决定；
  - LineAddressFamilyCapabilityCodec 硬编码了 Go 的失败码表；
  - Tailscale BackendState 词表有 4 份解释；
  - Surge/Clash 规则类型支持矩阵有 7 份，至少 3 种集合。
- **同一件事写多份**：
  - Provider 消息通道有 4 套宿主发送路径；
  - TCP 和 UDP relay 的 SOCKS 客户端逐函数复制；
  - UNIX socket 连接代码有 4 份；
  - 流量计数 Swift 和 Go 各一套；
  - 固定公网探针端点分散在 4 层；
  - 状态带脚手架有 6 份，任务状态到文案的映射有 2 份且已漂移。
- **恢复逻辑**：分散在 AppState、GoEngine、TPM 三层，有两套预算加一个所有权枚举来仲裁。应收敛成一个 ConnectionIntentReconciler（见 P068、P160）。
- **Shared 的含义变成了「可测试」，而不是「两进程共享」**：只供宿主用的约 2.2k 行被编进了 root 运行的扩展（P094）。
- **补丁栈只增不改**：sing-box 的 0014 撤销了 0010 的主体；有两个补丁测试包从来没被执行；prepare 脚本靠 92 条 grep 断言兜底（P044 到 P046）。

## 六、文档漂移

- **ARCHITECTURE**：
  - 章节标题里的 D 编号已经没有定义；
  - §4.2 的入口链接指错了文件；
  - §1、§2、§4.1、§4.3、§5.2 的不变量没有标注平台范围，在移动端不成立；
  - Home DERP 被写成现有能力；
  - §8 说 SSID 不进 Debug，实际上 /state 会输出它；
  - IPv6 TLS 契约被误删（二.7）。
- **docs/plans**：global-configuration.md 和 settings-version-entry.md 已经完成，next-interface-redesign.md 已经放弃，profile-subscriptions.md 已被全局配置方案取代，这几份都还留在 plans 目录。profile-next.md 仍把自己写成「Next 测试通道」，并且有多处与代码矛盾。
- **其他**：
  - .golangci.yml 是孤儿配置，CI 名为 lint，实际只跑 gofmt；
  - claude-review.yml 写着「Swift 侧无单测」；
  - Makefile 让开发者 `go install gomobile@latest`，与固定的 v0.1.13 冲突；
  - origin/xdial-next 落后 main 49 个提交，NEXT_RELEASE_NOTES 自 54585fe 起没有更新。

## 建议顺序

1. 先修二.1（daemon 拒绝 start），实机确认二.2 之后再修，再把二.7 的契约补回文档。
2. 第四节的无争议删除，分 2 到 3 个 PR：macOS、Go/libbox、构建设施。
3. 拍板第三节的 4 个决定，然后删第二批。在 ARCHITECTURE §9 写明最低升级起点和退役规则。
4. 结构拆分：先补测试接缝，再拆 TPM、AppState、Provider；合并 start 与 prepareSwitch；把 Swift 复刻 Go 的部分下沉到 Go。
5. 移动端按决定 3 收敛或冻结，在决定之前不再往移动端 Swift 里补规则。

## 附录 A　功能清单（按子系统）

### Go 配置编译

这块代码负责三件事：把 Profile 编译成 sing-box JSON（core/config/generator.go，纯函数，按 macOS Transparent Proxy、iOS/tvOS NE、旧桌面 TUN 三个平台分支）；准备连接用的资源（core/libbox/configgen.go，是 gomobile 适配层，负责解析 JSON、下载/校验/缓存 RuleSet、调用 config.Generate*、对结果做后处理，并组装 Provider 会话信封、计划、Line 身份、AnyConnect/Tailscale 描述）；导入/导出配置（profile_document、subscription_profile 加 core/subscription 解析器）。调用只有一个方向：libbox 调 config，config 不调 libbox。两者不会把同一段 sing-box 配置各生成一份，例外只有几处小重复：Tailscale setup endpoint、tag 命名字面量、Line 身份字段表。核心编译（TP 的 DNS/路由、地址族、应用规则、计划、指纹、引用校验）复杂度和功能是匹配的，属于必要代码。屎山主要集中在三类。第一类是旧路径残留：macOS 已禁止嵌套订阅，所以"订阅 × Transparent Proxy"整条链路是死的；旧桌面 TUN（PlatformMacOS）只剩 CLI 能走到；2026-09-23 那次提交之后，迁移函数及其 libbox 桥已经没有调用方。第二类是 API 变体堆积：同一个 TP 会话入口有 4 个 libbox 导出加 3 个 config 入口。第三类是重复：两套 Surge/Clash 规则编译器、REJECT 名单 4 份、各消费者各自重算活动闭包。测试约 1 万行，大部分不变量（INV1/2/3/4/6/7）实际上守的是不再发布的旧桌面路径，同一条不变量在 2–3 个文件里被重复测试。

| 功能 | 判定 | 约行数 | 说明 |
|---|---|---|---|
| sing-box 配置编译总编排 | 核心 | 400 | ARCHITECTURE §2 规定 Go 是唯一编译者，有效依赖、重复 tag、单例冲突都要在生成阶段失败。问题是这一个 400 行函数里有 24 处平台分支（见 problems） |
| Transparent Proxy 入口、会话凭据与逐 Line 地址族策略 | 核心 | 270 | §3.1 macOS 主入口和 §4.3 地址族规则要求它。不过其中的 API 变体是冗余的，见 problems |
| TP 分阶段 DNS 编译 | 核心 | 280 | §4.1、§4.2 和 D-DNS 要求先确定 Line 再按该 Line 的视角解析 |
| TP 逐 binding 路由编译 | 核心 | 250 | §4.1 要求 binding 顺序和 DNS/route 同源 |
| NE（iOS/tvOS）生成分支 | 核心 | 170 | iOS/tvOS 的 TunnelManager.swift:2036 调用 LibboxGenerateNEConfig，iOS 本月仍在活跃开发 |
| 旧桌面原生 TUN 生成分支（PlatformMacOS） | 存疑 | 280 | 唯一的生产调用方是 core/engine/singbox.go:62，走 cmd/xdial 的 start 命令或 daemon 的 "start"。macOS App 发给 helper 的命令里没有 start（已列出全部 cmd 字面量）。§9 写着旧原生 TUN 保留在 helper/CLI，但没有产品入口会触发它 |
| 代理出站构建与 AnyTLS 校验 | 核心 | 260 | Line 是一等资源，lineHasUsableOutbound 和 fail-closed 都依赖它 |
| Tailscale endpoint 与 MagicDNS | 核心 | 160 | §3.2（D33）要求 |
| 应用进程规则 | 核心 | 200 | macOS 应用分流功能需要；Swift 不重算哈希，符合 §1 |
| RuleSet 资源块、下载 detour 与 tag 命名 | 支撑 | 145 | route.rule_set 需要它们，同时它们是 tag 命名的单一事实源 |
| 引用完整性校验（INV6） | 核心 | 330 | ARCHITECTURE §2 要求引用悬空在生成阶段失败 |
| ConnectionPlan 编译 | 核心 | 290 | §5.1 和 §5.2 要求；macOS TransparentProxyManager.swift:2572 调用 LibboxGenerateConnectionPlan |
| 运行配置指纹 | 核心 | 280 | §5.2：Swift 只比较指纹，不复制算法 |
| 旧 Subscription 运行时编译（NE 专用） | 历史必要 | 900 | iOS/tvOS 的 AppState/GoEngine/TunnelManager 仍把 Profile.subscriptions 作为运行对象（appletv/XDialTV/GoEngine.swift:115、TunnelManager.swift:182）。macOS 不用。与 Next 导入是两套编译器，见 problems |
| 订阅 × Transparent Proxy 路径 | 死代码 | 250 | macOS 在 GlobalConfiguration.swift:119/152/241/370、ProfileLibrary.swift:172、ExistingXDialProfileReader.swift:80 全面拒绝嵌套订阅，所以 TP 拿到的 Profile.Subscriptions 恒为空。iOS/tvOS 不调用 BuildConnectionPlan，也不走 TP |
| Next 文档导入/导出 | 核心 | 800 | DESIGN 的 Profile 导入/导出与 §2 的首次只读转换旧配置；Swift 端通过 LibboxImportProfile/ExportProfile/ValidateProfileDocument 使用 |
| 订阅 → Next 资源转换与导入后整理 | 核心 | 700 | macOS Next 导入订阅的唯一路径（ProfileDocumentService.read → LibboxImportProfile），§7 明确描述 |
| 一次性迁移：Compact、Separate、Reimport | 死代码 | 290 | macOS 的调用点在 54585fe（2026-09-23）被删除，只剩 Swift 包装函数，没有调用方。现在只有 tools/profile-document-check.swift 和 Go 测试在用 |
| 原生资源、组、克隆与存储路径 | 核心 | 356 | Swift 调用 LibboxCloneProfile 和 LibboxProfileStoragePath；Tailscale 身份目录依赖它 |
| Tailscale 通道投影 | 支撑 | 98 | §3.2 通道前缀；daemon 和 libbox 都在用 |
| 订阅解析器（严格路径） | 核心 | 1150 | macOS Next 导入和 iOS/tvOS 订阅都依赖 ParseStrict 和 ExpandRulesetsStrict；FetchStrictBytes 还用于 RuleSet 下载 |
| 订阅非严格抓取路径 | 历史可删 | 70 | 只被 cmd/xdial/cmd_sub.go 和 daemon 的 parse-sub 调用。macOS 唯一的发送方 GoEngine.parseSubscription 没有调用方 |
| libbox TP 会话信封 | 核心 | 500 | §5.3 的 Line 租约身份和 Provider 只消费 Go 产物的约定要求它 |
| libbox RuleSet 获取会话（bootstrap） | 核心 | 240 | §7 要求 |
| libbox RuleSet 物化、缓存与文本转换 | 核心 | 750 | §7 的缓存语义；TP 分阶段 DNS 依赖 RuntimeMatchKind |
| Tailscale setup 配置 | 核心 | 85 | §3.2 的 setup session |
| Tailscale 主机名生成器 | 死代码 | 70 | 全仓库（含测试和 Swift）没有任何调用；Swift 自己用 "xdial-" 加 id 前缀生成主机名（ProfileDocumentService.swift:76） |
| Line.TailscaleAuthKey 旧字段 | 历史可删 | 25 | macOS、iOS、tvOS 的 Swift Line 模型都没有 tailscale_auth_key 字段，Swift 编码出的 profileJSON 里恒为空 |
| 连通性验收规则前置 | 存疑 | 25 | 只有 iOS/tvOS 使用这两个 ID，而 Swift 端已经把它们规范化到 bindings 最前面（appletv/XDialTV/Models.swift:584），Go 端再做一次是重复 |

### Go 运行时 libbox

core/libbox 在本范围内约 10.1k 行生产代码、8.9k 行测试，内容是：gomobile 门面、进程内 sing-box 数据面、冷启动和候选 Switch 两个事务、Line 能力池（AnyConnect / Tailscale 租约与恢复）、就绪证明，以及探测/测速/诊断。核心事务、能力池和就绪证明与 ARCHITECTURE §4.3、§5.3 基本一致，复杂度多数有依据（address_probe_policy 和 DESIGN §4.3 的描述逐条对得上）。问题集中在四类。一是 macOS 统一改走 StartForNetwork / PrepareSwitchForNetwork 后，旧导出面整片死掉：6 个 PrepareSwitch*、4 个 Start* 变体、Status，还有 Tailscale peer 探测 / HomeDERP 重选 / DNSCaptureDomains。HomeDERP 重选背后挂着一个 2083 行的 tailscale 补丁。二是死分支：旧的 AnyConnect 重连、恒为空操作的 RefreshPreparedSwitchLineRuntimes。三是 active / prepared 成对 API 逐份复制，Libbox 上的投影字段和能力本体重复。四是 libbox.go 一个文件 3187 行，混了 10 多块职责。保守估计可删或合并约 1400 行（含测试）。另外实锤一处回归：tvOS/iOS 的路由证据 tracker 从未被启用，数据面验收因此恒失败。

| 功能 | 判定 | 约行数 | 说明 |
|---|---|---|---|
| gomobile 门面与平台输入 | 核心 | 1100 | 三平台 Swift 宿主都靠它把 NWPath 与 TUN fd 交给盒内；ARCHITECTURE §3.1 的 Underlay 事实输入就在这里（Swift 调用点：EmbeddedSingBoxRuntime.swift:446-453、PacketTunnelProvider.swift、LocalTailscaleSetupRuntime.swift） |
| 冷启动连接事务 | 核心 | 520 | 对应 §5.1 的 preparing→committed；Stop 与晚到的准备结果互相竞争时的处理有测试覆盖（switch_test.go:313） |
| 候选 Switch 事务 | 核心 | 1000 | §5.3 要求的 make-before-break、最多一个候选、提交中失败恢复旧代，都在这里实现；目前只有 macOS 使用 |
| Line 能力池与租约 | 核心 | 395 | 和 §5.3 逐条对应（唯一候选、最后租约才停、不并发第二个握手）；只有 exclusive 参数是多余的（见问题） |
| AnyConnect 能力、恢复与盒内出口 | 核心 | 1000 | §3.3 / §5.4 规定恢复由 Line 自己负责、局部预算耗尽才升级为完整恢复；macOS 与 tvOS 都在用 |
| AnyConnect 旧版 session 重连回退 | 死代码 | 140 | 生产代码中凡是设置 session 的路径都同时设置了 capability，这个分支不可达；它已被 05af780 的 runRecovery 取代 |
| Tailscale 进程级能力 | 核心 | 650 | §3.2 / §5.3 要求切换时复用同一身份的 endpoint，同时防止两个实例共用一份状态目录 |
| Tailscale 状态、登录、MagicDNS 快照、非 home DERP 释放 | 核心 | 700 | §3.2 MagicDNS 快照契约和登录管理需要；DERP 路径的 23 个字段被 Swift 的 TailscaleEgressFailure 分类消费（Swift 侧 rg 'reply_route_state' 等有命中） |
| Tailscale peer 探测、HomeDERP 重选、DNSCaptureDomains | 死代码 | 300 | 三个平台的 Swift 都没有调用方；重选功能独占 patches/tailscale/0005 的主体 |
| Line 网络就绪证明与出口 TLS 能力探测 | 核心 | 1180 | §4.3、§5.3 规定 Commit 前必须有当前 epoch/revision 的证明；Direct 只用 Underlay 上下文作证明的规则也由它保证 |
| 出口公网地址观察 | 支撑 | 560 | DESIGN.md:156-161 明确描述了按地址族的竞速与限流，复杂度与之相符；非 family 的旧版本被 Swift 拿去当就绪门槛，越了界（见问题） |
| 测速与原生组选线 | 支撑 | 470 | DESIGN.md:347-379 与 ARCHITECTURE §2 的独立测速会话；内部有循环、常量重复 |
| RuleSet 经精确出口刷新 | 核心 | 110 | §7 RuleSet 资源经 fetch Line 获取；macOS 有两处调用 |
| 移动端 DNS 分派 | 核心 | 330 | iOS/tvOS 的 NE 配置由 generator.go:1281 生成；§3.2 写明快照契约不扩展到 iOS/tvOS，这条路径独立存在 |
| 路由观察（route watch experiment） | 支撑 | 350 | §5.2 的短时 route watch；只在 macOS DEBUG 开启（EmbeddedSingBoxRuntime.swift:445-447） |
| 路由固定目标计数（1.0.0.1 / 1.1.1.1） | 存疑 | 80 | macOS 不读；tvOS/iOS 读，但 tracker 在这两端从未安装，恒为 0 |
| 流量累计 | 支撑 | 106 | iOS 首页速率（5ab8ff1）、tvOS 使用；macOS 上与 Swift relay 计数重复 |
| 诊断快照 | 支撑 | 170 | macOS 判定 AnyConnect 失败证据、tvOS 判定启动阶段要用；其中 TUN 收发计数从未写入 |
| 精简 sing-box 注册表 | 核心 | 88 | 受 NE 内存预算约束；自定义 vpn / xdial-tailscale-runtime / xdial-mobile / xdial-anyconnect 都在这里注册 |
| 无 gVisor 构建 stub | 历史必要 | 110 | CI 的 make go-vet / go-build 不带 tag 编译 ./...；其中 mobile_no_tailscale 分支从未被使用 |
| 旧版 / 未用 gomobile 入口 | 历史可删 | 320 | 已被 ForNetwork 入口取代；Swift 没有调用方，Go 侧只有测试在用 |
| RefreshPreparedSwitchLineRuntimes 与非 network 切换分支 | 死代码 | 65 | 生产里 candidate.networkReadiness 恒不为空，函数入口就 return nil |
| Tailscale 进程级能力（续）：SetTunOpener 测试缝 | 支撑 | 15 | dataplane_test 离线集成测试需要；生产不调用，注释已说明 |

### Go 旧引擎 / CLI / 构建设施

这个范围里混着三类东西。第一类是仍在发布、确实必要的：root daemon 的安装交接、Tailscale 配置会话、连接报告转发、mDNSResponder 刷新，AnyConnect 适配（sslcon.go、bridge.go）和 Underlay 快照，另有发布与签名脚本和三套补丁。第二类是旧原生 TUN 数据面，自 v0.7.0（a5f761f，2026-07-30）起宿主不再发 daemon `start`，GoEngine 还明确忽略 daemon 的 status/error 事件。旧数据面现在只剩 CLI 和一个没接进任何入口的 e2e 脚本能触达。这部分约 3.5k 行（含测试）可以直接删，里面的规则集预取语义还与 ARCHITECTURE §7 相反，root 进程还会执行用户可写路径下的 sing-box。第三类是只为 v0.6.0 等旧版本兼容而存在的代码：DNS 残留自愈约 2.2k 行、/Library 旧 helper 清理、protocol<1 交接、Tailscale 身份迁移，能删多少取决于作者定的最低升级起点。构建设施整体健康，但有几处问题：补丁栈只增不改（0010 被 0014 完全撤销），补丁脚本靠 92 条 grep 断言兜底，两个补丁测试包没被任何目标跑到，cmd/xdial 的测试不在 CI，CI 却在跑约 2.3k 行已死路径的测试。

| 功能 | 判定 | 约行数 | 说明 |
|---|---|---|---|
| 旧原生 TUN 数据面引擎（Engine.Start/connectInternal/monitorVPN/reconnect/startSOCKS/handleSingBoxExit/KillSession/SOCKSAddr + 状态机） | 死代码 | 1050 | 宿主自 a5f761f（v0.7.0）起不再发 daemon `start`。GoEngine.swift:860-869 明确忽略 helper 的 status/error 事件（"helper 不再拥有桌面数据面"）。剩下的调用方只有 `xdial start` CLI（不随产品分发，且依赖 Homebrew 的 sing-box）和 test/e2e_test.py |
| 外置 sing-box 子进程管理 | 历史可删 | 381 | 只被旧 TUN 引擎调用。当前数据面是进程内 Libbox，不再 exec sing-box |
| 旧 TUN 远程规则集预取 | 历史可删 | 804 | 只被 engine.connectInternal 调用。它和 libbox/configgen.go 的 NE 规则集物化重复，失败策略还与 ARCHITECTURE §7「失败归因对应 RuleSet，不静默换 Direct」相反（ruleset_prefetch.go:95 `ruleSet.Enabled = false`） |
| 旧 TUN Tailscale 出口就绪探测 | 历史可删 | 266 | 只被 engine.connectInternal 调用。TP 路径有自己的就绪证明 |
| 系统 DNS 接管（Takeover 方向） | 历史可删 | 1190 | 只有 engine.takeoverDNSLocked 会调用，而它只在旧 TUN 连接里触发。只有 v0.6.0 正式发布过这条路径（v0.5.0 的 core/engine 里没有 dns_takeover.go） |
| 系统 DNS 残留自愈（Restore/RestoreLeftover/SelfHeal/后台重试/状态文件） | 历史必要 | 2300 | ARCHITECTURE §9 要求保留清理能力。现在唯一可能的残留来源是 v0.6.0 的 daemon 崩溃（其状态路径与当前正式通道相同），所有 v0.7+ daemon 启动时都已执行过一次 RestoreLeftover |
| Underlay 默认接口快照 | 核心 | 297 | 宿主 TransparentProxyManager.swift:3689 通过 LibboxDetectUnderlayInterface 调用，core/tailscalesetup/manager_gvisor.go:78 也在用。其中 parseDefaultRouteIsGlobal 和 detectDataPlaneUnderlayInterface（拒绝 GLOBAL 路由）只服务旧 TUN，可以删 |
| AnyConnect 协议适配（VPNClient / VPNBridge / 会话诊断） | 核心 | 463 | core/libbox 在 libbox.go:241、anyconnect_runtime.go、vpn_outbound.go、mobile_dns_transport_enterprise.go 中直接使用，是 ARCHITECTURE §1 所说的「协议适配器」 |
| root daemon 进程骨架 | 支撑 | 420 | 宿主所有特权请求都经由这个 socket |
| daemon 注册维护交接（registration-handoff/commit/abort/finalize、daemon-info） | 核心 | 975 | ARCHITECTURE §6 的安装与更新事务需要它，PrivilegeManager.swift:222-395 是调用方 |
| Tailscale 限时配置会话（tailscale-prepare/status/login/logout/stop-setup） | 核心 | 520 | ARCHITECTURE §3.2 规定的 setup session。GoEngine.swift:236-593 是调用方 |
| Tailscale 身份目录一次性迁移 | 历史必要 | 237 | 服务于从 v0.6.0 升级的用户，有 marker 保证幂等。确定最低升级起点后可以删 |
| Provider 连接报告转发（connection-report） | 核心 | 110 | ARCHITECTURE §5.2「helper 只读转发」。TransparentProxyManager.swift:2661 是调用方 |
| mDNSResponder 查询器重建（resolver-refresh） | 支撑 | 206 | Transparent Proxy 的平台缺陷补救，GoEngine.swift:930 是调用方 |
| 订阅解析经 root daemon（parse-sub）及 CLI `xdial sub parse` | 存疑 | 75 | tvOS 用的是进程内 LibboxParseSubscription（ParseStrict、ExpandRulesetsStrict、校验加清洗），macOS 宿主本身也链接了 Libbox。两端严格度不同，而且 root 进程在抓任意 URL |
| 孤儿 sing-box 清理 | 历史可删 | 60 | v0.7+ 不再 spawn 外置 sing-box，只有 v0.6.0 或 CLI 残留时才会命中 |
| Windows/Linux 平台适配 | 死代码 | 75 | cmd/xdial 在 Windows 上编译不过：registration_handoff.go 用了 syscall.LOCK_SH、Flock、O_NOFOLLOW、Stat_t，GOROOT/src/syscall 里没有这些符号的 Windows 实现。Linux 只用于 ubuntu CI 的 go build/vet，没有产品 |
| 运行身份表（Go 侧） | 支撑 | 192 | daemon 默认值和 App Group 路径需要它。其中 4 个字段只在测试里断言过 |
| cmd/libboxtest 手测工具 | 历史可删 | 125 | 自 2026-07-02 起没有改动，不走 Profile/生成器，也没有任何地方引用，只在 CI 的 go build ./... 里被编译 |
| 补丁化依赖构建（prepare-patched-go-mod.sh + test-patched-*） | 核心 | 550 | 所有产物都依赖它 |
| sing-box 补丁（15 个：0001-0011、0013-0016，没有 0012） | 核心 | 3600 | 实现 ARCHITECTURE §3.1、§3.2、§4.2 的盒内能力。补丁栈本身的结构问题见 problems |
| tailscale 补丁（10 个） | 核心 | 4850 | ARCHITECTURE §3.2 的 Tailscale 行为与证据都依赖这些补丁，宿主和 Provider 也在使用 TailscalePeerDERPPath |
| sslcon 补丁（2 个） | 核心 | 1870 | libbox 通过 engine.AnyConnectSessionDiagnostics 使用 |
| 发布与身份契约脚本 | 核心 | 1880 | Makefile 的 release、publish、app 目标和 CI 都引用它们，每个脚本都有调用方 |
| 图标生成与本地重启/启动工具 | 支撑 | 526 | 由 Makefile 目标和 test/menu_bar_recovery_test.sh 引用 |
| tools/profile-document-check.swift 与 gomobiletool | 支撑 | 87 | 分别被 Makefile 的 test-profile-document-bridge 引用，以及被 go mod tidy 需要 |
| tools/inspector.swift（AX 检查器） | 死代码 | 213 | 它硬编码查找 `com.kafeifei.xdial`，而现有身份是 .app、.debug、.next（bb53e99/v0.7.1 起），所以找不到任何进程。DebugServer 已经覆盖这个功能，文件自 2026-05-08 起没有改动 |
| tools/repair-menu-bar-tracking.swift 与菜单栏恢复夹具 | 存疑 | 194 | Makefile、CI、docs 都没有引用（grep 结果为 0） |
| 发布契约与安装/布局测试 | 支撑 | 977 | 由 make test-release-contract（CI 中 test-macos-transaction 的依赖）、test-installation-launch、test-scenario-layout 引用 |
| test/e2e_test.py 密封盒验收 | 历史可删 | 1029 | 它驱动的正是已死的旧 TUN 路径。它读的是旧存储（com.kafeifei.xdial 偏好里的 xdial.profile、~/.xdial/vault.json），没有接入任何 Makefile、CI 或 docs |
| test/macos_ne_probe 与 test/macos_tp_integration | 死代码 | 1738 | 两者都没有被引用。tp_integration 的 start-current 只传 `profile`，Provider 会以 missingTransaction 拒绝（TransparentProxyProvider.swift:216-229）。两个工程的 sources 都没包含 macos/Shared，按现状无法编译 |
| Makefile 构建、发布与测试目标 | 核心 | 528 | 所有产物和 CI 都从这里走。test-macos-transaction 里的 42 条 rg 门禁我只读执行过一遍，全部通过，属于事故驱动的累积但仍然有效；assemble_app 宏已死 |
| daemon launchd plist 与 entitlements（app/debug/next） | 核心 | 125 | project.yml 的 XDIAL_DAEMON_PLIST/ENTITLEMENTS 引用它们，verify-macos-identity-contract.sh 和 verify-macos-debug-app.py 会校验 |
| macos/com.kafeifei.xdial.helper.plist | 死代码 | 34 | bb53e99（v0.7.1）删掉了它在 Makefile、project.yml、PrivilegeManager 里的全部引用，现在全仓 grep 为 0 |
| PrivilegeManager：旧版兼容（/Library helper 清理、protocol<1 交接、respawn） | 历史必要 | 90 | 分别对应从 ≤v0.5.0、≤v0.7.3 升级的路径。requestRespawn 自 f85bbfd（v0.8.0）起在 Swift 侧已经没有调用方 |

### macOS 宿主：连接与状态

这个范围是 macOS 宿主的连接编排与状态层，约 1.9 万行（Sources 约 12.7k，Shared 约 6.3k），另有约 8.3k 行测试。它负责完整连接事务、staged Switch、network epoch 与 SSID、自动恢复、报告镜像、测速与诊断、Tailscale 配置会话、本机 SOCKS 共享。主干能力和 ARCHITECTURE §3、§5、§8 一一对应，大部分复杂度有依据。Shared 下的小策略类型（Automatic*Policy、*Gate、*Selection）总体不算过度拆分，原因是 TransparentProxyManager、AppState、GoEngine 合计约 8.1k 行都不在 XDialTests 的 sources 里，这些策略是唯一能测的地方。屎山主要有五类：一是两个巨型对象（TPM 4211 行、51 个状态变量；AppState 2902 行、约 70 个存储状态），把安装、连接、Switch、恢复、Tailscale、诊断、SOCKS 揉在一起；二是同一事实多份真相，比如运行态门禁跑两遍、9 个 transactionID 变量、"期望场景" 6 处回退链、3 个睡眠闸门；三是同一个 Provider 消息通道有 4 套发送路径；四是 Swift 复制了 Go 的校验（AnyTLS、线路组环检测、连接缺口、Tailscale 身份）；五是约 450 行可以直接删的死代码或历史残留，包括 macOS 订阅解析链、比喻命名迁移、retry-now 链、场景模板，以及多 Profile 维度的 profileID 管线。MenuBarRecovery 不是层层叠加的补丁（只有 2 次提交），但其中 TrackingRepair 会改写 Apple Control Center 的偏好设置 plist，这一点存疑。

| 功能 | 判定 | 约行数 | 说明 |
|---|---|---|---|
| 完整连接事务启动（宿主侧） | 核心 | 460 | ARCHITECTURE §5.1 规定的连接事务入口；带 intentID 防迟到回调，复杂度和事务语义相符 |
| 宿主 Underlay 快照、捕获与监控 | 核心 | 650 | ARCHITECTURE §3.1/§5.4：启动前 Underlay 是不透明事实，network epoch 合并物理变化 |
| Scenario Switch 客户端（宿主侧 staged switch） | 核心 | 1470 | ARCHITECTURE §5.3：候选准备期间旧 generation 继续承载流量，latest-wins，结果不确定时先对账；复杂度来自真实的竞态 |
| 场景切换编排（AppState single-flight） | 核心 | 690 | ARCHITECTURE §5.3/§5.4 的宿主侧意图编排；AutomaticScenarioSwitchRetryPolicy 是其可测缝 |
| network epoch 合并与 SSID 场景激活 | 核心 | 1390 | ARCHITECTURE §5.4、§8（D39）明确要求 |
| 自动重连（Provider 掉线／启动自动连接失败） | 核心 | 730 | ARCHITECTURE §5.4 规定共享五次预算、显式断开取消恢复 |
| 期望连接、启动自动连接与唤醒恢复（AppState） | 支撑 | 700 | 需要表达用户的长期连接意图，但它是和 TPM 自动重连并列的第二套恢复引擎（见 problems） |
| 连接报告模型、journal 与残留事务协调 | 核心 | 1810 | ARCHITECTURE §5.2：运行事实来自带 transaction ID 的 ConnectionReport，残留事务按所有权回收 |
| 运行态门禁与状态投影 | 核心 | 390 | ARCHITECTURE §5.2：NE 的 connected 不能替代事务事实；但门禁目前算了两遍（见 problems） |
| System Extension 激活/卸载与 NE 配置选择 | 支撑 | 470 | 安装事务（ARCHITECTURE §6）依赖它；放在连接管理器里属于职责混放 |
| Provider 诊断 IPC 与出口/流量观察 | 支撑 | 1970 | ARCHITECTURE §5.2：Provider 诊断限定当前事务的 active Line；DESIGN 有出口 IP 和流量展示 |
| 线路测速（运行时加独立测速） | 核心 | 564 | ARCHITECTURE §2 明确定义了独立测速会话 |
| Tailscale 配置会话与登录 | 支撑 | 610 | ARCHITECTURE §2/§3.2：限时 Tailscale 配置会话是独立资源会话；目前分散在 4 层（见 problems） |
| Tailscale 就绪判定（Provider 专用，位于 Shared） | 核心 | 526 | Tailscale Line 就绪证明（ARCHITECTURE §3.2/§4.3），只由 EmbeddedSingBoxRuntime 使用 |
| 本机 SOCKS5 共享与入口模式 | 核心 | 450 | 现行产品功能（DESIGN §217 一带），宿主只改变回环监听 |
| 配置脏标记（运行指纹比较） | 核心 | 150 | ARCHITECTURE §5.2：Swift 只比较指纹 |
| 连接前配置缺口提示 | 支撑 | 127 | UX 必需，但判定逻辑复制了 Go 生成器的拒绝条件 |
| Profile 库投影、引用校验与编辑入口 | 支撑 | 725 | ARCHITECTURE §2：宿主把资源目录、全局组和场景投影成一个临时 Profile 交给 Go |
| 领域模型 | 核心 | 1165 | UI 编辑和跨语言 JSON 合同需要；其中有死代码和校验复制（见 problems） |
| helper 控制面客户端与 resolver 刷新 | 支撑 | 310 | Tailscale 配置会话和 DNS 自愈需要；类名 GoEngine 是历史遗留 |
| 菜单栏条目丢失恢复 | 历史必要 | 247 | 针对 macOS 26 的事故修复（fe86693，2026-09-12），只有 2 次提交，不是层层叠加 |
| Control Center 跟踪记录修复 | 存疑 | 109 | 改写 Apple 系统组件的偏好设置，超出“只叠加网络层”的姿态；有备份和严格 schema 校验，但缺少退役条件 |
| 菜单栏错误呈现与 Switch 失败确认 | 支撑 | 142 | DESIGN §4.2 要求关闭 Switch 失败提示后叹号同步消失 |
| 进程入口模式与退出排空 | 支撑 | 811 | ARCHITECTURE §6：退出在任何时候都成立，安装和事务有界收尾 |
| 断线事件历史 journal | 存疑 | 450 | Release 只写不读，唯一读取方是 #if DEBUG 的 DebugServer:239 |
| Provider 专用策略（位于 Shared） | 核心 | 400 | Provider 的就绪和回滚规则；放在 Shared 是为了可测试，不是因为两个进程共享 |
| macOS 订阅解析链与比喻命名迁移 | 死代码 | 200 | macOS 内 0 调用方；UI 调用自 ec2f29d（2026-09-14）起已移除 |
| 多 Profile 维度残留（profileID 管线） | 历史可删 | 150 | schema 3 下 activeProfileID 恒为 "global-configuration"，catalog 只有一份 |
| retry-now 链、场景模板等零散死代码 | 死代码 | 170 | 均已 grep 确认 0 生产调用方（见 problems） |
| helper 安装状态旁路（helperInstalled/checkHelper） | 历史可删 | 45 | 安装真相已由 InstallationReport 表达；这两个字段只有 DEBUG 的 DebugServer 读取 |
| Line verified 回写、开机启动与应用日志 | 支撑 | 70 | 展示和平台集成需要；appLog 放在 GoEngine.swift 位置不当 |
| DEBUG 故障注入与诊断属性 | 支撑 | 160 | Debug 验收需要，已用 #if DEBUG 隔离（诊断属性除外） |

### macOS 安装 / 更新 / 配置库 / 诊断

这部分代码负责以下几件事：macOS 版从下载包自安装到 /Applications，以及同通道替换；SMAppService helper 的注册与维护租约；System Extension 激活与安装报告；基于 Pages 清单的应用内更新；共享加密 Profile 配置库，以及旧配置的首次只读转换；卸载；Debug 诊断服务；Settings Dock 载体。主干复杂度与 ARCHITECTURE 第 6 节、updates.md 的合同一一对应，属于必要复杂度，不算屎山。主干包括安装事务、HelperRegistrationCoordinator 状态机、更新链路和共享加密库。更新链路 6 个文件按职责切分，彼此不重叠；AppUpdateCheckerTests 长在格式冗长，测试价值本身并不虚高。真正的屎山有三类。第一类是无调用方的死代码，合计约 750 行（含测试），已核实。包括：macOS KeychainStore 整个文件；ProfileRecord.refreshed 旧刷新合并及其约 130 行测试；ProfileVaultProjection；已被 DebugServer 用 409 封掉的 4 个旧路由迁移包装；AppState 里的旧比喻 key 改写；若干零散成员。第二类是为 ≤v0.7.x 用户层层保留的迁移残留，涉及旧应用身份、/Library helper、无 handoff 协议的 daemon、误拼的 Debug 路径。其中旧身份迁移依赖 v0.7.0 二进制并不存在的命令行参数，大概率从未生效。第三类是重复与职责混杂：UNIX socket 连接代码有 4 份，凭据字段与通道身份常量多处手抄；ApplicationRelocator 和 PrivilegeManager 各自承担 6–10 类事务；只给宿主用的安装代码放在会编进 Network Extension 的 Shared 目录。

| 功能 | 判定 | 约行数 | 说明 |
|---|---|---|---|
| 启动时自安装与同通道替换 | 核心 | 1250 | ARCHITECTURE 第 6 节明确要求：同通道替换须身份签名匹配，保留临时旧包，二次验签后清理，失败恢复旧包；复杂度与合同一致 |
| 安装包签名与嵌套组件身份校验 | 核心 | 250 | 替换和更新的安全前提，每次替换、更新都会调用 |
| 安装事务编排与安装报告 | 核心 | 700 | ARCHITECTURE 第 6 节的 InstallationReport、可退出与续接要求的直接实现 |
| helper 注册、刷新与维护租约 | 核心 | 1150 | 由事故驱动但边界清楚（2026-10-13-fresh-registration-launch-constraint），IO 已注入，测试充分 |
| 替换前拆除旧 helper | 核心 | 230 | 保证旧容器在注销完成屏障之前不被移走，日常升级每次都走这条路径 |
| 卸载与数据删除 | 核心 | 200 | ARCHITECTURE 第 6 节要求：勾选删除数据时清理新旧配置及凭据，并先退出其他版本 |
| 更新清单查询（Pages feed） | 核心 | 990 | 逐条对应 docs/agent/updates.md 的清单合同；git 历史无 GitHub API 残留 |
| 更新候选策略与重启意图 | 核心 | 515 | 候选身份绑定是 ARCHITECTURE 第 6 节要求；文件名 AppUpdateTransaction 名不副实，见问题 19 |
| 更新下载、暂存与包校验 | 核心 | 610 | 下载与安装前重新确认候选、校验嵌套签名是合同要求 |
| 更新状态机与交接 | 核心 | 480 | 满足「点击安装才交接、不改变当前连接」的要求 |
| 更新窗口 UI | 支撑 | 286 | 正式版更新入口 |
| 共享加密配置库存储 | 核心 | 260 | ARCHITECTURE 第 6 节：各通道共享配置库、跨进程写入防覆盖 |
| Profile 文档与订阅的 Go 桥 | 核心 | 130 | Swift 只做 IO，解析与校验交给 Go，符合所有权边界 |
| 首次旧配置只读转换 | 历史必要 | 170 | ARCHITECTURE 第 6 节明确要求「首次只读转换旧配置」；在旧版用户全部迁移前不能删 |
| 库 schema v1/v2 升到 v3 及迁移备份 | 历史必要 | 40 | v1/v2 库只来自 2026-09-14~23 的本地 Next 构建；但 library(with:) 与 seed 首建仍借这条晋升路径，见问题 11 |
| 企业预置（seed）Profile | 支撑 | 150 | 预置配置包通过它首启注入 Profile；只是代码寄居在名为 Migration 的文件里 |
| 旧 per-Profile 订阅刷新合并 ProfileRecord.refreshed | 死代码 | 90 | 生产代码零调用，真实路径已换成 ProfileLibrary.refreshing(profileID:)，见问题 2 |
| ProfileVaultProjection | 死代码 | 75 | 只有测试引用，见问题 3 |
| macOS 旧 vault 存储 KeychainStore | 死代码 | 173 | 2026-09-18 以后零调用，见问题 1 |
| 旧路由迁移包装（reimport/group/separate/compact） | 死代码 | 60 | Swift 侧零调用，DebugServer 对这 4 个 action 一律返回 409，见问题 4 |
| Next 导入旧 Debug 配置命令行 | 历史可删 | 60 | 属于 Next 隔离库时代的入口，共享库已自动转换，见问题 10 |
| 旧应用身份迁移（com.kafeifei.xdial / ne-probe → .app） | 历史可删 | 200 | 只服务 ≤v0.7.0，而该版二进制不支持这个参数，见问题 7 |
| 旧 /Library 特权 helper 残留清理 | 历史必要 | 60 | v0.5.0 的旧 daemon 与当前正式版共用 /tmp/xdial.sock，残留会抢占 socket；能否删取决于是否还有 ≤v0.5.0 用户，见问题 9 |
| 无 handoff 协议旧 daemon 的空闲窗口迁移 | 历史必要 | 90 | 只服务 ≤v0.7.x 的 daemon（v0.8.0 起都带协议），见问题 8 |
| 误拼 Debug 路径（XDail Debug.app）接管与退役 | 历史必要 | 70 | 2026-10-13 刚引入，只影响开发机；迁移完成后可删 |
| 无 receipt 旧安装临时文件回收 | 历史必要 | 15 | 体量小，用于清理 v0.7.x 时代的遗留文件 |
| 无调用方的维护命令行入口 | 存疑 | 50 | 仓库及所有历史 tag 中都没有程序调用，可能是作者的人工排障入口，见问题 12 |
| Debug 诊断 HTTP 服务 | 支撑 | 1100 | 只在 DEBUG 下编译，Release 不含；docs/agent/debug-server.md 与 restart 脚本依赖它；规模大但多为必要的验收面，可小幅修剪，见问题 21 |
| Settings Dock 载体 | 支撑 | 230 | DESIGN.md 第 47–51 行明确要求：主实例保持 LSUIElement，由载体提供 Dock 入口且不暴露内部名称；仍然需要 |
| 通道身份表 | 核心 | 166 | 保证通道隔离；但同样的数据在其他文件里多处手抄，见问题 18 |
| 配置编辑器 UI 状态 | 支撑 | 99 | 设置窗口直接使用 |
| 应用规则 bundle 采集 | 支撑 | 53 | SettingsView.swift:2080 调用；文件名仍是旧名 SignatureCollector，与类型名 ApplicationRuleBundleCollector 不符 |
| RuleSet 预设目录与 JSONValue | 支撑 | 170 | SettingsView 与 Models、NativeResourceViews 在用；只给宿主用，却放在 Shared |

### macOS UI

macOS UI 覆盖了 DESIGN.md 描述的所有产品表面：菜单栏图标、Popover、五页设置窗口、Profile 管理、安装/卸载窗口、更新窗口、Dock 载体。功能大体是必要的，复杂度主要来自真实需求，例如原生 NSTableView 用于大列表、场景/线路组/延迟交互。屎山集中在三类：(1) 视图承担业务与状态推导，且这部分不在 XDialTests 编译清单里，等于没有单测覆盖：Tailscale 登录编排写在 LineRow 里，Popover 的场景动作状态机、按错误字符串猜失败类别、Profile 的增删导入写在视图中；(2) 同一呈现被复制多份并已出现漂移：折叠线路行头有 AppKit 与 SwiftUI 两份，任务状态到文案/颜色的映射两份，状态带脚手架 6 份，SSID 权限文案 4 份；(3) schema v3「全局配置」迁移后留下的残留：恒为 true/false 的旧开关、Profile 内 Subscription（sub:）目标、未被投递的通知、死视图，以及过期的文档、计划与图标草稿。本地化实际以约 400 处 state.tr(zh,en) 为主，xcstrings 只有 7 个键，另有约 200 处中文字面量未本地化，与 DESIGN.md 的说法不符。两套调色板是分层关系（原始 hex 与自适应语义色），供图标生成器单独编译使用，不算重复。整体健康度中等：功能边界清楚，但 SettingsView（2957 行、15 个类型）与 MainPopover（1827 行）需要拆分，并把业务推导下沉到 AppState 或 Go。

| 功能 | 判定 | 约行数 | 说明 |
|---|---|---|---|
| Popover 场景圆球网格与连接/取消/断开/切换/重试主操作 | 核心 | 370 | DESIGN §4.1/§4.2 的唯一主操作入口；但状态机写在视图里（见问题） |
| Popover 标题栏 | 核心 | 150 | DESIGN §2/§4.1 明确要求 |
| Popover 状态带（进度/待应用/配置阻塞/Wi-Fi 权限/仅 SOCKS5/切换失败） | 核心 | 370 | DESIGN §4.4/§4.5/§5.1 要求；实现上脚手架重复 5 次 |
| Popover 连接详情（速率、线路地址与延迟、分流映射、失败事实） | 核心 | 560 | DESIGN §4.3/§4.4；其中 failurePresentation 按字符串分类，违反 §4.4 |
| 设置窗口外壳与顶栏导航 | 核心 | 230 | DESIGN §5.1 |
| 配置待应用状态轨 | 核心 | 80 | DESIGN §5.6；与 Popover 版本重复实现 |
| 设置列表拖动排序基础设施 | 支撑 | 200 | 规则、场景、线路组、binding 排序共用；应独立成文件 |
| 线路列表（原生表格折叠行与 SwiftUI 展开编辑器） | 支撑 | 680 | 大量线路时的性能方案，属必要复杂度；但折叠头与 SwiftUI 头重复实现，且已漂移 |
| 线路编辑表单（AnyConnect/Trojan/SS/VMess/AnyTLS 字段与 sing-box 高级选项） | 核心 | 620 | Line 编辑是配置窗口的主体 |
| Tailscale 线路登录/注销/状态与出口节点 | 核心 | 340 | 产品能力必要，但编排写在视图里（iOS 放在 AppState） |
| 运行态资源徽标 | 支撑 | 140 | DESIGN §5.2 中“运行或活动状态”；与 Popover 的任务状态映射重复 |
| 规则列表与编辑 | 核心 | 640 | DESIGN §5.3/§5.6 |
| 场景列表与编辑 | 核心 | 760 | DESIGN §5.5；Scenario 是唯一绑定点 |
| 场景图标目录与选择器 | 核心 | 440 | DESIGN §5.4 明确要求 |
| 线路组编辑 | 核心 | 580 | DESIGN §5.2 与“Next 线路组与延迟”一节 |
| 出口选择器 | 核心 | 86 | 场景 binding、默认出口、规则获取线路共用；其中 sub: 分支是遗留 |
| 延迟展示与测速按钮 | 核心 | 105 | DESIGN 线路组与延迟一节要求统一延迟组件 |
| Profile 选择与管理 | 核心 | 490 | DESIGN §5.1；但视图内含领域操作与 Go 常量 |
| 通用设置页 | 核心 | 392 | DESIGN §5.1 |
| 安装/卸载窗口 | 核心 | 648 | DESIGN §6/§6.1；卸载事务状态放在视图 @State 里 |
| 更新窗口 | 核心 | 286 | DESIGN §6.2；恢复场景意图在视图中计算 |
| 菜单栏拨号盘状态图标 | 核心 | 303 | DESIGN §3.1 状态表 |
| App/Dock/移动端图标绘制 | 支撑 | 195 | 生成器依赖；但运行时 applyDockState(connected:) 是载体出现前的遗留 |
| 调色板（语义层与原始 hex 层） | 支撑 | 234 | 两者是分层关系而非重复（Makefile:54/87/109 把 XDialBrandPalette 单独喂给 swiftc）；仅有少量未用常量 |
| 本地化与外观控制 | 支撑 | 185 | 中英支持是 DESIGN §3 要求，但两套机制并存且覆盖不全 |
| 通用小组件 | 支撑 | 290 | 三类配置卡片共用 |
| 设置窗口 Dock 载体 | 核心 | 85 | DESIGN §2 明确要求；实现精简（85 行） |
| 离线布局检查与设置截图（DEBUG） | 支撑 | 205 | 由事故驱动的 Debug-only 验收工具，不进发布产物；有效性存疑 |
| 企业 RuleSet 预设示例 | 支撑 | 49 | RuleSetPresetCatalogTests 读取该示例；构建脚本支持私有注入 |
| Profile 内 Subscription 出口目标（sub:） | 死代码 | 45 | schema v3 的 validateReferences 禁止 subscriptionID，snapshot 也不填 subscriptions，这些分支不可达 |
| 设置选页通知 xdialSettingsSelectTab | 死代码 | 7 | 投递方已在 ec2f29d 删除，仓库内 0 个 post |
| 图标设计草稿 | 历史可删 | 1060 | 不在任何 target，仓库内无引用；rotary-dial 已被 RotaryDial.swift（6 孔）取代，草稿是 10 孔 |
| Next 界面重设计草案 | 历史可删 | 202 | 无引用；唯一采纳的“独立通用窗口”已被 DESIGN §5.1“不创建另一扇通用窗口”推翻，其余“暂不实施” |
| 产品设计文档 | 核心 | 379 | UI 的契约来源；但有过期段落与内部重复（见问题） |

### macOS Transparent Proxy 扩展

审计范围约 10.3k 行：扩展 8.6k 行，Shared 中相关文件 1.7k 行，另有约 5.5k 行相关测试。TransparentProxyProvider、EmbeddedSingBoxRuntime、UDPFlowSOCKSRelay 三个文件共 7.2k 行，都不在 XDialTests 的 sources 里（macos/project.yml:400-450），只能通过抽到 Shared 的纯函数间接测试。  核心能力基本都对应 ARCHITECTURE §3.1 / §5，复杂度大体相称：flow 接入、relay 换代排空、冷启动与 Switch 事务、回滚、本机 SOCKS5、MagicDNS 捕获名。UDP relay 的 978 行里，约 170 行是从 TCP relay 复制来的 SOCKS 客户端代码；剩下的跨 generation 重关联是 d35 证据和 §5.3 要求的必要复杂度，不算屎山。  Provider 没有读域名做裁决，也没有做第二次 DNS 裁决：它只透传 remoteHostname、绑定接口，以及 Go 下发的捕获名。越界点在别处：它在 Swift 里做应用规则的 first-match，并为一个只有 DEBUG 读取的账本持有 Line / RuleSet / Subscription ID。  屎山集中在 EmbeddedSingBoxRuntime，有三类问题： - 就绪编排在 Swift 和 Go 各写一份：地址族二次收敛编译、Tailscale DERP 诊断、AnyConnect 等待。 - 在 Swift 里复制 Go 的 tag 和身份格式。 - 两处用固定外部端点当门槛或地址族裁决依据，与 §4.3 冲突：Cloudflare / Google 的 IPv6 TLS，以及 Cloudflare trace。  Provider 的诊断代码约占 18%（约 550 行），Switch 事务约占 41%。保守估计可删或可合并的 Swift 约 2000 行，这个数不含把逻辑迁入 Go 后 Go 侧新增的部分。

| 功能 | 判定 | 约行数 | 说明 |
|---|---|---|---|
| 系统扩展入口与签名身份 | 支撑 | 110 | ARCHITECTURE §6 要求各身份的签名 profile 与 entitlement 独立。5 份文件只在 App Group 和 NE 值上不同，与 project.yml:94-120 的配置一一对应。 |
| 冷启动连接事务（startProxy → Commit） | 核心 | 370 | 直接实现 §5.1 的 planning→preparing→committing→committed 和 §5.2 中 Provider 作为报告权威写入者的要求。 |
| 停止 / 致命错误 / 提交超时 / 回滚 | 核心 | 380 | §5.1 要求逆序、幂等、有界撤销，原始失败与回滚失败分开记录。系统 API 是异步的，所以 in-flight 撤销延后机制是必要的。 |
| 场景切换候选事务（Switch） | 核心 | 1630 | §5.3 要求旧 generation 在候选准备期间继续承载流量、latest-wins、失败只清理候选。行数多主要来自响应构造和超时模式的重复，见 problems。 |
| flow 接入与 relay 代际登记 | 核心 | 620 | §5.3 要求提交时原子切换新 flow 的 relay generation，旧 flow 有界排空；停止后的 tombstone 保证不泄漏到 Underlay。 |
| TCP flow → 回环 SOCKS5 CONNECT relay | 核心 | 573 | §3.1 规定 macOS 入口以随机凭据保护的回环 SOCKS 把 flow 交给 sing-box。 |
| UDP flow → SOCKS UDP ASSOCIATE relay（跨代重关联） | 核心 | 1410 | d35 §7 与 RelayReassociationPolicy 的注释都说明：macOS 不会为同一个 socket 再造 flow，关流会让 mDNSResponder 永久黑洞。978 行中约 170 行与 TCP 重复，其余与语义相称。 |
| Relay 并发原语与关流错误规范化 | 支撑 | 325 | 放在 Shared 是为了能进 XDialTests（扩展文件不在测试目标里），拆分大体合理。只有少量过度抽象，见 problems。 |
| flow metadata 编码（绑定接口 / 原始域名） | 核心 | 170 | §3.1 和 d35 §1 要求已绑定 flow 的接口经认证、有长度上限的 metadata 交给 sing-box，只由 Direct 恢复；§4.3 要求 connect-by-name UDP 保留域名。 |
| 应用规则进程归属与凭据选择 | 核心 | 290 | §4.1 写明 Application binding 的 auth_user 归属贯穿 DNS 与 route。进程路径无法穿过 SOCKS 交给 sing-box，所以 Provider 侧匹配是现实方案。但它在平台层做了规则匹配，属于边界灰区，见 problems。 |
| 应用归属诊断账本 | 存疑 | 160 | 唯一消费方 DebugServer 整体在 #if DEBUG 内（DebugServer.swift:1），宿主侧方法也在 #if DEBUG 内（TransparentProxyManager.swift:763-858）。Provider 在 Release 下照样逐流加锁记录，实际是只写不读。 |
| 系统网络设置构造（DNS 捕获与接口作用域排除） | 核心 | 200 | 直接对应 §3.1 的排除集合、§3.2 的 MagicDNS 捕获契约和 d35 §1 / §3。 |
| 本机 SOCKS5 入口 | 核心 | 375 | §3.1 入口表和 DESIGN 215-223 的产品能力；端口不随 Switch 重建，所以必须由 Provider 持有。 |
| 连接事务报告写入 | 核心 | 449 | §5.2 规定 Provider 是运行报告的权威写入者，journal 写不了就不能 Commit。 |
| Go 会话信封生成、解码与校验 | 支撑 | 300 | 解码是必需的，但其中复刻了 Go 的 tag 和身份格式校验，见 problems。 |
| 线路地址族就绪与约束二次编译 | 存疑 | 480 | Go 的 lineNetworkGeneration 已缓存每个 tag 的 proof、合并并发探测、计算每条 Line 的 IPv4 / IPv6，Ensure* 还会自己再遍历一次。Swift 层是重复编排，而且 start 和 prepareSwitch 各复制一份。 |
| Tailscale 就绪等待与 DERP 诊断 | 存疑 | 730 | 这是 Tailscale 协议层知识，按 §1 应归协议适配器（Go）。iOS / tvOS 没有对应逻辑。git log 显示它反复靠事故补丁叠加（a5f761f、6b21331、6ab2759）。 |
| MagicDNS 捕获名准备 | 核心 | 170 | §3.2 的 macOS MagicDNS 快照契约，平台只取得有界捕获名。 |
| AnyConnect 恢复等待与运行事件 | 支撑 | 230 | 事件映射是必要的。但 active generation 的握手等待和 Go 就绪路径里的 anyConnect.ensureTransport 重叠（anyconnect_recovery_owner.go:65）。 |
| Direct IPv6 TLS 探测 | 存疑 | 185 | 与 §4.3 冲突：Direct 就绪不依赖固定外部 TLS，单点失败不能判定整个地址族不可用。Go 侧把这个参数命名为 legacyDirectIPv6Available。 |
| RuleSet 冷获取与后台刷新会话 | 支撑 | 290 | §7 的获取会话语义。编排放在 Swift 尚可接受，但单例冲突判断复刻了 Go 已掌握的信息，Direct 预检还依赖 Cloudflare trace，见 problems。 |
| 订阅就绪验证 | 支撑 | 65 | §4.3 允许“其他 Line 的实际服务依赖经该 Line 的精确出口验证”。 |
| Provider 诊断 IPC | 支撑 | 530 | §5.2 的事务限定诊断，Popover 的测速和出口 IP 依赖它。但 Provider 中约 550 行诊断代码有大量样板重复。 |
| Provider 流量账本 | 存疑 | 100 | 速率是 DESIGN 的产品面。但 Go 的 trafficCounter 已挂在每个 Box 的 Router 上（libbox.go:1343、1974），iOS 直接用 TrafficTotals；macOS 是两套计数并存，只用了 Swift 那套。 |
| Tailscale 登录控制 IPC | 核心 | 50 | §3.2 规定已提交的 Provider 通过带事务 ID 的独立控制 IPC 提供状态与登录续期。 |
| DEBUG 故障注入 | 支撑 | 60 | 在 DEBUG 内且有调用方（TransparentProxyManager.swift:619-632）。但它内联在 startProxy 里，增加了阅读负担。 |
| 网络 epoch 选择与 network context | 支撑 | 60 | §5.4 的 epoch 语义要求同一 Underlay 复用 epoch。 |
| 引擎回调与运行门 | 核心 | 223 | §5.1 规定接管中的数据面失败必须进入回滚。 |
| Home DERP 重选判定 | 死代码 | 55 | 生产代码零调用。对应的 Go 方法 ReselectTailscaleHomeDERP 也只有 Go 测试调用。 |

### iOS / tvOS

移动端实际可用的只有 iOS：App 和 Packet Tunnel 扩展在进程内运行 Libbox。tvOS 真机构建注入的是 NoopTunnelEngine，且没有 tunnelManager，canConnect 恒为 false，所以 tvOS 只是 Simulator 演示，iOS 和 tvOS 都不在 CI 里构建。共享的 AppState（2808 行）和 TunnelManager（2303 行）几乎没有 #if os 分叉（全仓约 8 处、不到 50 行，主要是 bundle id），内容基本都是 iOS 的需求；tvOS 的 UI 只用到 AppState 约 12 个成员，GoEngine 和 TunnelManager 在 tvOS 构建里从未被实例化。以下核心部分的复杂度与功能匹配，属于必要：NE 隧道的启动/停止生命周期、带 revision 配对的 Keychain 持久化、Tailscale 限时设置会话、系统按需重连、快捷指令和控制中心。屎山集中在三处：(1) Swift 复制 Go 的配置校验、outbound tag、Tailscale 端点语义和配置指纹，而且已经和 Go 现状不一致；(2) 数据链路验收约 1300 行，依赖 1.0.0.1/1.1.1.1 固定公网探针，向每个场景强行写入锁定规则，验收失败即断开，与 ARCHITECTURE §4.3 冲突；(3) 从 macOS 拷来的旧格式迁移，处理的是移动端从未写过的格式，却漏掉了移动端真实写过的 modes→scenarios。移动端整体还停在 macOS 上一代的模型：没有 Profile Next、线路组、AnyTLS、ConnectionPlan/ConnectionReport 和候选 Switch，已连接时切换场景必须先断开。

| 功能 | 判定 | 约行数 | 说明 |
|---|---|---|---|
| Packet Tunnel 启动/停止生命周期（generation、锁、NE 网络设置、tun fd、引擎串行队列） | 核心 | 830 | NE 回调、Go 回调和停止请求并发到达，sslcon 又是进程级单例，锁和 generation 的复杂度与需求相符。缺点：AnyConnect 路径把同一份 settings 应用了两次（见 problems） |
| Provider 的 Underlay 接口发布 | 核心 | 95 | Go 的 auto_detect_interface 依赖它。048b878 已去掉按名称前缀筛选，但 selectDefaultInterface 仍然取 availableInterfaces.first |
| Provider ⇄ App 的 JSON 命令通道 | 支撑 | 320 | 运行时选线、测速、Tailscale 登录和流量统计都靠它；协议是字符串化的临时 JSON，App 侧有 GoEngine 和 TunnelManager 两个客户端 |
| 启动包解析（一次性 start options / 按需重连安全信封 / 清理旧 App Group 明文） | 支撑 | 250 | 按需冷启动没有 options，必须有安全信封。清理旧 App Group 在 App 和 Provider 各写了一份 |
| Provider 诊断快照与脱敏 | 支撑 | 275 | Provider 异常退出后仍能读到诊断。脱敏逻辑与 App 侧 MobileDiagnosticsService 重复 |
| NETunnelProviderManager 管理（加载、保存、启动、停止、移除描述文件） | 核心 | 820 | iOS 唯一的系统接入路径 |
| 系统级按需重连（On-Demand） | 支撑 | 330 | iOS 专属能力，App 不在前台时由系统恢复连接；目前和数据链路验收耦合 |
| 数据链路验收（锁定的 1.0.0.1/1.1.1.1 规则 + 公网探针 + 路由命中计数，失败即断开） | 存疑 | 1300 | 违背 ARCHITECTURE §4.3（就绪证明不依赖固定外部服务，单点失败不升级为整个场景的门槛）和 §2（隐式注入）。Go 侧已有 EnsureActiveLinesReady，移动端没有使用 |
| Tailscale 待登录（action-required）就绪轮询 | 支撑 | 250 | tsnet 首次登录必须保持 provider 存活；但端点集合用 Swift 自己拼的 tag，并假设所有已启用线路都会生成端点（已过期） |
| Tailscale 限时设置会话（主 App 内无 TUN 的 Libbox） | 核心 | 920 | 对应 ARCHITECTURE §2/§3.2 的限时 setup session，配置由 Go 生成。问题：接口选择仍然按 utun/ipsec/ppp 前缀过滤 |
| GoEngine（App→Provider 传输 + 订阅解析 + 运行时选线/测速） | 支撑 | 514 | 约 1/4 是从 macOS socket 协议照搬的残留（事件分发、start/stop），从不被触发 |
| AppState 连接状态机与前台自动重连 | 核心 | 280 | 状态完全是字符串（"connected" 等约 106 处字面量），但逻辑本身必要 |
| Swift 侧连接前配置校验 | 存疑 | 440 | Go 生成器已拒绝悬空引用和多 AnyConnect/Tailscale，禁用对象会产生 warning；macOS 只保留 87 行 AnyConnect 字段检查。这里的注释还以“生成器会回落 direct”为前提，与 Go 现状不符 |
| 配置持久化（UserDefaults 信封 + Keychain vault，revision 配对，fail-closed） | 核心 | 700 | 必要的凭据保护。但敏感字段清单在多处各写一份 |
| 旧格式迁移（扁平 vault key、旧 vault 文件、比喻命名 key、v0.2 exits/rules/strategies、逐条 Keychain） | 历史可删 | 500 | 比喻命名、v0.2 和逐条 Keychain 从未在任何移动端版本里写过（照搬自 macOS）；只有 2026-07-19 至 07-23 的 iOS 早期构建写过扁平 vault，那部分算“历史必要”，前提是还有这样的设备。真实存在过的 modes/active_mode_id 反而没有迁移 |
| 订阅管理 | 核心 | 770 | 移动端唯一的“线路组”形态（macOS 已改为线路组 Line） |
| 场景模板与场景管理 | 支撑 | 150 | 活动场景的切换在 5 处 UI/Intent 代码里直接改 app.profile.activeScenarioID，没有统一入口；已连接时完全禁止切换 |
| 移动端领域模型（Models.swift） | 支撑 | 647 | 是 macOS Models（1165 行，含线路组/AnyTLS/应用规则/fetch_line_id）分叉出来的旧版本，跨语言 schema 有第三份拷贝 |
| iOS 界面（首页 / 配置 / 设置） | 核心 | 3230 | iOS 产品表面；UI 层直接修改 app.profile 并调用 save()，绕过 AppState API 的地方很多 |
| 移动端专属导入/导出格式（xdial-mobile-configuration v1） | 存疑 | 376 | Go 已有 ImportProfile/ExportProfile/ValidateProfileDocument（profile_document.go），macOS 用的就是它，移动端零调用；校验常量与 AppState 重复 |
| 诊断报告 | 支撑 | 90 | 必要的用户诊断出口；脱敏实现与 Provider 重复 |
| 快捷指令 / 控制中心 / 小组件快照 | 支撑 | 450 | iOS 专属新能力（2026-10-11），复用 AppState 现有事务；切换场景在已连接时直接报错 |
| 实时流量速率 | 支撑 | 100 | 首页展示需要 |
| tvOS App（Connection/ScenarioPicker/Credentials/Settings/Root） | 存疑 | 590 | 真机上是 AppState()+Noop，无法连接；版本号写死 0.4.1 (tvOS)；“配置优先从 Mac 端同步”的功能并不存在 |
| DebugSmokeTest（tvOS Phase 0 手测桩） | 历史可删 | 80 | 绕过 Go 配置生成的 Phase 0 原型；文件本身没有包 #if DEBUG，Release 也会编译进去 |
| FakeTunnel（Simulator 演示隧道与 UI 测试夹具） | 支撑 | 594 | 只在 Simulator 编译，真机和发布产物不包含，是测试/演示脚手架；但 UI 测试的启动参数开关和演示凭据写入逻辑放在 App target 里 |
| NoopTunnelEngine 与 TunnelEngine/TunnelManaging 的默认实现 | 支撑 | 90 | 只服务于 tvOS 真机（因此是不可用状态）、AppState 的默认参数和测试替身 |
| 移动端测试 | 支撑 | 4863 | 状态机、持久化和按需重连的测试有价值；部分在测死代码、旧迁移和过期语义 |
| 构建配置 | 支撑 | 270 | iOS 发布需要；tvOS 目标只编 Simulator；两者都不在 .github/workflows 里 |

### 横切：跨平台重复与改动热点

iOS 与 tvOS 已经共用 appletv/ 下的同一份 Swift（ios/project.yml 直接引用 ../appletv/XDialTV/*.swift），所以真正的重复发生在 macOS 和移动端之间。这种重复不是复制粘贴：AppState、TunnelManager、Provider 两两之间的文本相似度只有 1–15%。实际情况是移动端停在 8 月以前的上一代架构，用 Swift 自己实现了一套 Go 的 Profile 校验、依赖闭包、outbound tag 生成、运行指纹、导入导出格式，还有依赖固定 IP 的连接验收。这条路径绕开了 macOS 已经在用的 ConnectionPlan/Report，CI 也从不编译移动端。两份 Swift 领域模型有 67% 重叠，而且已经漂移：移动端解码时会静默丢掉 anytls/udp/tfo/group/native 字段。macOS 在切换到 Next 配置库（ec2f29d/76e746c）之后，留下约 500 行没有任何调用方的代码。Libbox 导出面靠 With… 后缀变体不断叠加，十余个变体现在只有测试在调用，Makefile 的源码 grep 门禁还把变体名写死了。改动热点集中在 macOS 宿主三件套和安装事务。补丁叠补丁最明显的有三处：EmbeddedSingBoxRuntime 的 start()/prepareSwitch() 是两份近似实现，被成对修改了 7 次；失败的重试分类在 Swift 端靠白名单和文本转译完成，与酒店事故同类的问题仍留在 LineLatencyStore；Tailscale 的 DERP 恢复决策写在了 Swift Provider 里。整体来看，macOS 核心事务的复杂度与功能相匹配，屎山主要集中在跨层边界和移动端分叉上。

| 功能 | 判定 | 约行数 | 说明 |
|---|---|---|---|
| Go 核心作为唯一的配置编译/校验/计划源（Libbox 导出面） | 核心 | 9500 | ARCHITECTURE §1 规定 Go 拥有 Profile 校验、计划编译与指纹；§5.2 规定 Swift 只比较指纹。macOS 宿主已全部走这条路径（macos/ 中有 LibboxGenerateConnectionPlan、LibboxValidateProfileDocument 等 15 个以上调用点） |
| macOS Swift 领域模型镜像（Codable） | 支撑 | 1165 | UI 需要类型化编辑，镜像本身合理；但它是 Go schema 的手写副本，靠 tools/profile-document-check.swift 单点校验（Makefile:442-444），只覆盖 macOS 这一份 |
| iOS/tvOS Swift 领域模型镜像 | 支撑 | 647 | 移动端编辑同样需要模型；但它与 macOS 版重复 67%（tv 486 行有效行中 330 行出现在 mac 版），且字段已漂移，应合并为一份共享 Swift 包 |
| macOS 连接事务、Switch、Line 租约的宿主与 Provider 实现 | 核心 | 11900 | 直接实现 ARCHITECTURE §3.1、§5.1–5.4 的事务、Switch 与恢复契约，是发布产物中的主数据面 |
| 移动端 Packet Tunnel 数据面 | 支撑 | 3400 | ARCHITECTURE §3.1 写明 iOS/tvOS 用 Packet Tunnel，这是平台差异导致的合理分叉；但它没有 ConnectionPlan/ConnectionReport/Switch，是上一代事务模型 |
| 移动端 Swift 侧配置校验、依赖闭包、tag 与运行指纹 | 存疑 | 1000 | 违反 ARCHITECTURE §1（Swift 不复制 Go 的 tag、schema、依赖闭包、指纹）与 §5.2（configDirty 只比较 Go 指纹）；Go 已经有对应实现 |
| 移动端连接验收（固定 IP 探针 + 注入验收 RuleSet） | 存疑 | 1300 | 与 ARCHITECTURE §4.3 冲突（Direct 就绪不依赖固定外部 DNS/TLS/出口展示服务；固定 IP 或单目标失败不足以判定网络不可用），也与 macOS 用 Go line_network_readiness 的做法分叉 |
| 移动端安全持久化（vault 信封、逐项 Keychain 旧数据迁移） | 支撑 | 1050 | 移动端真实存在过逐项 Keychain 存储，迁移与凭据分离有数据依赖；与 macOS 的 profiles.enc 配置库是两套独立设计（ARCHITECTURE §6 的共享配置库只覆盖 macOS 各通道） |
| 移动端比喻命名与 v0.2 配置迁移 | 历史可删 | 120 | 这两种格式只在 v0.5.0 之前的 macOS 上存在过。tvOS 首个提交 a12b44e 写入的就是 lines/rule_sets 正式键，iOS 在 b3b7418（2026-07-19）才加入，移动端存储里不可能出现这两种格式；这段代码是移植时从 macOS 拷过来的 |
| 移动端配置文件导入导出格式 | 存疑 | 470 | macOS 用 Go 的 LibboxImportProfile/ExportProfile/ValidateProfileDocument（core/libbox/profile_document.go，build tag 是 !windows，可以编进 iOS）。两端格式不互通，校验也重复 |
| 移动端进程内 Tailscale setup 运行时 | 存疑 | 595 | 职责与 Go 的 core/tailscalesetup/manager_gvisor.go（Prepare/Status/BeginLogin/Logout/Stop/idle）重合，区别只在 macOS 经 daemon、iOS 在进程内 |
| tvOS 专属 UI 与 DebugSmokeTest | 存疑 | 590 | tvOS 只有 `make appletv` 以 CODE_SIGNING_ALLOWED=NO 构建模拟器版（Makefile:510-517），CI 不编译（.github/workflows/ci.yml 中无 ios/appletv），没有发布路径；appletv/project.yml:17-19 注释记录过 tvOS 构建断裂 |
| macOS 旧 vault 存储（KeychainStore / ProfileVaultProjection） | 死代码 | 337 | 76e746c（2026-09-18）删掉了最后的 importSandboxVaultIfNeeded/deleteVault 调用，ec2f29d 删掉了 ProfileVaultProjection 的生产调用。旧数据的读取与删除已改由 ExistingXDialProfileReader、ConfigurationDataDeletion 自行处理 |
| macOS 旧订阅解析链 | 死代码 | 130 | ec2f29d 删掉了 SettingsView 中两处 state.engine.parseSubscription 调用；Next 改用 LibboxImportProfile。daemon 的 parse-sub 在 App 里没有发送方 |
| macOS 比喻命名迁移函数、场景模板、EngineStatus | 死代码 | 130 | 都是 private static 或模块内符号，在 macos/、Tests 中都搜不到调用；迁移函数的调用方在 ec2f29d 被删 |
| Libbox 导出 API 的 With… 后缀变体 | 历史可删 | 450 | Swift 只用其中 1–2 个变体，其余没有调用方或只剩测试调用，详见 problems |
| Tailscale HomeDERP 重选 | 死代码 | 1300 | ARCHITECTURE §3.2 把它称为“显式维护能力”，但 Swift、cmd、DebugServer 中都没有调用入口；Swift 判定函数从 a5f761f 引入起就只被测试调用 |
| Swift 侧 Tailscale 就绪等待与 DERP 恢复判定 | 存疑 | 950 | ARCHITECTURE §5.4 规定由 Line 自己处理协议恢复，§1 规定 Swift 宿主只负责生命周期与结构化展示；这些协议内部恢复决策应留在 Go 的 Tailscale runtime |
| 失败重试分类与错误码转译 | 支撑 | 300 | 自动切换与重连预算依赖分类（ARCHITECTURE §5.4），功能必要；但分类在多层间转译，见 problems |
| 自动恢复、网络 epoch 与唤醒重连 | 核心 | 2600 | ARCHITECTURE §5.4 明确规定了这两种预算和 epoch 语义；问题在于所有权分散，不在于功能多余 |
| 安装与 helper 注册事务 | 核心 | 3300 | ARCHITECTURE §6 的安装事务；3 份事故记录都落在这里，有平台不确定性，复杂度大体有依据 |
| 旧原生 TUN 数据面与其 e2e 测试 | 存疑 | 2700 | ARCHITECTURE §9 声明它保留在 helper/CLI 与恢复路径；App 自 a5f761f（2026-07-30）起不再发送 start，GoEngine.handleEvent 显式忽略 status/error 事件；e2e_test.py 没有接入 Makefile/CI |
| Makefile test-macos-transaction 源码 grep 门禁 | 存疑 | 45 | 其中一部分表达架构不变量，但它们检查的是文本而非行为，还会把 Libbox 变体名、函数名、出现次数写死，阻碍合并重构 |
| 跨平台小型共享件 | 支撑 | 60 | 各约 10–20 行，靠复制共享；可以随共享 Swift 包一并合并，单独处理收益小 |

## 附录 B　全部问题（含复核结论）

「复核修正」的条目以修正后的结论为准；「未复核」的条目只代表单个审计员的判断。

### Go 配置编译

**P001　订阅 × Transparent Proxy 整条链路在 macOS 上不可达**　〔dead｜复核成立｜可删约 450 行〕

- 结论：macOS 在所有入口拒绝或丢弃嵌套订阅，送给 TP 和 BuildConnectionPlan 的 Profile 里 Subscriptions、DefaultSubscriptionID、binding.SubscriptionID 都恒为空；iOS/tvOS 不走 TP，也不构建 ConnectionPlan。所以 TP 下的订阅路由、DNS、计划任务、指纹投影和 SubscriptionOutbounds 在所有发布产物中都执行不到。实际残留比审计员列的更多，Swift 侧还有一批订阅任务管道（见 new_findings）。
- 位置：core/config/generator.go:629-634；core/config/generator.go:1508-1535；core/config/generator.go:2818-2844；core/config/connection_plan.go:179-206；core/config/connection_plan.go:291-337；core/config/runtime_fingerprint.go:86-92；core/config/runtime_fingerprint.go:124-131；core/config/runtime_fingerprint.go:226-255；core/config/runtime_fingerprint.go:320-330；core/libbox/configgen.go:142-146；core/libbox/configgen.go:723-726；core/libbox/configgen.go:1048-1110；core/libbox/configgen_test.go:1357-1561；core/config/transparent_proxy_dns_test.go:296-352；core/config/transparent_proxy_line_capabilities_test.go:467-513；core/config/connection_plan_test.go:132-174；core/config/connection_plan_test.go:223-300
- 建议：TP 入口（GenerateSingBoxTransparentProxy* 或 BuildConnectionPlan）遇到 Subscriptions、SubscriptionID 或 DefaultSubscriptionID 时显式报错（fail-closed）。然后删除 TP 下的订阅规则和 DNS、计划中的订阅任务、指纹中的订阅投影、SubscriptionOutbounds 字段，以及 Swift 的对应校验和这些测试。NE 下的订阅编译保留。
- 注意：1) 必须先加 fail-closed，否则共享段 generator.go:502 仍会给 TP 生成订阅 outbound，但没有规则，结果是静默的半配置。2) Swift 的 EmbeddedSingBoxRuntime 用非可选类型 `[String:[String]]` 解码 subscription_outbounds（:117/:128），必须在同一 PR 修改。3) connection_plan_test.go:132-174 同时覆盖 Tailscale 动态任务，只能改写，不能整段删除。4) invariants_test.go 里的订阅不变量走 GenerateSingBoxDesktop，不属于 TP，这次不要动。5) inspectScenarioReferences 和 collectEffectiveSubscriptionGeoIPRules 仍被 NE 使用。6) 可删行数约为：Go 生产代码约 265 行，Swift 约 25 行，测试约 390 行，扣除需要改写的部分，保守取 450。

**P002　一次性迁移函数及其 libbox 桥自 54585fe 起无产品调用方，Compact 和 Separate 互为逆操作**　〔dead｜复核修正｜可删约 330 行〕

- 结论：这 4 个迁移自 f065750（2026-09-15）引入以来，唯一的产品调用方就是 #if DEBUG 下的 DebugServer action，54585fe（2026-09-23）把这些调用删掉了；之后 config.CompactProfileRuleSets、SeparateImportedRuleResources、ReimportScenario 和 4 个 libbox 导出都没有产品调用方。但 LibboxCompactProfileRuleSets 并没有被 tools/profile-document-check.swift 使用，它连工具调用方都没有。测试依赖也比审计员列出的多。
- 位置：core/config/rule_set_group.go:194-253；core/config/imported_rule_resources.go:57-102；core/config/imported_policy_selectors.go:150-222；core/libbox/profile_document.go:166-183；core/libbox/profile_document.go:206-290；core/config/imported_rule_resources_test.go:63-117；core/config/imported_policy_selectors_test.go:119-146；core/libbox/profile_document_test.go:89-147；macos/Sources/XDial/ProfileDocumentService.swift:5-66；tools/profile-document-check.swift
- 建议：删除 config.CompactProfileRuleSets、SeparateImportedRuleResources、ReimportScenario 和 4 个 libbox 导出，以及 Swift 包装函数和相关测试。profile-document-check 改为只验证 Import/Export/Clone 往返。MatchingRuleName 和 GroupProfileRulesByDestination 保留。
- 注意：1) 审计员写的风险“仍有未迁移的旧库依赖 Separate”不成立：这些迁移从未出现在 Release 或 NextRelease 中（NextRelease 不定义 DEBUG），正式用户的库从没跑过 Compact，也就不存在要靠 Separate 撤销的 policy 包装组。2) 依赖 Compact 构造分组的 12 处测试夹具要改成手写分组，否则 rule_set_group 和 subscription_profile 的测试无法编译。3) profile_document_test.go:89 需要把 RuleSet bootstrap 的覆盖拆出来保留。4) ReimportScenario 用到的 expandGroupLineIDs 和 NormalizeImportedPolicySelectors 仍有其他调用方，必须保留。5) 330 行不含 Swift 包装的 54 行，那部分已计入 P081。

**P003　旧桌面原生 TUN 生成分支只剩 CLI 能触达，却占据生成器约 280 行和大部分测试**　〔legacy｜复核修正｜可删约 400 行〕

- 结论：desktop 生成入口 GenerateSingBoxDesktop 在生产代码中只有 core/engine/singbox.go:62 一个调用方，因此只能经 daemon 的 start 或 CLI start 到达。GenerateSingBox 及其硬编码的 en0 只有测试使用。这些都成立。但「PlatformMacOS 的唯一生产调用链」这一说法有误：PlatformMacOS 还在 4 处非桌面的生产代码里，作为「非 NE」标志传给 buildSubscriptionOutbounds，而且它是枚举的零值。所列的 1054-1260 区间里，desktopProxyDNSTag 也被 TP 路径共用。可删的只是 platform==PlatformMacOS 的那些分支和桌面专属的 helper，不能直接删掉这个常量。
- 位置：core/config/generator.go:27-33；core/config/generator.go:110-124；core/config/generator.go:437-455；core/config/generator.go:525-543；core/config/generator.go:696-700；core/config/generator.go:738-745；core/config/generator.go:1004-1021；core/config/generator.go:1045-1051；core/config/generator.go:1054-1260；core/config/generator.go:1662-1677；core/config/generator_test.go:1401-1632
- 建议：先请作者确认旧 TUN 数据面是否仍要维护（见 questions）。如果退役：删除 PlatformMacOS 分支、GenerateSingBox/GenerateSingBoxDesktop、engine 的 Start 路径和桌面 DNS 测试，把 smoke/integration 改用 TP 或 NE 配置跑 sing-box check。如果保留：至少把它从 generator 主函数里拆成独立文件。
- 注意：(a) 不能删除 PlatformMacOS 枚举值或改变它的零值，否则 PlatformNE 会变成 0，所有零值的 Platform 都会悄悄变成 NE。应先把那 4 处调用改成显式的「非 NE」参数。(b) desktopProxyDNSTag 要保留，或改名成 TP 专用。(c) smoke_test 和 generator_integration_test 是唯一真正跑 sing-box check/数据面的测试，必须先迁移到 TP 配置再删除，所以测试部分的净删除量远小于它们当前的行数。(d) CLI 的 start 随 App 包以 xdial-daemon 形式分发（project.yml:376），删除前需要作者确认这条手工入口可以退役。

**P004　架构不变量测试主要守护不发布的桌面路径，同一不变量在 2–3 个文件重复**　〔test-bloat｜复核修正｜可删约 100 行〕

- 结论：invariants_test.go 中 INV1、1c、1d、2、3、4_NoHiddenRouteRules、4b、6a、6b、7、D30 只走桌面入口，这一点属实；INVUnderlay_DesktopRejectsMissingSystemSnapshot 同时调用了桌面和 TP 两个入口。但“主要守护不发布的路径”说得过头。桌面和 TP 共用 generateSingBox，单例校验（generator.go:417-424）、悬空和禁用引用、Scenario/订阅的排序都在平台分支之前完成，所以从桌面入口测试同样守护了 TP 使用的共享代码。桌面生成器也随投产 helper 一起发布（core/engine/singbox.go:62），只是宿主不调用。真正的缺口是依赖平台分支的 DNS 和路由不变量（INV2、3、4、7）在 TP 上没有通用断言，不过 transparent_proxy_dns_test.go 有 14 个针对 TP 的 DNS 用例部分覆盖。重复方面：两个单例测试确实重复。“悬空引用测了 3 次”不准确：generator_integration_test:526 测的是订阅内 Clash 组成员悬空时跳过死组，与 INV6a 的拒绝悬空引用是不同的行为。禁用引用三处重叠属实。smoke:896 在 validator 层面测试，层级不同。
- 位置：core/config/invariants_test.go:132-150；core/config/invariants_test.go:361-1175；core/config/generator_test.go:1262-1292；core/config/generator_test.go:1735-1788；core/config/generator_test.go:1845-2056；core/config/generator_integration_test.go:466-604；core/config/smoke_test.go:896-933
- 建议：把不变量改为对 TP 与 NE 两个发布平台做参数化断言（INV2、INV4、INV7 要补上 TP 版本），删除跨文件重复的单例、悬空、禁用测试，保留一份即可。夹具统一放进一个 testdata/fixtures 构造器。
- 注意：参数化改造时，INV1、1d、6a、6b、D30 这类共享校验保留一份即可，不需要每个平台各测一遍。INV2、3、4、7 必须补上 TP 版本之后才能考虑删除桌面版本。只要 ARCHITECTURE §9 仍保留 helper/CLI 的旧 TUN，就要保留最少一组桌面断言。

**P005　TP 会话生成堆积了 4 个 libbox 导出和 3 个 config 入口，其中 3 个只有测试调用或完全没有调用**　〔over-engineering｜复核成立｜可删约 120 行〕

- 结论：TP 生成入口里有 4 个是测试专用或零调用：libbox 的 GenerateTransparentProxySession 只在测试中出现；GenerateTransparentProxySessionWithCallback 全仓库 0 调用；GenerateTransparentProxyRuleSetBootstrap 只在测试中出现；config.GenerateSingBoxTransparentProxy 只出现在 7 个测试文件里。标题说“3 个”，实际是 4 个。config 的 ...WithCapabilities 注释写的是服务于“older Providers”，这条注释已经过时：它其实是当前 Provider 首轮（未约束）会话的入口（configgen.go:78），也是 RuleSet bootstrap 的入口（:534），所以只能合并，不能删除。
- 位置：core/config/generator.go:170-218；core/config/generator.go:263-291；core/libbox/configgen.go:52-88；core/libbox/configgen.go:244-391；core/libbox/configgen.go:393-417；macos/TransparentProxyExtension/EmbeddedSingBoxRuntime.swift:1181-1226
- 建议：libbox 只保留 GenerateTransparentProxySession(…, directIPv6Available, lineCapabilitiesJSON 可为空, callback) 和 GenerateTransparentProxyRuleSetBootstrap(…, directIPv6Available)。config 只保留 WithLineCapabilities，加一个内部函数 defaultLineCapabilities。测试改用一个测试辅助函数。
- 注意：1) 这是 gomobile 签名变更，EmbeddedSingBoxRuntime 中 3 处 Libbox 调用要在同一 PR 修改，Provider 和 Libbox 同包发布，不存在旧调用方。2) 合并后 lineCapabilitiesJSON 为空时，必须保持 legacy 默认语义，并继续拒绝 Direct 冲突（decodeTransparentProxyLineCapabilities:113-118）；validateConstrainedEnvelope 对两轮信封一致性的检查不能变。3) invariants_test.go（CLAUDE.md 列出的架构不变量文件）有 5 处调用 GenerateSingBoxTransparentProxy，需要引入测试辅助函数；测试侧大多是改写，净删除行数有限。4) 120 行只算生产代码。

**P006　lineRuntimeIdentity 手写每种协议的字段表，与 outbound 构建和指纹各维护一份**　〔duplication｜未复核｜可删约 80 行〕

- 结论：【看到的】libbox 的 lineRuntimeIdentity 为 trojan、ss、vmess、anytls、vpn、tailscale 各自手写了一个匿名结构体字段表（约 90 行）。而 runtime_fingerprint.includeLine 对代理类 Line 直接复用 buildProxyOutbound(line)（runtime_fingerprint.go:210）。【推论】以后给某个协议新增字段（例如 AnyTLS 新参数）时，如果只改了 buildEditableProxyOutbound 而忘了改 identity，身份不变，候选 Switch 就会错误复用旧会话，违反 §5.3“变更身份另行准备”。
- 位置：core/libbox/configgen.go:879-1000；core/config/runtime_fingerprint.go:182-224；core/config/generator.go:2954-3068
- 建议：代理类 Line 的 identity 改为对 buildProxyOutbound(line) 的结果去掉 tag 后取 HMAC（NativeOptions 已经包含在内）。只有 vpn 和 tailscale 保留专用投影。
- 注意：identity 值会整体变化，升级后第一次 Switch 会认为身份不同并重建能力。这只发生在进程内，不持久化，影响可以接受。

**P007　Surge/Clash 语义有两套编译器（Next 导入与旧运行时），REJECT 名单 4 份、组 fixpoint 2 份、规则类型表 3 份**　〔duplication｜复核修正｜可删约 50 行〕

- 结论：重复属实：REJECT 名单有 4 份（generator.go:2283、:2702，libbox/subscription.go:107、:164）；组可用性 fixpoint 有 2 份，语义确有差异；urltest 的 url 和 interval 夹取逻辑写了两次（generator.go:2416-2434、2460-2478）。但支持类型表实际有 4 份，不是 3 份，还要加上 core/subscription/ruleset.go:155。另外 Next 导入的类型表（subscription_profile.go:174-221）按设计就和旧运行时语义不同（拒绝 REJECT，支持 PROCESS-NAME、IP-ASN、USER-AGENT），不能简单合成一份。iOS/tvOS 确实仍依赖旧 Subscription 运行时编译，所以长期方案的前提是先完成移动端迁移。
- 位置：core/config/generator.go:2280-2498；core/config/generator.go:2684-2816；core/config/subscription_geoip.go；core/libbox/subscription.go:58-175；core/config/subscription_profile.go:160-223
- 建议：短期：把 REJECT 名单、组可用性 fixpoint 和支持类型表收敛成 config 包的导出函数，libbox 改为调用它们（约 60 行）。长期：iOS/tvOS 改走 LibboxImportProfile 生成 Line、组和 RuleSet，然后删除旧运行时编译器（generator.go 2280-2877 约 570 行、subscription_geoip.go 177 行、libbox/subscription.go 约 150 行、validate 的订阅分支，以及约 1500 行测试）。
- 注意：1) 把 fixpoint 统一成 generator 的语义，会让 libbox 导入在某些情况下从拒绝变为接受：规则引用的组只含一个“仅 REJECT”子组时，现在会报“references an unavailable group”。这是行为变化，需要产品确认。2) 类型表只能共享旧运行时内部的两份（libbox 校验表和 generator switch），Next 导入表和 RULE-SET 展开行过滤表（ruleset.go:155）语义不同，不宜合并。3) 长期删除旧编译器需要移动端完成 Profile 数据迁移，并决定 REJECT 规则的去留；还要处理 CLI、Desktop 路径和 invariants_test 中的订阅用例。4) 短期可删约 50 行。

**P008　generator.go 与 configgen.go 内的复制粘贴块**　〔duplication｜未复核｜可删约 120 行〕

- 结论：【看到的】(1) buildScenarioRouteRules 1949-1973 把 bindingOutboundTag 1731-1751 的逻辑原样内联了一遍。(2) BuildSubscriptionRuntimeCatalog 2592-2647 再次调用 buildProxyOutbound，重新推导节点 tag 和组成员，没有复用 buildSubscriptionOutbounds 已算出的映射。(3) activeApplicationRuleSetSelectors 844-862 与 ActiveApplicationSOCKSCredentials 903-924 是同样的 binding 去重循环。(4) buildTransparentProxyDNS 1410-1473 的四个 case 都是 ensureResolver、rule、strategy、invert 的同一个模板。(5) configgen.go 里 AnyConnect 和 Tailscale 描述的构建在 bootstrap（571-615）与 session（731-776）中逐字复制，约 45 行。
- 位置：core/config/generator.go:1731-1751；core/config/generator.go:1949-1973；core/config/generator.go:2592-2647；core/config/generator.go:844-862；core/config/generator.go:903-924；core/config/generator.go:1410-1473；core/libbox/configgen.go:571-615；core/libbox/configgen.go:731-776
- 建议：buildScenarioRouteRules 改为调用 bindingOutboundTag；buildSubscriptionOutbounds 额外返回 nameToTag 和成员表供 catalog 使用；提取 transparentProxyRuntimeDescriptors(profile) 给 bootstrap 和 session 共用；DNS 四个分支提取成一个 matcher→rule 的辅助函数。
- 注意：低。改动前后应对 TP 和 NE 的样例做配置快照比对（invariants 的 normalize 可以复用）。

**P009　活动闭包被各消费者重复推导，一次 TP 会话要展开 6 次、校验 5 次、建计划 2 次；主函数混了 3 个平台**　〔mixed-responsibility｜未复核｜可删约 100 行〕

- 结论：【看到的】一次 generateTransparentProxySession 的执行过程：ParseRuntimeProfile 展开 1 次；BuildConnectionPlan 展开并校验；GenerateSingBoxTransparentProxyWithLineCapabilities 内部的 compileTransparentProxyAddressFamilyPolicy 再 BuildConnectionPlan 一次（generator.go:308）；generateSingBox 又展开并校验；ActiveApplicationSOCKSCredentials 展开并校验；ActiveTailscaleLine 展开并校验。合计 ExpandRuleSetGroups 6 次、inspectScenarioReferences 5 次、BuildConnectionPlan 2 次。Swift 每次连接最多调用两轮，bootstrap 每个 fetch Line 组还要再来一遍。‘binding → 出口 tag 或 Line’的解析在 effectiveActiveTargetIDs、BuildConnectionPlan.resolveTarget、bindingOutboundTag、buildScenarioRouteRules、collectProxyBoundDNSTargets、sbCollectRuleSets、materializeNERuleSets 和 bootstrap 中各写一份。generateSingBox 的 400 行里有 24 处平台分支；TP 平台还会先调用一次 buildScenarioRouteRules，再把结果丢弃（573-592）。【推论】缺少一个‘解析一次的 ResolvedScenario’中间表示，这是 generator 体积大、改动要多处同步的主要原因。
- 位置：core/config/generator.go:293-327；core/config/generator.go:369-769；core/config/generator.go:817-838；core/config/generator.go:879-926；core/config/generator.go:971-997；core/config/connection_plan.go:48-63；core/libbox/configgen.go:642-782
- 建议：在 config 中引入 resolveScenario(profile)，一次性产出：展开后的 profile、校验 warnings、有序 bindings（含 outTag 和 Line）、活动 Line/VPN/Tailscale/MagicDNS 集合，以及 plan。DNS、route、plan、指纹和 libbox 信封都消费这一份结果。拆分建议：generator_tp.go（1300-1582、1686-1934、771-812）、generator_ne.go（1262-1298、1936-2025）、generator_desktop.go（1054-1260，或直接删除）、outbounds.go（2879-3068）、subscription_runtime.go（2280-2877）、application_selectors.go（2027-2132）、rule_set_resources.go（2134-2278）。
- 注意：属于中等规模的重构，必须先有 TP 与 NE 的配置快照测试兜底，否则 DNS/route 顺序容易被悄悄改坏。

**P010　零散死代码与只被测试使用的辅助函数**　〔dead｜未复核｜可删约 140 行〕

- 结论：【看到的】firstString（generator.go:2269-2274）和 Platform.isDesktop（102-104）没有任何调用。GenerateTailscaleHostname、hostnameBase、sanitizeDNSLabel、randomHexSuffix 及两个常量（tailscale.go:12-19、29-90）在全仓库包括测试中都没有调用。WarningUnavailableLine 和 WarningUnavailableSubscription（validate.go:44-49）注释写着‘仅为旧 JSON 兼容’，但从未产生，Swift 也不识别。只被测试使用的有：CollectProfileWarnings（validate.go:67-95，生产中 warnings 走 ConnectionPlan.Warnings）、Profile.VPNLine（model.go:318）、GenerateSingBox（generator.go:110-114，硬编码 en0）、materializeNERuleSetsWithEvents（configgen.go:1276-1284）。另外 mobileTailscaleDNSTag 只是 TailscaleMagicDNSDNSServerTag 的别名（1591-1593）；sbCollectRuleSets 的 subTagMap 参数没有使用；GenerateNEConfig 的 vpnServerIP 在 NE 下不起作用，因为 buildTUNInbound 对 NE 提前返回（1041-1044）。
- 位置：core/config/generator.go:102-104；core/config/generator.go:110-114；core/config/generator.go:1591-1593；core/config/generator.go:2141-2146；core/config/generator.go:2269-2274；core/config/tailscale.go:12-19；core/config/tailscale.go:29-90；core/config/validate.go:44-49；core/config/validate.go:67-95；core/config/model.go:318-326；core/libbox/configgen.go:1276-1284
- 建议：直接删除。测试里的 CollectProfileWarnings 改用 BuildConnectionPlan(p).Warnings；GenerateSingBox 改为测试辅助函数。
- 注意：低。CollectProfileWarnings 的注释说是给 daemon 或 UI 用的，删除前再 rg 一遍 cmd/。

**P011　Line.TailscaleAuthKey 旧移动端字段已没有写入方**　〔legacy｜复核成立｜可删约 55 行〕

- 结论：Line.TailscaleAuthKey 在所有产品中都没有写入方，理由比审计员说的更强：iOS/tvOS 的 Swift 模型从来没有过 tailscale_auth_key 字段。只有 macOS 在 84eb3f4 到 048b878 之间（只出现在 v0.6.0）有过这个字段，而且当时存在 vault 的 '<id>-tsauth' 里，现在的旧配置读取器不读这个 key。model.go:80 的注释“仅为旧移动端 Profile 兼容字段”本身就是错的。
- 位置：core/config/model.go:80-89；core/config/generator.go:467-472；core/config/runtime_fingerprint.go:83；core/config/runtime_fingerprint.go:205；core/config/generator_test.go:2198-2241
- 建议：删除该字段、NE 下的 authKey 分支、指纹中的 AuthKey 和对应测试；buildTailscaleEndpoint 的 authKey 参数只留给 setup 路径使用。
- 注意：1) 审计员写的风险“旧 App Group 里仍存着 key”不成立，移动端从没写过这个字段。2) generator_test.go:2197-2241 里“节点不得 ephemeral”的断言要保留，移到不带 auth key 的 NE 测试里。3) 还有 3 处测试引用该字段，需要同步删除或改写：generator_test.go:1029、invariants_test.go:438、libbox/configgen_test.go:198。其中 invariants_test 是架构不变量文件。4) test/e2e_test.py:368 也写了这个字段，但该脚本本身已过时（见 new_findings）。

**P012　libbox 硬编码 config 的 tag 命名，并复制了 Tailscale endpoint 构建**　〔duplication｜未复核｜可删约 25 行〕

- 结论：【看到的】configgen.go:1031 写死 'proxy-dns-'+outboundTag，复制了 config.desktopProxyDNSTag 与 transparentProxyResolverForOutbound；:1205 写死 'tailscale-'+ID，复制了 tailscaleEndpointTag；:1672 用前缀 'sub-geoip-' 识别生成的 GEOIP 规则集，依赖 subscription_geoip.go:129 的命名；GenerateTailscaleSetupConfigWithAuthKey 在 1203-1221 手工拼 endpoint，注释写着‘与 buildTailscaleEndpoint 保持同一身份语义’，即靠人工同步。这违反了 tag 只有一个事实源的原则（invariants_test.go 文件头注释也这样要求）。
- 位置：core/libbox/configgen.go:1031-1034；core/libbox/configgen.go:1203-1221；core/libbox/configgen.go:1672；core/config/tailscale.go:102-135；core/config/generator.go:2846-2851
- 建议：config 导出 TransparentProxyResolverForOutbound、BuildTailscaleSetupEndpoint(line, identity, basePath, authKey) 和 IsGeneratedRuleSetTag；libbox 改为调用这些函数。
- 注意：低。

**P013　订阅非严格抓取路径只被 CLI 和无人调用的 parse-sub 使用**　〔legacy｜复核修正｜可删约 50 行〕

- 结论：非严格抓取路径（subscription.Parse 的 URL 抓取分支、fetch/fetchWithContext/fetchWithClient、ExpandRulesets 非严格模式）的调用方只有 CLI 的 `xdial sub parse` 和 daemon 的 parse-sub。macOS 最后一个 parseSubscription 调用在 ec2f29d（v0.9.0）被删除。但审计员要删的“非严格抓取函数”范围写错了：fetchWithClientLimit（parser.go:92-118）被严格路径共用，必须保留；Parse 本身也被 ParseStrict 复用来做内容解析，只能删它的 URL 抓取分支。
- 位置：core/subscription/parser.go:16；core/subscription/parser.go:24-31；core/subscription/parser.go:78-118；core/subscription/ruleset.go:27-30；core/subscription/ruleset.go:127-132；core/config/generator.go:2739-2742；cmd/xdial/daemon.go:353-361
- 建议：删除 daemon 的 parse-sub 和 macOS GoEngine.parseSubscription；CLI 的 sub 命令改用 ParseStrict 和 ExpandRulesetsStrict；删除非严格抓取函数和 generator 中的 RULE-SET 占位分支。
- 注意：1) 必须保留 fetchWithClientLimit 和 Parse 的内容解析部分。2) v0.6.0 之前，tvOS 通过隧道消息做非严格解析，持久化的订阅里可能还有 RULE-SET 占位；删掉 generator 的 case 后它们照样被忽略，不影响。3) 与 P039 是同一问题，建议合并成一个 PR；50 行只算 Go 侧和 daemon 分支，macOS Swift 部分计入 P039。4) 如果 CLI 改用严格抓取，http:// 和内网源会被拒绝；file:// 本来就不支持（Go http.Client 不支持该 scheme）。

**P014　读取 /tmp 文件的手动测试在 CI 中恒跳过**　〔test-bloat｜未复核｜可删约 55 行〕

- 结论：【看到的】TestParseRealSurge 读取 /tmp/sub_test.txt；TestGenerate_RealSubscription 读取 /tmp/xdial-engine/sing-box.json 并直接对它跑 sing-box check，根本不经过生成器。两者在 CI 中都会 t.Skip，属于本地调试残留。
- 位置：core/subscription/manual_test.go:1-33；core/config/generator_integration_test.go:605-623
- 建议：删除；如需保留，改用 testdata 下的脱敏样例。
- 注意：无。

**P015　连通性验收规则在 Go 中按魔法 ID 二次前置**　〔accretion｜未复核｜可删约 25 行〕

- 结论：【看到的】generator 识别 xdial-connectivity-direct 和 xdial-connectivity-anyconnect，把它们的路由规则提到普通 Scenario 规则之前（573-597、1977-1990），注释说是为了防止订阅大网段吞掉它们。但 Swift（appletv/XDialTV/Models.swift:566-584）在规范化时已经执行 bindings = acceptanceBindings + ordinaryBindings，而订阅规则本来就排在所有 Scenario 规则之后。【推论】Go 端的前置是重复保证，同时让产品级魔法 ID 进入了编译器，与‘Scenario 顺序即语义’的规则相悖。TP 路径下这些规则已经被置空，不起作用。
- 位置：core/config/generator.go:34-35；core/config/generator.go:573-597；core/config/generator.go:1941-1990；core/config/generator_test.go:529-613
- 建议：删除 Go 端的前置，buildScenarioRouteRules 只返回一个列表；顺序完全由 Scenario 决定，测试改为断言规则按 binding 顺序输出。
- 注意：如果有绕过 Swift 规范化的旧 Profile（例如通过 CLI 加载），这两条规则的顺序会改由用户 binding 顺序决定，属于预期内的语义。

**P016　移动端 Swift 自己推导 Line tag，Go 没有给移动端提供 Line catalog**　〔boundary-violation｜未复核｜可删约 15 行〕

- 结论：【看到的】appletv/XDialTV/TunnelManager.swift:196-205 在 Swift 中写死 'proxy-'+id 和 'tailscale-'+id，而且漏掉了 anytls；订阅主 tag 取的是 groups.first?.tag，没有用 Go 提供的 MainTag。generator.go:2361 的注释（‘Swift NetworkInfo 只按第一个组算 tag，保持兼容’）就是为这种 Swift 自推导留下的兼容约束。Go 已有 BuildLineRuntimeCatalog（daemon 的 runtime-lines 和 engine 在用），但 libbox 只导出了 SubscriptionRuntimeCatalog，没有导出它。违反 §1：Swift 不复制 Go 的 tag。
- 位置：core/libbox/subscription.go:18-29；core/config/generator.go:2361-2362；core/config/generator.go:2541-2560；appletv/XDialTV/TunnelManager.swift:196-205
- 建议：libbox 导出 RuntimeCatalog(profileJSON)，返回 lines 和 subscriptions（含 MainTag）；移动端改为消费它；删除 generator.go:2361 中的兼容注释约束。
- 注意：移动端改动不在本范围内。AnyTLS 在移动端验收探测中拿不到 tag，属于现存缺陷，要单独确认。

需要作者回答的问题：

- 旧原生 TUN 数据面（PlatformMacOS，也就是 `xdial start` 和 daemon 的 'start'）是否仍是要维护的产品能力？macOS App 已经不发送 start。如果只是历史遗留，生成器桌面分支约 280 行、engine 的 Start 路径和大部分桌面测试都可以删，不变量也应改为守护 TP。
- iOS/tvOS 是否计划迁到 Next 模型（LibboxImportProfile → Line/组/RuleSet）？如果迁，旧 Subscription 运行时编译器（generator.go 2280-2877、subscription_geoip.go、libbox/subscription.go、validate 的订阅分支，以及约 1500 行测试）可以整体删除。迁移时 REJECT 规则在 Next 导入中会被拒绝，产品打算怎么处理？
- make test-profile-document-bridge（tools/profile-document-check.swift）是否仍是发布前检查？它是 Compact、Separate、Reimport、Group 四个 libbox 导出的唯一使用者。
- 是否还有用户库停留在需要 SeparateImportedRuleResources 拆分 'policy/...' 组的状态？如果有，删除前要先确认迁移已经全部完成。
- TP 用硬编码的 223.5.5.5 DoH 解析代理端点域名（configureTransparentProxyEndpointBootstrap，generator.go:514-523/2927-2948），是否符合 §4.3“不依赖固定外部 DNS”？它与 d35 事故记录中否决的“Direct 硬编码 223.5.5.5”是不同用途，但需要作者确认这个边界。
- 两轮 TP 生成（首轮只测 Direct、其余默认双栈，第二轮用逐 Line 的实测能力）能否合并成一个 libbox 入口：lineCapabilitiesJSON 为空时由 Go 填默认值？是否有外部（非本仓库）Provider 依赖现有的多个导出签名？
- daemon 的 parse-sub 是否还有脚本或调试工具在用？（已由 #34 删除）

### Go 运行时 libbox

**P017　死的 gomobile 入口：6 个 PrepareSwitch* + 4 个 Start* 变体 + Status + ProbeStandaloneLineLatency**　〔dead｜复核修正｜可删约 280 行〕

- 结论：列出的 12 个导出在 Swift（含 gomobile 的 With/For 拆分形式）、DebugServer、cmd、tools 中均无产品调用，自 05af780（v0.8.0，2026-09-11）Swift 改走 StartForNetwork / PrepareSwitchForNetwork 后成为遗留入口。可以删除，但要修正三处细节：switch_test 的 14 个测试中有 13 个经由这些死入口，TestStopAllCapabilityTeardownDoesNotHoldLibboxLock 只把 Status() 当锁探针；locations 中的 1100-1113 包含仍在使用的 StartStandalone；macOS 的 RuleSet bootstrap 实例同样使用 StartResolvedWithInsecure 和 StartStandalone。
- 位置：core/libbox/libbox.go:345-356；core/libbox/libbox.go:1028-1033；core/libbox/libbox.go:1040-1098；core/libbox/libbox.go:1100-1113；core/libbox/libbox.go:1555-1769；core/libbox/standalone_line_latency.go:20-25；core/libbox/switch_test.go:43-70
- 建议：删除上述导出。switch_test / tailscale_runtime_test 的 helper 改为直接调用包内的 prepareSwitch / coldStart 或 PrepareSwitchForNetwork。把 prepareSwitch / coldStart 的位置参数收敛成一个 runtimeInputs 结构体（networkSessionRuntimeInputs 已经在产出同样的四元组）。Start 普通版跟随 Phase 0 手测工具的去留决定。
- 注意：switch_test.go 要改写，不能直接删。TestStopAllCapabilityTeardownDoesNotHoldLibboxLock 用 Status() 证明 Stop 不持有 l.mu，删除 Status 前要换成 IsRunning() 之类同样取锁的探针。改调包内 prepareSwitch 时，测试会走 networkGenerations 为空的旧分支，与 P021“删除非 network 分支”冲突；两条一起做时，测试应改用 networkReadinessTestEnvelope + PrepareSwitchForNetwork。tailscale_runtime_test 也依赖 StartStandaloneWithTailscaleLineID 和 PrepareSwitchWithLineRuntimeIDs 注入池化 Tailscale。docs/agent/profile-next.md:154 用名字提到 ProbeStandaloneLineLatency，需要同步修改。Libbox 打包在各自 App 内，不存在跨版本 ABI，删除导出不影响已安装的旧版本，但三份 xcframework 都要重建。

**P018　Tailscale peer 探测、HomeDERP 重选、DNSCaptureDomains 没有产品调用方，背后还挂着一个 tailscale 补丁**　〔dead｜复核修正｜可删约 270 行〕

- 结论：ProbeTailscalePeer、ProbePreparedSwitchTailscalePeer、ReselectTailscaleHomeDERP、TailscaleDNSCaptureDomains 在所有分支的 Swift / cmd / Debug 中都没有调用方，可以删除。需要修正几处：ProbePreparedSwitchTailscalePeer 是 0abde98（2026-08-08）引入的，不是 a5f761f；所列测试区间混有仍在使用的 API 的断言，不能整段删；XDialControlNetInfoState 来自补丁 0003/0006，不在 0005；prepare-patched-go-mod.sh 的 351-367 行校验的是 0009 的过期 NetInfo 回调拒绝，以及 0005 里一个与重选无关的旧 control client 修复，这两项影响生产，不能随重选一起删。
- 位置：core/libbox/tailscale_status_gvisor.go:213-247；core/libbox/tailscale_status_gvisor.go:296-311；core/libbox/tailscale_status_gvisor.go:438-579；core/libbox/tailscale_status_gvisor.go:613-658；core/libbox/tailscale_status_stub.go:16-46；core/libbox/tailscale_status_gvisor_test.go:326-346；core/libbox/tailscale_status_gvisor_test.go:406-418；core/libbox/tailscale_status_stub_test.go:32-107；patches/tailscale/0005-add-bounded-homederp-reselection.patch；scripts/prepare-patched-go-mod.sh:311-370
- 建议：删除这 4 个导出（gvisor 与 stub 两侧）及相关的 payload、helper 和测试。之后评估从补丁 0005（以及修改了 xdial_derp_reselection.go 的 0009）中剥离重选部分；同一补丁里 tailscaleRuntimeReadiness 仍在用的 XDialControlNetInfoState 等诊断要保留。最后删掉 prepare-patched-go-mod.sh 中对应的 grep。
- 注意：测试只删死 API 对应的断言（gvisor_test 339-345、406-418；stub_test 中的 peer probe、reselection 两个测试，以及 prepared-switch 测试里的 probe 那一项），其余要保留。stub_test 虽然从来不执行，但 CI 的 go vet ./... 不带 tag，会对它做类型检查，所以删除 stub 方法时必须同步修改，否则 vet 失败。sing-box 补丁 0002 的 Endpoint.DNSCaptureDomains() 和 dnsCaptureDomains 字段，以及 prepare-patched-go-mod.sh:214 的 grep，会随之变成死代码（见 new_findings）。docs/verification/tailscale.md:15 和 ARCHITECTURE.md:133 要同步修改。剥离补丁时的保留清单见 P154 的修正。

**P019　AnyConnect 旧版 session 重连回退不可达：monitorSession 后半段和 reconnectAnyConnect**　〔dead｜复核成立｜可删约 135 行〕

- 结论：monitorSession 中 activeAnyConnectCapability 为 nil 的回退分支（libbox.go:2783-2834）和 reconnectAnyConnect（2836-2922）在生产和测试中都不可达。anyConnectConfig 字段的唯一读取点就在这段死代码里。
- 位置：core/libbox/libbox.go:2783-2834；core/libbox/libbox.go:2836-2922；core/libbox/libbox.go:134；core/libbox/libbox.go:1221；core/libbox/libbox.go:1401；core/libbox/libbox.go:2450；core/libbox/libbox.go:2468；core/libbox/libbox.go:3074
- 建议：monitorSession 收缩为三步：等待 commit 结束、校验 generation 和 session、委托 capability.ensureTransport。删除 reconnectAnyConnect 和 anyConnectConfig 字段。waitForAnyConnectReconnect 和 anyConnectReconnectDelay 保留，runRecovery 还在用。
- 注意：保留 failAfterAnyConnectReconnect、anyConnectReconnectDelay、waitForAnyConnectReconnect、anyConnectLineStatusJSON 和 runtimeUsers（多处使用）。删除 anyConnectConfig 字段时，session_monitor_test.go:274 的写入也要一起删。anyConnectLineRuntime.activate/deactivate 仍被 line_runtime_pool 使用，不受影响。

**P020　零散死代码：installRoutingProbe、从未写入的 TUN 收发计数、两个等价的 no-op 包装、只在测试中用的 stopAll**　〔dead｜未复核｜可删约 40 行〕

- 结论：installRoutingProbe 没有调用方：coldStart（1343-1347）和 prepareSwitch（1975-1979）各自内联了同样的三行。xdPlatformInterface 上 tunIn/OutPackets/Bytes 四个原子计数从未被 Add，只有 diagnostics() 在 Load，所以 Diagnostics JSON 里的 tun_in_packets 等字段恒为 0，而 tvOS TunnelManager.swift:826 还在读它。wrapTunWithDiagnostics 的 gvisor_darwin 与 default 两个 build-tag 文件实现完全相同，都是 return device。lineRuntimePool.stopAll 只在测试里使用。
- 位置：core/libbox/libbox.go:1546-1553；core/libbox/libbox.go:970-973；core/libbox/libbox.go:995-998；core/libbox/platform.go:66-69；core/libbox/platform.go:694-697；core/libbox/platform.go:708-711；core/libbox/tun_diagnostics_gvisor_darwin.go:1-14；core/libbox/tun_diagnostics_default.go:1-9；core/libbox/line_runtime_pool.go:345-347
- 建议：删除 installRoutingProbe，或让两处内联改为调用它，二选一。删除 TUN 计数字段和对应的 JSON 字段，同时修改 tvOS 的读取。删除 wrapTunWithDiagnostics 及其两个文件。
- 注意：删 Diagnostics JSON 字段会影响 tvOS 解码，需确认对方用的是 decodeIfPresent 或字典读取。

**P021　RefreshPreparedSwitchLineRuntimes 和“非 network”切换分支在生产中是空操作或不可达，网络事实还被输入两遍**　〔legacy｜复核修正｜可删约 55 行〕

- 结论：结论基本成立：PrepareSwitchForNetwork 总会传入非 nil 的 lineNetworkGeneration，所以 RefreshPreparedSwitchLineRuntimes 在生产中只做候选存在性检查后就返回 nil；setter 向 activeTailscalePlatform 的传播分支不可达；macOS 主实例的 setter 调用与 switchCandidate 重复。修正两点：1921 / 2041 行的 ==nil 分支是旧路径上更严格的可用性要求，network 路径才是放宽的一方，原描述把方向说反了。“networkGenerations 改为必选”依赖先删掉 P017 的 PrepareSwitch* 并迁移 switch_test，而且只适用于 prepareSwitch：coldStart 的可变参数必须保留，因为 StartStandalone / StartResolvedWithInsecure（tvOS、iOS、macOS bootstrap）走的就是无 generation 路径。
- 位置：core/libbox/libbox.go:2160-2203；core/libbox/libbox.go:1883-1887；core/libbox/libbox.go:1921；core/libbox/libbox.go:2041；core/libbox/libbox.go:263-273；core/libbox/libbox.go:301-317；core/libbox/line_network_readiness.go:351-379；macos/TransparentProxyExtension/EmbeddedSingBoxRuntime.swift:449-453；macos/TransparentProxyExtension/EmbeddedSingBoxRuntime.swift:2225；macos/TransparentProxyExtension/EmbeddedSingBoxRuntime.swift:2407
- 建议：删除 RefreshPreparedSwitchLineRuntimes 导出及 Swift 的两处调用。删掉 prepareSwitch 中没有 network generation 的分支，networkGenerations 从可变参数改为必选参数。删除 setter 中的 Tailscale 传播分支。macOS 主实例在 StartForNetwork 前不再重复调用 setter（bootstrap 实例仍然需要）。
- 注意：RefreshPreparedSwitchLineRuntimes 并非完全无副作用：候选已 Abort 时它会抛出 'switch candidate is not prepared'，在极窄的竞态下让 Swift 循环提前退出。删掉后下一轮读取状态同样会失败，影响可以忽略。macOS 主实例去掉 setter 时，setUnderlayInterfaceBinding(true) 必须保留，因为 switchCandidate 要拷贝这个标志；bootstrap 实例的 setter 也必须保留。删除后 syncLineRuntimeUnderlayFrom 的 force 参数恒为 true，可以顺带简化。

**P022　active / prepared-switch 成对 API 逐份复制**　〔duplication｜未复核｜可删约 130 行〕

- 结论：凡是需要“对当前代或候选代执行”的操作，都写了两份几乎相同的函数，区别只在借用哪个 box、ctx 和 WaitGroup，以及用哪个当前性校验。具体有：ProbeOutboundIP 的非 family 分支和 ProbePreparedSwitchOutboundIP（循环、clamp、错误拼接逐行相同）；ProbeOutboundTLSCapabilities 和 ProbePreparedSwitchOutboundTLSCapabilities；TailscaleStatus 和 PreparedSwitchTailscaleStatus；PrepareTailscaleDNS 和 PreparePreparedSwitchTailscaleDNS；ReleaseNonHomeDERP 和 ReleasePreparedSwitchNonHomeDERP；tailscaleRuntime 和 preparedSwitchTailscaleRuntime；还有已死的 peer probe 一对。Swift 侧也为每一对写了 switch generation { case .active / .preparedSwitch }（EmbeddedSingBoxRuntime.swift:1723-1737、1600-1606、1621-1637、2612-2631）。EnsureActive/EnsurePreparedSwitchLinesReady 已经示范了正确做法：内部只有一个带 prepared bool 参数的函数。
- 位置：core/libbox/libbox.go:592-659；core/libbox/libbox.go:2221-2297；core/libbox/outbound_tls_probe.go:109-198；core/libbox/tailscale_status_gvisor.go:249-293；core/libbox/tailscale_status_gvisor.go:313-414；core/libbox/tailscale_status_gvisor.go:581-600；core/libbox/tailscale_status_gvisor.go:717-802
- 建议：提取 borrowGeneration(prepared bool)，返回 box、runtimeCtx、networkReadiness、Tailscale endpoint、isCurrent 函数和 release 函数，所有探测和状态函数只写一份。gomobile 面可以保留成对的薄包装，也可以改为带 generation 参数的单个方法，后者能顺带简化 Swift 侧的 switch。
- 注意：两代的借用规则不同（runtimeUsers 与 switchCandidateUsers、commit 期间拒绝借用），抽象时必须原样保留“在锁内 Add”的语义，Commit 的 drain 正确性依赖这一点。

**P023　AnyConnect 隧道 DNS 解析有两套实现，较弱的一套留在 vpn 出口里**　〔duplication｜未复核｜可删约 80 行〕

- 结论：两套实现做的是同一件事：经 VPNBridge 向握手下发的 DNS 服务器发查询。第一套是 vpnOutbound.resolve / resolveViaTunnel / buildDNSQuery / parseFirstA / dnsName，基于 golang.org/x/net/dnsmessage，只走 UDP、只查 A 记录、事务 ID 固定为 0，也不校验响应的 ID 和 question。第二套是 bridgeDNSExchanger，基于 miekg/dns，UDP 截断时回退 TCP，并校验 Response、ID 和 question。anyConnectLineRuntime 已经暴露了 Exchange（anyconnect_runtime.go:114-122），vpn 出口完全可以直接用它。现在保留在 vpn 出口里的，恰好是校验更弱、更不安全的那份副本。
- 位置：core/libbox/vpn_outbound.go:141-245；core/libbox/mobile_dns_transport_enterprise.go:25-153；core/libbox/anyconnect_runtime.go:114-122
- 建议：vpnOutbound.resolve 改为构造一个 A 查询，调用 o.line.Exchange，取首个 A 记录；删除 dnsmessage 那套实现。把 mobile_dns_transport_enterprise.go 改名为 anyconnect_dns_exchanger.go：它也被 macOS 的 xdial-anyconnect transport 使用，并不是移动端专属。
- 注意：行为会变：加上 TCP 回退和严格校验后，以前侥幸通过的畸形响应会失败。vpn_outbound_test.go:22-29 的 fail-closed 测试要保留。

**P024　零散重复：TLS 错误分类 ×3、组解析循环 ×2、测速默认 URL ×2、超时 clamp ×5、伪造 Libbox 复用方法**　〔duplication｜未复核｜可删约 30 行〕

- 结论：x509 / TLS 错误类型列表写了三遍：isTypedTLSProbeError（libbox.go:912-923）、classifyOutboundTLSHandshakeFailure（outbound_tls_probe.go:381-404）、transientLineReadinessError（anyconnect_recovery_owner.go:257-281）。沿 OutboundGroup.Now() 逐层解析到叶子出口（深度上限 32，带 seen 集合）的循环写了两遍：TestOutbound（libbox.go:467-479）和 LineLatencySnapshot（line_latency.go:51-62）。测速默认 URL https://www.gstatic.com/generate_204 出现在 libbox.go:446 和 standalone_line_latency.go:18 两处。500~10000 ms 的超时 clamp 在 TestOutbound、probeOutboundIP、ProbePreparedSwitchOutboundIP、probeStandaloneLineLatency、clampOutboundTLSProbeTimeout 各有一份。EvaluateLineGroupLatencies 构造了一个假的 &Libbox{box, runtimeCtx, running: true}（line_group_latency.go:187-189），只为复用 LineLatencySnapshot 这个方法。
- 位置：core/libbox/libbox.go:446；core/libbox/libbox.go:452-457；core/libbox/libbox.go:467-479；core/libbox/libbox.go:603-608；core/libbox/libbox.go:912-923；core/libbox/libbox.go:2232-2237；core/libbox/outbound_tls_probe.go:200-208；core/libbox/outbound_tls_probe.go:381-404；core/libbox/anyconnect_recovery_owner.go:257-281；core/libbox/line_latency.go:51-62；core/libbox/standalone_line_latency.go:18；core/libbox/standalone_line_latency.go:73-78；core/libbox/line_group_latency.go:187-189
- 建议：抽出几个纯函数：isTLSAuthenticationError、resolveGroupLeaf(box, outbound)、clampTimeout(min, max)、lineLatencyFacts(box, ctx, tags)。常量只保留一个定义来源。
- 注意：低。

**P025　libbox.go 一个文件 3187 行，承担 10 多块独立职责**　〔mixed-responsibility｜未复核｜可删约 0 行〕

- 结论：可拆的块如下（按行号）：A 1-57 包注释和 import，注释仍写着“Phase 0 / tvOS 自研引擎 / TUN 留到 Phase 2”，已过时；B 58-98 gomobile 类型和常量；C 99-237 Libbox 状态（60 多个字段）和代际结构；D 238-412 平台输入 setter 和状态查询（gomobile 门面）；E 413-506 SelectOutbound / TestOutbound，属于测速，应并入 line_group_latency.go；F 508-683 和 784-959 出口公网地址探测，应与 address_probe_policy.go 合成 outbound_address_probe.go；G 684-791 RefreshRuleSet，属于 RuleSet 资源；H 961-1017 Diagnostics；I 1019-1145 Start* 入口，其中 4 个已死；J 1146-1483 coldStart；K 1484-1553 创建能力的 helper；L 1555-1769 PrepareSwitch* 死入口；M 1771-2140 prepareSwitch 核心；N 2142-2219 复用证据和空操作的 Refresh；O 2221-2297 候选代地址探测（与 F 重复）；P-R 2299-2667 Abort / Commit / Retire；S 2669-2749 Stop；T 2751-3061 AnyConnect session 监控和失败上报，含约 140 行死代码，应并入 anyconnect_recovery_owner.go；U 3063-3119 detach / close；V 3121-3187 Tailscale 状态目录锁，应并入 tailscale_runtime.go。按性质归类：gomobile 导出面是 B、D、I、L；事务编排是 J、K、M、N、P-S、U；诊断和观察是 E、F、H、O；协议恢复是 T；资源是 G、V。另有过时注释：registry.go:55-57 说 socks inbound“真机 NE 模式下不会出现”，但 macOS Transparent Proxy 的入口恰恰就是 socks（routing_probe.go:28 的 transparentProxyInboundTag）。
- 位置：core/libbox/libbox.go:1-3187；core/libbox/registry.go:55-57
- 建议：先做本表中“死的 gomobile 入口”“AnyConnect 旧版重连回退”“RefreshPreparedSwitchLineRuntimes”三项删除（约 -560 行）。再按 E、F+O、G、H、T、V 拆出文件。libbox.go 只保留 B、C、D 和 Start / Stop 门面；切换事务移到 switch.go，冷启动移到 start.go。
- 注意：纯移动，不改行为。注意 gomobile 生成头里的文档注释要随方法一起移动。

**P026　Libbox 上的活动能力“投影字段”与能力本体重复，靠反向回调保持同步**　〔over-engineering｜未复核｜可删约 60 行〕

- 结论：bridge、session、anyConnectLine、anyConnectConfig、anyConnectRuntimeIdentity、dnsJSON、tailscaleRuntimeIdentity、tailscaleEndpointTag 这些字段，都能从 activeAnyConnectCapability.snapshot()、activeTailscaleCapability 和池条目推出来；libbox.go:141-144 的注释自己也承认它们是 projections。为了保持同步，能力反过来持有 owner *Libbox 并回调 syncAnyConnectCapability（anyconnect_recovery_owner.go:219-233）。coldStart、Commit、detach 各自手工写 6~10 个字段；CommitPreparedSwitch 在 drain 之后逐个比较 10 个源字段（2393-2405）；validatePreparedSwitchCommitLocked 对 capability 和 identity 字段重复校验（2541-2563）；prepareSwitch 的 activeIsUnchanged 是一个 40 行的布尔表达式（2027-2071）。这是一层层叠上去的防御性检查。如果把活动代表示成一个不可变结构体 {box, ctx, platform, lineRuntimeGeneration, capabilities}，靠指针比较判断是否变化，这些都可以去掉。
- 位置：core/libbox/libbox.go:99-185；core/libbox/libbox.go:1386-1407；core/libbox/libbox.go:2027-2071；core/libbox/libbox.go:2370-2405；core/libbox/libbox.go:2436-2480；core/libbox/libbox.go:2495-2584；core/libbox/libbox.go:3063-3096；core/libbox/anyconnect_recovery_owner.go:202-252
- 建议：引入 activeGeneration 结构体，与 preparedBoxSwitch、retiredBoxGeneration 统一成一个 generation 类型；Commit 原子替换指针。Diagnostics 和 TunnelNameServers 改为从 capability.snapshot() 读取。删除 syncAnyConnectCapability 里的字段拷贝。
- 注意：中。这是最敏感的提交和停止并发路径，switch_test、session_monitor_test 的并发用例必须全部保留，最好在死入口的测试迁移完成之后再动。

**P027　就绪编排在 Go 和 Swift 各写一份，Swift 还把出口展示服务当成门槛**　〔boundary-violation｜未复核｜可删约 120 行〕

- 结论：Go 的 lineNetworkGeneration 已经从 session 计划生成了完整的需求闭包，包括 Line 和订阅（line_network_readiness.go:139-196）；Ensure*LinesReady 逐项探测并缓存证明；LineReadiness 报告里已经带有每条 Line 的 ipv4/ipv6_available。但 Swift 的 prepareGenerationReadiness 先自己并发遍历计划里每条非 Direct Line，调用 probeOutboundTLSCapabilities（EmbeddedSingBoxRuntime.swift:1497-1590），然后再调 ensure*（1600-1606），后者基本命中 Go 的证明缓存。接着 verifySubscriptionReadiness 又用 ProbeOutboundIP（checkip.amazonaws.com 和 1.1.1.1 这两个出口展示端点）给订阅出口加了第二道门（1706-1760），而订阅在 Go 闭包里已经有 TLS 证明。更严重的是 waitForTailscale：它先对 "direct" 出口调用 ProbeOutboundIP，失败就抛 underlayEgressUnavailable（2164-2177）。这与 ARCHITECTURE §4.3 直接冲突：“Direct 的就绪证明……不依赖固定外部 DNS、TLS 或出口展示服务……诊断和展示失败不升级为无关 Line 或整个 Scenario 的连接门槛”。另外，Go 的 ensureNetworkLinesReady 是串行的（710-744），Swift 外面那层并发循环其实是在弥补这个缺陷。出口地址探测也存在两套端点和算法：ProbeOutboundIP（非 family，两个端点顺序尝试）和 ProbeOutboundIPForFamily（DESIGN §4.3 描述的竞速加限流）。
- 位置：core/libbox/line_network_readiness.go:139-196；core/libbox/line_network_readiness.go:680-757；core/libbox/libbox.go:533-578；core/libbox/libbox.go:592-659；macos/TransparentProxyExtension/EmbeddedSingBoxRuntime.swift:1428-1610；macos/TransparentProxyExtension/EmbeddedSingBoxRuntime.swift:1706-1760；macos/TransparentProxyExtension/EmbeddedSingBoxRuntime.swift:2156-2177；macos/TransparentProxyExtension/EmbeddedSingBoxRuntime.swift:1880-1900
- 建议：Go 的 ensureNetworkLinesReady 改为并发探测（上限 4），作为唯一的就绪门槛；Swift 只读 LineReadiness() 取地址族能力。删除 verifySubscriptionReadiness 里的 ProbeOutboundIP 门，以及 waitForTailscale 里的 Direct 出口门，或把它们降级为诊断。非 family 版的 ProbeOutboundIP 只留给还没有需求闭包的 RuleSet bootstrap 实例；如果 bootstrap 也改走 ForNetwork，就整个删掉。
- 注意：中。这会改变连接成功的判定，需要回归 AnyConnect、Tailscale、订阅、Direct-only 各场景。Swift 部分属于另一位审计员的范围，需要协同。

**P028　路由固定目标计数（1.0.0.1 / 1.1.1.1）在任何发布构建里都不产生数据，tvOS/iOS 的数据面验收因此恒失败**　〔other｜复核成立｜可删约 30 行〕

- 结论：a5f761f（2026-07-30，macOS 提交，未改 appletv/ios）给 routing probe tracker 加了 debug 门控。之后 iOS/tvOS 的 PacketTunnelProvider 在任何构建（包括 Debug）里都不调用 setDebugRoutingProbeEnabled，所以 routing-probe-snapshot 恒为 routingProbeZeroJSON，routingEvidenceOK 恒为 false。后果比审计员写的更重：不只是 dataPathVerified 永不为真、on-demand 永不武装，而是每次真机连接在验收后都会进入 applyProbeFailure(shouldStop:true)，随即 stopVPNTunnel，提示“Direct 路由验收失败/分流器未按当前配置选择线路，已自动断开”。这一段是从代码推出来的，没有实机验证。
- 位置：core/libbox/routing_probe.go:24；core/libbox/routing_probe.go:32-60；core/libbox/routing_probe.go:157-206；core/libbox/routing_probe.go:274-292；core/libbox/libbox.go:292-298；core/libbox/libbox.go:1343-1347；core/libbox/libbox.go:1975-1979；appletv/XDialTV/TunnelManager.swift:521-525；appletv/XDialTV/TunnelManager.swift:646-720；appletv/XDialTV/TunnelManager.swift:739；appletv/XDialTV/TunnelManager.swift:1724-1745
- 建议：需要作者二选一。(a) tvOS/iOS 仍需要数据面验收：在 PacketTunnelProvider 启动前调用 setDebugRoutingProbeEnabled(true)，或把门控改成按平台显式传入的参数，这就是一个 bug 修复，可删行数为 0。(b) 不再需要：删除固定目标计数、routingProbeZeroJSON 中对应的字段、相关 Go 测试（routing_probe_test.go:122-200、459-570 中的相应部分），以及 tvOS 的验收逻辑。
- 注意：选 (a) 修 bug（在 Provider 启动前打开门控，或改成平台显式参数）时可删行数接近 0，只能顺带清掉下面这些死代码：installRoutingProbe（libbox.go:1546-1553，0abde98 之后无调用方），以及 Swift 的兼容方法 RoutingProbeSnapshot.provesConfiguredRouting(after:)（TunnelManager.swift:635-653，只有 DataPathProbeTests:339-341 在用）。Go 的 6 个标量计数器 direct_target_*/anyconnect_target_* 只被这个死方法消费，生产路径只看 *_target_tags。但 Swift 的 init(from:) 用 decode（必填）读取这 6 个 key，删 Go 字段前必须先改 Swift 解码器。选 (b) 等同于删掉整个移动端验收机制（与 P134/P149 合并处理），不要重复计数。不论选哪个，都应先实机确认“每次连接被自动断开”的推断。

**P029　mobile_no_tailscale 构建标签从未被设置，stub 测试在 CI 里从不运行**　〔legacy｜复核修正｜可删约 80 行〕

- 结论：mobile_no_tailscale 在 Makefile、scripts、.github、project.yml 的整个历史中都没有被设置过，11 个文件的约束可以简化为 with_gvisor / !with_gvisor。需要修正：stub_test 在 CI 中从不执行，但会被不带 tag 的 go vet ./... 类型检查；不带 tag 构建时 core/tailscalesetup 使用 manager_stub，并不导入 libbox，stub 之所以必需，是因为 ./... 本身包含 core/libbox 和 cmd/libboxtest；测死 API 的测试是 2 个完整测试加 1 个部分测试，不是 3 个。
- 位置：core/libbox/tailscale_status_stub.go:1；core/libbox/tailscale_runtime_stub.go:1；core/libbox/registry_tailscale_stub.go:1；core/libbox/mobile_dns_transport_stub.go:1；core/libbox/tailscale_status_gvisor.go:1；core/libbox/tailscale_runtime_gvisor.go:1；core/libbox/registry_tailscale_gvisor.go:1；core/libbox/mobile_dns_transport_gvisor.go:1；core/libbox/tailscale_status_stub_test.go:1-107；Makefile:37-38；Makefile:155-159；Makefile:187-188
- 建议：把约束简化为 with_gvisor / !with_gvisor。stub 测试删除或精简，只保留 1 个确认“返回 unavailable 且不泄露 tag”的测试，并让 CI 不带 tag 跑一次 go test ./core/libbox。stub 文件本身保留。
- 注意：“让 CI 不带 tag 跑一次 go test ./core/libbox”未经验证：tailscale_runtime_test.go、line_network_readiness_test.go 等不带 tag 的测试，在没有 gvisor 和 Tailscale registry 时可能失败。更稳妥的做法是 go test -run 'WithoutMobileDataPlane$' ./core/libbox。无法只读确认作者本机没有使用该 tag 的未入库低内存 tvOS 构建，需要作者回答。

**P030　腾讯地址端点靠 FQDN 字符串特判，散落在 4 处**　〔accretion｜未复核｜可删约 10 行〕

- 结论：probeOutboundAddress 用 destination.Fqdn == "r.inews.qq.com" 决定三件事：是否先经 Line 的 resolver 解析（libbox.go:810-834）、是否给请求加 _t 查询参数（848-852）、用哪个函数解析响应（900-905）。address_probe_policy.go:95-100 又用 strings.Contains(url, "r.inews.qq.com") 推导限流用的服务名。这些都是 ee2c512（恢复按线路的公网 IP 查询）加进来的特例，可以改成端点结构体上的字段（service、needsLineResolve、cacheBust、parser）。
- 位置：core/libbox/libbox.go:533-561；core/libbox/libbox.go:810-834；core/libbox/libbox.go:848-852；core/libbox/libbox.go:900-905；core/libbox/address_probe_policy.go:95-100
- 建议：给 outboundAddressProbeEndpoint 增加 service、resolveViaLine、cacheBust、parse 字段，探测函数按字段执行，不再比较字符串。
- 注意：低。tencent_address_probe_test.go 覆盖了这条路径。

**P031　lineRuntimePool 的 exclusive 参数在生产中恒为 true**　〔over-engineering｜未复核｜可删约 15 行〕

- 结论：acquireCandidate 在生产代码里有 4 处调用（libbox.go:1263、1290、1861、1912），全部传 exclusive=true。注释说“currently AnyConnect”，但 Tailscale 也传 true。exclusive=false 只出现在 line_runtime_pool_test.go 里一个叫 "shareable" 的假 kind 上。entry 和 reservation 都额外存了一份 exclusive，还参与匹配判断。
- 位置：core/libbox/line_runtime_pool.go:46-60；core/libbox/line_runtime_pool.go:101-107；core/libbox/line_runtime_pool.go:135-176；core/libbox/libbox.go:1263；core/libbox/libbox.go:1290；core/libbox/libbox.go:1861；core/libbox/libbox.go:1912
- 建议：去掉这个参数，所有能力按 kind 互斥，这与 §3.2、§3.3“至多一条 AnyConnect / Tailscale”一致。将来真需要可共享的能力时再加回来。
- 注意：低。

**P032　macOS 上 Go 流量计数器挂在每代 Box 的热路径上，但没人读**　〔duplication｜未复核｜可删约 5 行〕

- 结论：coldStart 和 prepareSwitch 都无条件执行 AppendTracker(&l.traffic)（libbox.go:1342、1974），每条连接都被 Int64CounterConn 包一层。TrafficTotals 只有 tvOS/iOS 的 PacketTunnelProvider 调用；macOS Provider 用自己的 Swift relay 计数（TransparentProxyProvider.swift:862-875 的 self.traffic）。所以在 macOS 上这是重复计数，结果直接丢弃。
- 位置：core/libbox/libbox.go:1342；core/libbox/libbox.go:1974；core/libbox/traffic_counter.go:25-106；macos/TransparentProxyExtension/TransparentProxyProvider.swift:862-875
- 建议：二选一：由宿主显式声明是否需要计数（例如 SetTrafficAccountingEnabled，或只在非 Transparent Proxy 入口安装）；或者 macOS 也改用 Go 计数，删掉 Swift 那一份。目标是只保留一套。
- 注意：低。

需要作者回答的问题：

- tvOS/iOS 的 DataPathProbe 依赖 routingProbe 固定目标计数，但自 a5f761f 起 tracker 只在 macOS DEBUG 下安装，tvOS 拿到的恒为全零快照，dataPathVerified 永远为 false，on-demand 永不会自动启用。这是有意停用（那就应删除验收逻辑），还是回归（那就应在 PacketTunnelProvider 里启用 tracker）？
- HomeDERP 重选（ReselectTailscaleHomeDERP，以及 patches/tailscale/0005 中的重选部分）和 Tailscale peer 探测，计划接入 Debug Server 或 UI 吗？如果不接，是否同意连同补丁的重选部分一起删除？
- Start（普通版）、cmd/libboxtest、tvOS 的 DebugSmokeTest 都是 Phase 0 手测工具，现在还有人用吗？
- tvOS/iOS 将来会引入候选 Switch 或 StartForNetwork 吗？如果会，旧的 Start 入口和 coldStart 的非 network 分支可以一起统一掉；如果不会，这两条路径要长期并存。
- waitForTailscale 先对 direct 出口探测 checkip.amazonaws.com / 1.1.1.1，失败就判 underlayEgressUnavailable。这与 ARCHITECTURE §4.3“Direct 就绪不依赖出口展示服务”冲突，是有意的吗？
- Swift 的 TailscaleEgressFailure 分类消费了 23 个 DERP 路径字段（tailscalePeerDERPPathPayload），现在仍需要这么细的粒度吗？它占了 tailscale_status_gvisor.go 约 370 行，以及补丁 0007 / 0008。
- prepareTailscaleRuntimeSpec、acquireTailscaleStateLocks、subscriptionNetworkIdentity 都在运行时重新解析并改写 configgen 的输出 JSON。是否应该改由 configgen 直接产出 consumer 和 capability 两份配置，以及订阅的运行身份？
- mobile_no_tailscale 这个 tag，有没有未入库的构建（比如低内存的 tvOS 变体）在用？

### Go 旧引擎 / CLI / 构建设施

**P033　旧原生 TUN 数据面自 v0.7.0 起没有产品调用方，却仍整套留在 daemon 和 CLI 里**　〔dead｜复核修正｜可删约 3000 行〕

- 结论：从 a5f761f（v0.7.0 及之后所有 tag）起，macOS App 不再向 daemon 发送 start、stop 或 kill-session；runtime-lines 和 kill-session 从来没有任何客户端。旧原生 TUN 数据面因此没有产品调用方，这一点成立。但可达面比审计员说的大：App 包里随附的 Contents/MacOS/xdial-daemon 就是完整的 CLI，start、stop、status 子命令都能直接执行；这条 daemon 路径已由 #34 关闭。另外，CLI 的 `xdial start` 是在进程内直接跑 engine，并不经过 daemon 的 start，而且显式关闭了 DNS 接管。删除方向成立，但可删清单和行数需要修正。
- 位置：core/engine/engine.go:204-673；core/engine/status.go:1-52；core/engine/singbox.go:1-196；core/engine/singbox_findpath*.go；core/engine/singbox_start_*.go；core/engine/ruleset_prefetch.go:1-374；core/engine/tailscale_readiness.go:1-161；core/engine/dns_takeover.go:252-406；core/engine/dns_takeover.go:844-994；core/engine/underlay_darwin.go:28-37；core/engine/underlay.go:39-65；cmd/xdial/daemon.go:281-326；cmd/xdial/daemon.go:363-370；cmd/xdial/daemon.go:450-511；cmd/xdial/cmd_start.go:1-119；cmd/xdial/cmd_stop.go:1-33；cmd/xdial/cmd_status.go:1-61；cmd/xdial/daemon_tailscale_test.go:1-69；macos/Sources/XDial/GoEngine.swift:860-869
- 建议：先在 ARCHITECTURE §9 把旧 TUN 的定位改成「只保留残留清理」。然后删掉 Engine 的连接路径、外置 sing-box、ruleset_prefetch、tailscale_readiness、Takeover 方向和 GLOBAL 判定，daemon 去掉 start、stop、kill-session、status、runtime-lines 及 preflight，CLI 去掉 start、stop、status，最后 go mod tidy。engine 包只留下 AnyConnect 适配、Underlay 快照和残留自愈。
- 注意：(a) runtime-lines 和 engine.Engine 无关，它调用的 config.BuildLineRuntimeCatalog 仍被 libbox/configgen.go:595/756/789 使用，只能删 daemon 里的 case。(b) 如果为了残留自愈保留 Engine 外壳，RestoreLeftoverDNS 和 selfHealDNSOnce 仍依赖 e.status/StatusDisconnected，status.go 不能整文件删，要一起重构。(c) Takeover 方向的测试和恢复测试共用 fixture，部分恢复测试先用 Takeover 造状态，删除时需要改用 writeState 构造，所以测试的可删量要打折。(d) 删掉 daemon 的 status 命令后，PrivilegeManager.legacyEngineIsIdle 只对 protocol<1 的旧 daemon 生效，不受影响；handleClient:220 连接后推送的 status 事件也可以一起删（LocalDaemonConnection 本来就按 id 过滤）。(e) registration-handoff 和 respawn 的空闲判定 engineStatus(eng)=="disconnected" 要同步改写。(f) 无法只读确认预置配置包的私有分发是否依赖 `xdial-daemon start`，需要作者回答。

**P034　root daemon 的本地提权面**　〔other｜复核成立〕

- 已由 #34 修复：root daemon 拒绝已停用的数据面命令（start、stop、kill-session、runtime-lines、parse-sub）。

**P035　DNS 自愈的「软失败上报」发出去后没人接收**　〔dead｜复核成立｜可删约 90 行〕

- 结论：软失败上报只能变成 daemon 广播的 error 事件，而 v0.7.0 起 macOS 宿主只把它写进日志就丢弃；v0.6.0 还会设置 lastError 并显示给用户。更严重的是：启动时的那次上报发生在 socket 监听之前，被广播给一个空的客户端集合，同时又被标记为「已上报」，所以在任何版本里它都不可能送达用户。
- 位置：core/engine/engine.go:188-202；core/engine/dns_takeover.go:205-208；core/engine/dns_takeover.go:470-506；core/engine/dns_takeover_test.go:2236-2296；cmd/xdial/daemon.go:77-80；macos/Sources/XDial/GoEngine.swift:860-869
- 建议：如果保留残留自愈，就删掉上报链路，只保留 slog 记录。如果确实需要提示用户，应改为结构化状态（参照 InstallationReport），而不是靠 error 事件。
- 注意：(a) recordingDNSCallback 和 blockingDNSCallback（dns_takeover_test.go:313-358）可能还被其他自愈测试使用，删除前先 grep。(b) 如果整体执行 P036，这一条随之消失，不要重复计算。(c) cleanupLocked（engine.go:522）也调用 reportDNSPending，要一起删。

**P036　系统 DNS 残留自愈只服务 v0.6.0 一个版本的遗留，却每 5 分钟常驻 tick，测试约 1.3k 行**　〔legacy｜复核修正｜可删约 2000 行〕

- 结论：从发布 tag 看，只有 v0.6.0 的 App 会驱动 daemon 接管系统 DNS：dns_takeover.go 首次出现于 63d33c4，第一个包含它的 tag 是 v0.6.0；v0.5.0 及更早的 tag 中没有任何 setdnsservers。v0.7+ 正式 daemon 的状态路径与 v0.6.0 一致，启动时会执行 RestoreLeftover。但「残留只来自 v0.6.0」这个前提不成立：v0.7.0 到 v0.9.6 的 daemon 仍然 AllowSystemDNSTakeover(true) 并接受 start，e2e 脚本、手工 socket 请求或任何同用户进程都能在当前版本上制造新的 dns-takeover.json。所以删除自愈必须在删除 daemon start（P033）之后进行，或与之同步。
- 位置：core/engine/dns_takeover.go:1-251；core/engine/dns_takeover.go:407-843；core/engine/dns_takeover.go:925-1180；core/engine/dns_takeover_test.go:1-379；core/engine/dns_takeover_test.go:939-2296；core/engine/engine.go:24-202；core/engine/dns_takeover_sync_darwin.go；core/engine/dns_takeover_sync_other.go；cmd/xdial/daemon.go:120-140；cmd/xdial/daemon.go:182-188
- 建议：作者先确定最低支持的升级起点。如果 ≥ v0.7.0，就删掉整个 dns_takeover、残留自愈、killOrphanSingBox 及其测试。如果还要兼容 v0.6.0，先删周期 tick、上报链路和单值 Address，只保留启动时一次恢复。
- 注意：(a) 与 P033（Takeover 方向）、P035（上报链路）的行数重叠，汇总时不要重复计算。(b) 需要作者给出最低支持的升级起点，以及 v0.6.0 的实际用户情况。(c) Debug 和 Next 各有独立的 rootStatePath，开发机上可能留有用 e2e 或手工 start 制造的残留，删除自愈前先用 networksetup 自查。(d) killOrphanSingBox（daemon.go:140、platform_darwin.go）同样只为旧 start 和 v0.6.0 服务，应与 start 同步删除。

**P037　core/engine 包名不副实：存活的 AnyConnect 适配和 Underlay 快照，与死掉的 TUN 引擎放在同一个包里**　〔mixed-responsibility｜未复核｜可删约 0 行〕

- 结论：看到的事实：libbox 依赖的只有 sslcon.go（VPNClient、诊断）、bridge.go（VPNBridge）、underlay.go（DetectUnderlayInterface），tailscalesetup 只依赖 DetectUnderlayInterface。同一个包里还有引擎、DNS 接管、规则集预取、sing-box 进程管理。结果是死代码随 libbox 一起被编进 iOS、tvOS、macOS，`make test` 也会跑约 2.3k 行 DNS 接管测试，libbox.go:7-8 的注释也还写着「对照 macOS 版 core/engine.Engine:那边 sing-box 是 exec 出去的外置二进制」。
- 位置：core/engine/sslcon.go:1-117；core/engine/bridge.go:1-208；core/engine/underlay.go:1-37；core/engine/underlay_darwin.go:13-26；core/libbox/libbox.go:7-8
- 建议：删除旧引擎时一并拆包：sslcon.go、bridge.go 移到 core/anyconnect，underlay 移到 core/underlay（或 platform），残留自愈如果保留就放到 cmd/xdial 内部。
- 注意：纯移动加改 import，libbox 有 14 处 import 要更新，gomobile 导出的符号不变。

**P038　cmd/xdial 的 Windows 代码已经无法编译，Linux 只是 CI 编译的脚手架**　〔dead｜复核成立｜可删约 57 行〕

- 结论：cmd/xdial/registration_handoff.go 没有 build tag，却使用了 syscall.LOCK_SH、LOCK_EX、LOCK_UN、Flock、O_NOFOLLOW、Stat_t，这些符号在 Windows 的 syscall 包里都不存在，所以 GOOS=windows 必然编译失败。仓库中也从来没有任何 Windows 构建目标或 CI 步骤，3 个 Windows 文件都是死代码。platform_linux.go 和 platform_darwin.go 只有 build tag 不同；peercred_other.go 对非 darwin 平台无条件放行。
- 位置：cmd/xdial/registration_handoff.go:21-132；cmd/xdial/platform_windows.go:1-19；core/engine/singbox_findpath_windows.go:1-7；core/engine/singbox_start_windows.go:1-14；cmd/xdial/platform_linux.go:1-17；cmd/xdial/platform_darwin.go:1-17；cmd/xdial/peercred_other.go:1-8；.github/workflows/ci.yml:9-38
- 建议：删除三个 Windows 文件，合并 platform_linux 和 platform_darwin。更彻底的做法是给 cmd/xdial 整包加 `//go:build darwin`，同时删掉 peercred_other、network_state_other；对 wildcard 构建来说，ubuntu CI 会自动跳过这个包。
- 注意：(a) core/engine 下的两个 Windows 文件是死代码，原因是根本没有 Windows 构建目标，而不是「因为 cmd/xdial 编不过」（engine 是独立的包）。(b) 如果给 cmd/xdial 整包加 //go:build darwin，所有 *_test.go 也必须加同样的 tag，否则 ubuntu 上 go vet 会只剩测试文件而报错。加 tag 后，cmd/xdial 的测试在 CI 中将不再被任何地方编译：它们目前本来也只被 ubuntu 的 go vet 编译，从未运行（见 P047），macOS job 的 ci-macos-build 只构建二进制。(c) core/engine 的 linux 变体（singbox_findpath_linux、underlay_other、dns_takeover_sync_other）仍是 ubuntu 上 go test ./core/... 的必需品，不能顺手删除。

**P039　订阅解析经 root daemon 宽松抓取，且与 tvOS 的 Libbox 严格解析各写一份**　〔boundary-violation｜复核修正｜可删约 65 行〕

- 结论：root daemon 的 parse-sub 确实会用宽松模式抓取任意 http(s) URL，而且当前登录用户的任意本地进程都能经 socket 触发它。但 macOS App 自 v0.9.0（ec2f29d）起已不再调用这条路径，问题处于潜伏状态。“两份解析”的说法也夸大了：解析语义由 Parse 共享，ParseStrict 直接委托给它，不同的只有抓取和展开策略，以及 libbox 侧的后置校验和清洗。建议“macOS 改为进程内调用 LibboxParseSubscription”没有必要：macOS 已经没有订阅解析的消费者（订阅在 macOS 上由 LibboxImportProfile 的严格路径导入成 Profile），直接删除即可。
- 位置：cmd/xdial/daemon.go:353-361；cmd/xdial/protocol.go:16-18；cmd/xdial/cmd_sub.go:1-60；macos/Sources/XDial/GoEngine.swift:697-727；core/libbox/subscription.go:32-47
- 建议：macOS 宿主改为在进程内调用 LibboxParseSubscription，删除 daemon 的 parse-sub、Request.Sub* 字段和 `xdial sub parse`。如果仍需要命令行调试，改成直接调用 libbox 的小工具。
- 注意：1) 审计员写的风险“严格模式会拒绝 macOS 用户的 http/file/内网订阅”不成立：App 根本不调用这条路径，而宽松路径本来也不支持 file://。只有手动用 `xdial sub parse` 的开发者会受影响。2) 每个版本的 daemon 都和自己的 App 一起发布，删 parse-sub 不存在新 App 调旧 daemon 的兼容问题。3) 65 行指 macOS GoEngine 约 63 行加 protocol 字段 3 行；daemon 分支已计入 P013。cmd_sub.go（60 行）是否删除取决于 CLI 去留。4) 应和 P013、以及 macOS 订阅残留（new_findings）一起删除。

**P040　test/e2e_test.py 驱动的是已死的 TUN 路径，读的是旧存储，也没有接入任何入口**　〔test-bloat｜复核成立｜可删约 1029 行〕

- 结论：test/e2e_test.py 没有接入 Makefile、CI、scripts 或 docs（5286b2a 从 docs 中删掉了最后一处引用），驱动的只有 daemon 的旧 start/stop 数据面。Tier B 读取的是旧的 com.kafeifei.xdial defaults 和 ~/.xdial/vault.json，断言的是 198.18.0.2 DNS 接管和 Clash API 9090。Tier A 的旧 key 兼容用例在当前 daemon 上必然失败。该脚本对当前产品已经没有验收意义，但它并非无害：对 v0.9.6 daemon 跑 Tier B 仍会真实接管系统 DNS。
- 位置：test/e2e_test.py:1-1029
- 建议：随旧 TUN 一起删除。TP 路径的端到端验收应基于 ConnectionReport 和 DebugServer 重新设计，不要在这个脚本上修补。
- 注意：(a) P163 是同一个文件，不要重复计算。(b) 作者需要确认开发机上不再手工运行它；如果要保留 TP 路径的端到端验收，应基于 ConnectionReport 和 DebugServer 重写。

**P041　test/macos_ne_probe 与 test/macos_tp_integration 是过期研究工程，按现状无法编译，也不符合当前 Provider 合同**　〔dead｜复核成立｜可删约 1700 行〕

- 结论：test/macos_tp_integration 和 test/macos_ne_probe 都缺少 macos/Shared 源，按现状无法编译。tp_integration 从被引入的那个提交（a5f761f）起就不可能编过，ne_probe 在它最后一次修改（9081181）时也已经编不过。两个工程的启动参数、读取的存储也都不符合当前 Provider 的合同。仓库里没有任何文件引用这两个目录，可以整体删除。
- 位置：test/macos_tp_integration/project.yml:12-50；test/macos_tp_integration/Host/main.swift:13-98；test/macos_tp_integration/Host/main.swift:164-200；test/macos_ne_probe/project.yml:14-17；macos/TransparentProxyExtension/TransparentProxyProvider.swift:205-255
- 建议：删除这两个目录。如果 D34/D35 的结论需要保留可复现性，就在 docs/incidents 里留下 commit 指针（例如 9081181），而不是把不能编译的工程留在 test/ 里。
- 注意：(a) 有一处事实需要更正：tp_integration 的最后一次修改是 9b815dd（2026-08-01），9081181 是 ne_probe 的最后修改。(b) 产品代码仍以遗留身份引用 com.kafeifei.xdial.ne-probe 和 .ne-probe.settings-ui（XDialBuildIdentity.swift:31-35、InstallationTransaction.swift:353/360、ConfigurationDataDeletion.swift:8）。这些用于清理历史安装身份，不能随测试目录一起删掉。(c) 删除前需要作者确认 D34/D35 的复现不再依赖它们；可以在 docs/incidents/d35 中留下提交指针。

**P042　tools/inspector.swift 查找的是已不存在的 bundle id**　〔dead｜未复核｜可删约 213 行〕

- 结论：看到的事实：findXDial() 用 `runningApplications(withBundleIdentifier: "com.kafeifei.xdial")` 查找进程，而现有 bundle id 是 com.kafeifei.xdial.app、.debug、.next（bb53e99/v0.7.1 起），所以它永远找不到进程。注释写着「fallback when embedded server isn't available」，而 Debug/Next 版本都内置了 DebugServer。文件自 68d0fd7（2026-05-08，v0.4.1）起没有改动，只有 `make inspector` 引用它。
- 位置：tools/inspector.swift:1-13；Makefile:83；Makefile:431-433
- 建议：删除这个工具和 Makefile 的 inspector 目标。
- 注意：无。

**P043　Makefile 的 assemble_app 宏与 macos/com.kafeifei.xdial.helper.plist 都已没有引用**　〔dead｜未复核｜可删约 51 行〕

- 结论：看到的事实：`define assemble_app` 最后一次被 `$(call assemble_app...)` 使用是在 a5f761f 之前，现在 bundle 由 xcodebuild 和 project.yml 的 "Embed and sign XDial helper" 组装。宏里拼出来的 bundle 没有扩展，按它组装会得到一个坏包。helper.plist（label 为 com.kafeifei.xdial.helper，AssociatedBundleIdentifiers 为旧 id com.kafeifei.xdial）的引用在 bb53e99（v0.7.1）里已全部删除。
- 位置：Makefile:120-136；macos/com.kafeifei.xdial.helper.plist:1-34
- 建议：删除宏和这个 plist 文件。
- 注意：无。verify-macos-debug-app.py:91 本身就断言 bundle 里只能有本通道的 .daemon.plist。

**P044　补丁栈只增不改：sing-box 0014 完全撤销了 0010，同一提交里的补丁互相改写**　〔accretion｜复核修正｜可删约 300 行〕

- 结论：大体成立：所有 refs 上 patches/*.patch 都只有新增（A），从来没有修改、删除或重命名；sing-box 共 15 个补丁，0012 从未存在。0014 删除了 0010 加入的选项、字段、参数和 IPv6 重解析分支，其中包括 0011 中贯穿的部分。需要修正的几点：(1) 0010 并非完全净零。它新增的测试被 0014 改名为 TestXDialFlowMetadataDefersAddressFamilyDecisionToRoute 并保留了下来，prepare 脚本第 244 行还断言它存在。(2) 0015 改写的 route.go 逻辑来自 0014（RouteOriginalDestination 那一段），不是 0013；它改写的测试文件 route/xdial_flow_resolve_test.go 才是 0013 新建的。(3) tailscale 0001-0009 全部在同一提交 a5f761f 中新增，sing-box 0004-0006 也在同一提交 a844740 中。(4) 针对已撤销选项的反向门禁不止两处，还有 4 处 Go 测试断言。
- 位置：patches/sing-box/0010-reresolve-stale-ipv6-flow-domains.patch；patches/sing-box/0013-resolve-stale-flow-address-after-line-match.patch；patches/sing-box/0014-move-stale-flow-decision-out-of-ingress.patch；patches/sing-box/0015-preserve-first-original-destination-on-line-reresolve.patch；patches/sing-box/0004-inject-bounded-tailscale-dns-memory-snapshot.patch；patches/sing-box/0005-scope-memory-dns-to-authoritative-routes.patch；patches/sslcon/0001-xdial-liveness-and-diagnostics.patch；patches/sslcon/0002-cstp-session-diagnostics.patch；patches/tailscale/0003-xdial-structured-connection-diagnostics.patch；patches/tailscale/0006-expose-control-generation.patch；patches/tailscale/0008-add-home-derp-node-relationship.patch；patches/tailscale/0005-add-bounded-homederp-reselection.patch；patches/tailscale/0009-reject-stale-netinfo-callbacks.patch；Makefile:221
- 建议：按主题把补丁压缩成等价的终态：去掉 0010，把 0011、0013、0014、0015 合成「flow metadata、绑定接口、route 层重解析」两个补丁；0004 和 0005 合并；sslcon 合成一个；tailscale 按诊断、Home DERP 重选、peer DERP 三个主题合并。之后删掉针对 0010 的反向门禁。
- 注意：压缩补丁时需要注意：(1) prepare 脚本第 194-201 行按文件名把 0011 特判为用 git apply 应用（BSD 和 GNU patch 的模糊上下文不一致）。合并后上下文会变，必须保留 git apply 语义，或改为全部用 git apply。(2) 脚本中的 grep 断言依赖测试函数名和文件路径，合并时不能改名。(3) 删掉反向门禁之前应先确认：sing-box 的选项解码使用 DisallowUnknownFields（我在 module cache 的 option/*.go 中看到了，推断 inbound 同样如此），生成器一旦误发该键会在启动或 validator 阶段报错。(4) 可删行数是补丁文件中的中间态和重复行，不是产品代码，并且会失去“一个补丁对应一次事故”的溯源粒度。

**P045　prepare-patched-go-mod.sh 用 92 条 grep 断言为补丁结果兜底**　〔accretion｜未复核｜可删约 150 行〕

- 结论：看到的事实：脚本对 sing-box、tailscale、sslcon 共写了 92 条 `grep -Fq/-Eq`，其中 33 条只是检查某个 `func Test...` 是否存在，其余检查具体代码片段（例如 'if !current {'、'normalized.PreferredDERP = c.myDerp'）。每加一个补丁就多出几条，原因是 BSD/GNU patch 的 fuzz 可能把 hunk 打到错误位置（0011 已经因此单独改用 git apply）。推测：对所有补丁统一用 `git apply --check`（不做 fuzz）加上真正运行补丁里的测试，就能替代这些逐行 grep，而且 grep 本身也查不出「打到了错误位置」。
- 位置：scripts/prepare-patched-go-mod.sh:193-212；scripts/prepare-patched-go-mod.sh:212-442
- 建议：所有补丁统一用 `git apply --check` 加 `git apply`，删除逐行 grep，只保留少数确实需要的反向守卫（例如 tailscale 那条 DebugPickNewDERP 禁用断言）。
- 注意：git apply 对上下文要求更严格，上游版本一动就会直接失败，这正是想要的行为。需要确认没有补丁在依赖 fuzz 才能打上。

**P046　有两个补丁测试包从来没被执行，只被 grep 断言过存在**　〔other｜复核成立｜可删约 0 行〕

- 结论：tailscale 补丁新增的 control/controlclient/xdial_update_test.go（TestXDialNetInfoReceiptRequiresExactHTTPAcceptedSnapshot、TestXDialNetInfoReceiptIsBoundToClientAndRevision）和 sing-box 补丁新增的 route/rule/rule_preferred_by_resolve_xdial_test.go（TestXDialResolvePreferredByUsesDNSTransport、TestXDialRoutePreferredByKeepsOutboundSemantics）不在任何 Makefile 或 CI 测试目标中，只被 prepare 脚本用 grep 断言过存在。
- 位置：Makefile:162-180；patches/tailscale/0005-add-bounded-homederp-reselection.patch；patches/sing-box/0006-route-resolve-preferred-by-dns.patch
- 建议：在 test-patched-tailscale 中加入 github.com/sagernet/tailscale/control/controlclient，在 test-patched-sing-box 中加入 github.com/sagernet/sing-box/route/rule。
- 注意：补上之后测试可能失败，也可能需要 DESKTOP_GO_TAGS。route/rule 包很大，加入后会增加 CI 时间。由于用了 -run 过滤，只会执行 TestXDial* 测试。

**P047　仍在使用的 daemon 测试不在 CI 里，CI 却在跑已死路径的测试**　〔test-bloat｜复核修正｜可删约 0 行〕

- 结论：cmd/xdial 的测试不在 make test 或 CI 中，这一点成立：make test 只运行 ./core/...，CI 中的 go vet ./... 只编译这些测试、不执行。审计员漏掉了 daemon_tailscale_test.go，cmd/xdial 测试合计 604 行。但“CI 在跑已死路径的测试”说得过头了。DNS 接管的恢复路径是活的：投产 helper 每次启动都会调用 eng.RestoreLeftoverDNS()（cmd/xdial/daemon.go:131），ARCHITECTURE §9 也明确把旧 TUN 保留在 helper/CLI 和恢复路径中。core/engine 里的 bridge、sslcon、underlay 还被 core/libbox（即扩展的 Go 核心）使用。ruleset_prefetch、tailscale_readiness、singbox_stop 只服务旧桌面 Engine.Start，而 Start 只能通过 CLI 的 xdial start 或 daemon 的 "start" 命令到达，macOS 宿主从不发送 "start"。
- 位置：Makefile:187-188；.github/workflows/ci.yml:37-38；cmd/xdial/registration_handoff_test.go；core/engine/dns_takeover_test.go
- 建议：把 `./cmd/...` 加进 make test（ubuntu 上 registration_handoff 的 flock 测试可以运行；darwin 专属测试已有 build tag）。删除旧引擎时，它的测试一起删掉。
- 注意：ubuntu 上的 go vet 已经能编译这些测试，加入 make test 不会有编译问题。但 peercred_other.go 中 peerAllowed 恒为 true，涉及对端凭据的断言在 Linux 上的行为可能不同，需要实际跑一次确认。删除旧引擎测试时必须保留 RestoreLeftoverDNS 恢复路径的覆盖，因为它在投产 helper 中执行。

**P048　daemon 协议里有从未或不再有客户端的命令与方法**　〔dead｜未复核｜可删约 15 行〕

- 结论：看到的事实：`runtime-lines` 从 a5f761f 引入起就没有任何客户端。`kill-session` 从 v0.3.0 起没有出现在 Swift 的发送记录里。Swift 的 PrivilegeManager.requestRespawn 自 f85bbfd（v0.8.0）起没有调用方。daemon 侧的 `respawn` 注释写着「Legacy clients still use this command」，对应 ≤v0.7.3 的宿主。engine.SOCKSAddr() 在全仓也没有调用方。
- 位置：cmd/xdial/daemon.go:321-323；cmd/xdial/daemon.go:363-370；cmd/xdial/daemon.go:246-269；macos/Sources/XDial/PrivilegeManager.swift:665-668；core/engine/engine.go:480-487
- 建议：现在就删掉 runtime-lines 和 Swift 的 requestRespawn。kill-session 和 SOCKSAddr 随旧引擎一起删。daemon 侧的 respawn 等确定最低升级起点后再删。
- 注意：daemon 的 respawn 要等确认不再有 ≤v0.7.3 宿主和新 daemon 共存的升级窗口之后再删。

**P049　旧版升级兼容代码散落在 PrivilegeManager、HelperRegistrationCoordinator 和 daemon 里，没有统一的退役点**　〔legacy｜复核修正｜可删约 150 行〕

- 结论：五处旧版兼容代码确实分散，也没有退役版本标记，方向成立。但审计员有两处事实错误：sudoers 从来没有被写过；respawn 的 Swift 客户端自 v0.8.0 起已经是死代码。另外各处服务的最高旧版本需要更精确地标注。
- 位置：macos/Sources/XDial/PrivilegeManager.swift:194-215；macos/Sources/XDial/PrivilegeManager.swift:503-537；macos/Sources/XDial/PrivilegeManager.swift:604-620；macos/Shared/HelperRegistrationCoordinator.swift:170-185；macos/Shared/HelperRegistrationCoordinator.swift:320-340；cmd/xdial/daemon.go:246-269；core/tailscalesetup/state.go:12-123
- 建议：作者明确定一个「最低支持升级起点」，写进 ARCHITECTURE §9，然后按版本把这五处一并退役。范围内估计可删约 70 行（不含 Shared 的 coordinator 分支和 DNS 自愈，它们在别的条目或范围里计算）。
- 注意：150 行只计入与 P085/P086 不重叠的部分：Tailscale 状态迁移约 130 行（不含 state_test 114 行，但 daemon 仍需以 0700 MkdirAll 创建 App Group 下的 NetworkExtension 目录），加上 Go 的 respawn 处理与 respawnDaemon 约 19 行；Swift 的 requestRespawn 可以无条件删除。删除 Tailscale 迁移的前提是最低升级起点 ≥ v0.7.0，否则 v0.6.0 用户的 tailnet 身份会丢失，需要重新登录。DNS 自愈和整个 daemon start/DNS 接管子系统见 new_findings，需要作者确认 daemon 在仓库外没有客户端。

**P050　daemon.go 的 handleClient 是一个 245 行的大 switch，把六类事务和一把共享锁混在一起**　〔mixed-responsibility｜未复核｜可删约 30 行〕

- 结论：看到的事实：handleClient（daemon.go:202-448）在一个函数里同时处理注册交接的 4 种命令及 respawn、旧引擎的 start/stop/kill/status、订阅解析、Tailscale setup 的 5 种命令、resolver 刷新、诊断（daemon-info、connection-report）、runtime-lines。networkRuntimeMu 同时串行化旧引擎和 Tailscale setup。交接的空闲判断 `engineStatus(eng) == "disconnected"`（daemon.go:250）依赖一个永远不会启动的引擎。推测：删掉旧引擎和 parse-sub 之后，daemon 只剩「特权代理」这一种职责：交接、Tailscale setup、连接报告、resolver 刷新、诊断。可以拆成按命令注册的 handler 表，空闲判断只看 tailscaleSetup.HasActiveSession()。
- 位置：cmd/xdial/daemon.go:202-448；cmd/xdial/daemon.go:117-119；cmd/xdial/daemon.go:246-251；cmd/xdial/daemon.go:450-458
- 建议：和旧引擎删除放在同一个 PR 里：去掉 engine 依赖和 engineStatus，把各个 case 拆成独立函数，按「交接门禁、Tailscale、只读诊断、resolver」分组。
- 注意：registration_handoff_test 里的 TestRegistrationHandoffOnlyExemptsReadOnlyDiagnostics 依赖命令名单（registration_handoff_test.go:86），需要同步修改。

**P051　运行身份在 Go、Swift、plist、project.yml 里各写一份，Go 侧还有 4 个字段只在测试里出现**　〔duplication｜未复核｜可删约 24 行〕

- 结论：看到的事实：cmd/xdial/identity.go 为三个 flavor 各列了 10 个字段，其中 hostBundleIdentifier、helperBundleIdentifier、daemonLabel、logPath 在非测试代码里的引用次数为 0，只被 identity_test 的 reflect.DeepEqual 整体断言。同一组值还写在 XDialBuildIdentity.swift（daemonSocketPath、engineRuntimePath、daemonIdentifier）、三个 daemon plist、project.yml（XDIAL_HELPER_IDENTIFIER 等），靠 verify-macos-identity-contract.sh 和 verify-macos-debug-app.py 保持一致。另外 daemon 的 socket 实际上由 plist 的 `--socket` 参数传入，Go 侧默认值只在 CLI 中生效。
- 位置：cmd/xdial/identity.go:13-73；cmd/xdial/identity_test.go:11-79；macos/Shared/XDialBuildIdentity.swift:38-147；macos/project.yml:23-61
- 建议：删除这 4 个无用字段及其测试断言。跨语言的身份表继续以 project.yml 和 Swift 为准，Go 只保留 daemon 自己需要读的路径（App Group、状态目录、intent 路径）。
- 注意：低。

**P052　小规模重复：console UID 获取写了两份，Swift 的 unix socket 连接样板写了三份**　〔duplication｜未复核｜可删约 30 行〕

- 结论：看到的事实：peercred_darwin.go:15-27 的 consoleUID() 和 registration_handoff.go:111-121 的 registrationConsoleUID() 都是 stat /dev/console 取 Uid，只有返回类型不同（int 和 uint32）。Swift 侧，PrivilegeManager.LocalDaemonConnection.init（689-718）、PrivilegeManager.canConnectSocket（777-795）、GoEngine.openSocket（约 780-800）各自手写了 sockaddr_un、strncpy、connect；canConnectSocket 实际上等价于 `LocalDaemonConnection(timeout:) != nil`。
- 位置：cmd/xdial/peercred_darwin.go:15-27；cmd/xdial/registration_handoff.go:111-121；macos/Sources/XDial/PrivilegeManager.swift:689-718；macos/Sources/XDial/PrivilegeManager.swift:777-795；macos/Sources/XDial/GoEngine.swift:777-800
- 建议：Go 侧合并成一个 consoleUID() (uint32, bool)。Swift 侧抽出一个 connectDaemonSocket(path:timeout:)，供三处复用。
- 注意：低。

**P053　cmd/libboxtest 是 Phase 0 时期的手测工具，与现行数据面脱节**　〔legacy｜未复核｜可删约 125 行〕

- 结论：看到的事实：它通过环境变量传入 AnyConnect 凭据，手写 socks 入站和 vpn/direct 出站的 sing-box JSON 再调用 libbox.Start，完全绕过 Profile、ConnectionPlan 和生成器。注释还停留在「Phase 0/2」。自 cde52ef（2026-07-02）起没有改动，没有引用（只有 .gitignore 里有一条），但会被 CI 的 `go build ./...` 编译。
- 位置：cmd/libboxtest/main.go:1-125
- 建议：删除。如果还需要桌面上的 AnyConnect 冒烟测试，改成用 core/libbox 的 Profile 入口写成测试。
- 注意：低。需要确认作者不再手工用它测试企业 AnyConnect。

**P054　tools/repair-menu-bar-tracking.swift 与菜单栏恢复夹具没有任何入口**　〔dead｜未复核｜可删约 59 行〕

- 结论：看到的事实：repair-menu-bar-tracking.swift（fe86693，2026-09-12）是一个硬编码目标为 com.kafeifei.xdial.debug 的一次性修复工具。test/menu_bar_recovery_test.sh 和 test/fixtures/MenuBarRecoveryFixture.swift 也没有 Makefile 目标、CI 或文档引用。推测：这是某次事故现场的处置工具。
- 位置：tools/repair-menu-bar-tracking.swift:1-59；test/menu_bar_recovery_test.sh:1-44；test/fixtures/MenuBarRecoveryFixture.swift:1-91
- 建议：修复工具可以删除，或者移到 docs/incidents 对应条目里作为一次性附件。菜单栏夹具测试如果仍有价值，就给它加一个 Makefile opt-in 目标（参照 test-installation-launch），否则一起删除。
- 注意：低。

需要作者回答的问题：

- ARCHITECTURE §9 写着「旧原生 TUN 保留在 helper / CLI 与恢复路径」，但自 v0.7.0（a5f761f）起宿主不再发 daemon `start`，也忽略 helper 的 status/error 事件。还有没有人（你自己、公司分发流程、脚本）在用 `xdial start` 或 daemon `start`？如果没有，§9 能否改成「只保留残留清理」，或者干脆连清理一起删？
- 最低支持从哪个版本升级上来？只有 v0.6.0 发布过 DNS 接管，v0.6.0 身份迁移、≤v0.5.0 的 /Library helper 加 sudoers 清理、≤v0.7.x daemon 的 protocol<1 交接和 respawn 也都取决于这个起点。预置配置包用户里还有停在 v0.6.0 或更早版本的吗？
- cmd/xdial 的 Linux/Windows 代码还有计划吗？Windows 现在已经编不过（registration_handoff.go 使用了 Flock、Stat_t、O_NOFOLLOW），Linux 只用于 ubuntu CI 编译。能否给 cmd/xdial 整包加 darwin build tag？
- macOS 的订阅解析走 root daemon 的宽松 subscription.Parse，而不是宿主进程内的 LibboxParseSubscription（ParseStrict），这是有意的吗？有没有依赖 http://、file:// 或内网订阅地址的 macOS 用户？
- test/macos_ne_probe 和 test/macos_tp_integration 还需要保留吗？二者按现状都缺 macos/Shared 编不过，tp_integration 也不符合当前 Provider 的启动合同。
- 补丁栈只增不改（每个补丁对应一次事故）是有意保留历史吗？能否按主题压缩成终态补丁（例如去掉被 0014 撤销的 sing-box 0010，合并 0013-0015、sslcon 0001+0002）？
- tools/repair-menu-bar-tracking.swift 和 test/menu_bar_recovery_test.sh 是谁、在什么场景下手工使用的？是否应该补一个 Makefile 入口或文档？

### macOS 宿主：连接与状态

**P055　TransparentProxyManager 是承担约 10 项独立事务的上帝对象**　〔mixed-responsibility｜复核成立｜可删约 0 行〕

- 结论：TransparentProxyManager 有 4211 行，是单个类，第 32-140 行有 51 个 var，函数大纲与所列 10 段职责基本吻合。Switch 两段合计约 880 行，System Extension 三段合计约 363 行，自动重连三段合计约 553 行，HostUnderlay 部分是 3535-4009。拆分建议成立。
- 位置：macos/Sources/XDial/TransparentProxyManager.swift:32-206；macos/Sources/XDial/TransparentProxyManager.swift:288-617；macos/Sources/XDial/TransparentProxyManager.swift:1440-1990；macos/Sources/XDial/TransparentProxyManager.swift:637-680,1005-1200,3411-3533；macos/Sources/XDial/TransparentProxyManager.swift:2466-2552,2736-2851,3060-3409；macos/Sources/XDial/TransparentProxyManager.swift:3535-4009
- 建议：不删功能，按上面 6 块拆成独立类型，TPM 只保留 NE 会话持有和事务生命周期的协调。优先把 HostUnderlay* 和 SystemExtension 激活移出（零语义变化），再把 ⑦ 自动重连抽成可注入时钟的控制器，放进测试 target。
- 注意：HostUnderlay 系列是 private 或 fileprivate 类型（snapshotResult 3658、captureSystemDNSJSON 3799 是 fileprivate），移出后需要放宽可见性，并非完全零改动。publishRuntimeStatus（2830）属于第 ⑥ 项投影，不属于第 ⑦ 项。拆分时必须保持主队列串行，以及 startIntentID、currentTransactionID、activeScenarioSwitch 这些守卫。

**P056　AppState 混合了 UI 状态、连接意图、Switch 编排、SSID/epoch、恢复、Tailscale、安装和持久化**　〔mixed-responsibility｜复核成立｜可删约 0 行〕

- 结论：AppState 有 2902 行，108 行 var 声明，约 64-72 个存储状态，职责混杂，所列分段与函数大纲吻合。init 中的 combineLatest（603-652）延后一轮读取，扇出到约 10 个同步动作。有一处小的标注错误：2546-2601 是“Intents（UI 与 DebugServer 共用入口）”，包括 activateScenario、persistActiveScenario、setupHelper、requireInstallationReady，不是单纯的安装兼容入口。死代码部分：hasLegacyMetaphorKeys 和 rewriteLegacyMetaphorKeys 的调用方在 ec2f29d 中被删除，rewriteLegacyScenario 只被它们调用；add、update、deleteSubscription 没有任何调用方。
- 位置：macos/Sources/XDial/AppState.swift:9-183；macos/Sources/XDial/AppState.swift:287-420；macos/Sources/XDial/AppState.swift:603-652；macos/Sources/XDial/AppState.swift:893-1303；macos/Sources/XDial/AppState.swift:1362-1940；macos/Sources/XDial/AppState.swift:1942-2545
- 建议：先删掉下面列出的死代码和历史代码（约 300 行），再按 4 块抽出协调器，每块成为可单测的类型。
- 注意：死代码约 115 行（2702-2778 和 2792-2829），很可能已在其他条目中计数，这里不重复计入。AppState+Profiles.swift（247 行）也是 AppState 的一部分，拆分时要一并考虑。combineLatest 之后那次 main.async 的时机必须保留。

**P057　运行状态与连接事实存在多份真相**　〔duplication｜未复核｜可删约 80 行〕

- 结论：①运行态门禁跑两遍：TPM.publishRuntimeStatus 已经用 TransparentProxyRuntimeGate.resolve 得出运行态，传给 GoEngine 后，GoEngine.reconcileTransparentProxyStatus 又把这个结果当作 systemStatus 再 resolve 一次，用的是异步晚到的 GoEngine.connectionReport；GoEngine.start 还会自行伪造 "connecting"/"disconnected"。②报告副本：Provider 的 root journal、宿主的用户 App Group journal（宿主既镜像又直接写入）、TPM.currentTransactionSeedJSON（编码副本）、GoEngine.connectionReport、HostScenarioSwitch.sourceReport/candidateReport、两份 projection；TPM 内 ConnectionReportJournal.read() 调用 24 次。③事务 ID：TPM 有 currentTransactionID、networkExtensionSessionTransactionID、connectedSessionTransactionID、automaticReconnectTransactionID、recoveringTransactionID、automaticReconnectRetryFailedTransactionID、hostOwnedTransactionIDs，GoEngine 还有 coldLaunchSettledTransactionID、explicitlyStoppedTransactionID。④“期望场景”：回退链 scenarioSwitchTargetID ?? connectionDesired.scenarioID ?? engine.connectionReport?.scenario.id ?? profile.activeScenarioID 在 AppState 出现 6 次，另有 suspended/resuming ScenarioIDForWake、epoch intent、updateRelaunchDecision 等约 10 个持有者。⑤配置副本：profileLibrary、可变快照 profile（被重新赋值 13 处）、editingProfile（catalog 缓存）。⑥睡眠状态：SystemSleepNetworkEpochGate（只包了一个 Bool）有 3 个实例（TPM:118、TPM:3859、AppState:146），各自喂入。⑦configDirtyFlag 只是 configurationChanges.isDirty 的镜像，手动同步 5 处。
- 位置：macos/Sources/XDial/TransparentProxyManager.swift:2830-2851；macos/Sources/XDial/GoEngine.swift:145-163,950-975；macos/Sources/XDial/TransparentProxyManager.swift:89-123；macos/Sources/XDial/GoEngine.swift:53-54；macos/Sources/XDial/AppState.swift:2084,2112,2166,2191,2264,2358；macos/Shared/NetworkEpochSwitchCoordinator.swift:397-413；macos/Sources/XDial/AppState.swift:54,1415,1443,1711,2654,2699
- 建议：①GoEngine 不再二次门禁，直接发布 TPM 的结果，并去掉自造状态；②报告只在 TPM 持有一份内存副本（加镜像 journal），seedJSON 按需编码；③把事务 ID 收敛成一个 SessionState 枚举（idle、starting、committed、recovering）；④给出唯一的 desiredScenarioID 计算属性；⑤睡眠状态由单一 PowerLifecycle 广播；⑥让 tracker 变成 @Published，删掉 configDirtyFlag。
- 注意：第 ③ 项牵涉启动、恢复、Switch 的竞态守卫；需要先用测试锁住 TransparentProxyRuntimeGate.connectionProofTransactionID 的语义。

**P058　同一 Provider 消息通道有 4 套重复的宿主发送路径**　〔duplication｜未复核｜可删约 130 行〕

- 结论：sendScenarioSwitchMessage（1440-1529）、sendTailscaleControl（1992-2023）、sendLocalSOCKSShare（2026-2054）、sendProviderDiagnostics（2057-2196）各自实现一遍：withExistingManager(.diagnostics)、检查 connected、转换 NETunnelProviderSession、sendProviderMessage、超时闸门、解码、校验 requestID/transactionID。其中 Tailscale 和 SOCKS 两个函数基本是逐行复制，只有类型和大小上限（1MB 与 4096）不同。Provider 端 handleAppMessage 按 "kind" 字段、形状探测（isScenarioSwitchMessage）、诊断 codec 兜底，三段式分发 4 种信封格式。
- 位置：macos/Sources/XDial/TransparentProxyManager.swift:1440-1529；macos/Sources/XDial/TransparentProxyManager.swift:1992-2054；macos/Sources/XDial/TransparentProxyManager.swift:2057-2196；macos/TransparentProxyExtension/TransparentProxyProvider.swift:736-776
- 建议：抽一个泛型 sendProviderMessage<Request: Encodable, Response: Decodable>(timeout:sizeLimit:validate:)；中期统一信封（kind、version、requestID、transactionID、payload），Provider 端只按 kind 分发。
- 注意：Switch 发送有一个 requestSent 竞态标记（1475-1490），必须保留在“即将 sendProviderMessage”的位置；信封统一需要宿主和扩展同版本发布（Debug/Next/正式版各自独立，问题不大）。

**P059　Swift 复制了 Go 的校验与选择规则**　〔boundary-violation｜未复核｜可删约 120 行〕

- 结论：①AnyTLS：Swift 的 anyTLSSupportedClientFingerprints、ALPN 8 项上限和 255 字节、空闲区间 6-3600、MinIdle 0-64（Models.swift:197-281），与 Go generator.go:46-69、2899-2920 逐项重复。②线路组：Profile.lineGroupMemberIssue（Models.swift:1094-1146）重写了 Go validateGroupReferences（native_resources.go:80-121）的环、32 层、AnyConnect/Tailscale 不能入组、URLTest 不能含 Direct 等规则；GlobalConfiguration.validateReferences:328 又调用它。③连接缺口：ConnectionConfigurationBlocker.evaluate 的注释自称“判定与 Go 生成器拒绝的条件一致”。④Tailscale 身份：GoEngine.performTailscaleStatusRequest:599-607 用 JSONSerialization 解析 profile，按 identity_profile_id ?? profile_id 取身份，复制了 Go 的 config.TailscaleIdentityProfileID（tailscale_channel.go:52-57）。⑤LineLatencyStore 在 currentExit、testRequirement、measurement、failure 四处重写 selector 的默认选择规则（GroupDefault ?? 第一个成员），与 Go selectedGroupUsesDirect（native_resources.go:309-324）同义。违反 ARCHITECTURE §1“Swift 不复制 Go 的 schema、依赖闭包”。
- 位置：macos/Sources/XDial/Models.swift:197-281；macos/Sources/XDial/Models.swift:1094-1146；macos/Sources/XDial/ConnectionConfigurationReadiness.swift:1-50；macos/Sources/XDial/GoEngine.swift:597-610；macos/Sources/XDial/LineLatencyStore.swift:117-271
- 建议：新增 Libbox 导出，例如 LibboxValidateLineDraft(lineJSON) 返回结构化问题（字段加 code）、LibboxLineGroupMemberIssue(profileJSON, groupID, memberID)、LibboxConnectionBlockers(profileJSON, scenarioID)；身份 ID 由 Go 在 plan/report 里给出，或者 Provider 按 lineID 自行解析。Swift 只负责本地化展示。
- 注意：编辑器需要逐字段即时反馈，Libbox 调用要足够快（纯函数，无网络）；错误码要映射成中英文文案。

**P060　macOS 订阅解析链与比喻命名迁移是死代码**　〔dead｜复核成立｜可删约 190 行〕

- 结论：以下代码在 macOS 中都没有调用方：GoEngine.ParseResult（69-80）、parseSubscription（397-428）、sendSubRequest（697-728）；AppState.activeSubscriptions（518-527）、比喻迁移三函数（2702-2777）、add/update/deleteSubscription（2792-2828）。合计约 199 行。
- 位置：macos/Sources/XDial/GoEngine.swift:69-80,397-428,697-728；macos/Sources/XDial/AppState.swift:518-527；macos/Sources/XDial/AppState.swift:2702-2777；macos/Sources/XDial/AppState.swift:2792-2828
- 建议：直接删除。同时确认 daemon 端的 parse-sub（cmd/xdial/daemon.go:353）是否还有其他客户端，没有的话一并删除。
- 注意：①Models 中的 Subscription、SubProxyGroup、SubRule 类型要保留：importWarnings 用到 SubRule，Profile 解码也需要它们。②daemon 端的清理见 P152。③与 P083、P107、P152 重叠。

**P061　多 Profile 时代的 profileID 维度残留在 Switch 和测速里**　〔legacy｜复核修正｜可删约 60 行〕

- 结论：Switch 中的 profileID 维度确实恒为 ProfileLibrary.configurationID：enqueueScenarioSwitch 的 profileID 参数没有被使用，scenarioSwitchTargetProfileID 与 scenarioSwitchTargetID 成对赋值，Attempt 中 target 与 source 的比较恒为假，对 activeProfileID 的 3 处写入都是同一个常量，editingActiveProfile 恒为 true，browsedProfileID 只被 DebugServer 读取，都可以删除。但 LineLatencyStore 去掉 profileID 键是一次中等规模的重构，被测试深度绑定，100 行的估计偏乐观。审计员还漏了两点：profile_id 参与运行时配置指纹；activeProfileID 是跨版本共享库的必需解码字段。
- 位置：macos/Sources/XDial/AppState.swift:25,1467-1475,1500-1660,1690,1703,1838,2893-2896；macos/Sources/XDial/LineLatencyStore.swift:23-47,118-280；macos/Sources/XDial/AppState+Profiles.swift:19-21,46,94；macos/Sources/XDial/MainPopover.swift:1392,1418-1445
- 建议：删除 Switch 中的 profileID 维度（参数、@Published 字段、Attempt 字段及其比较）；LineLatencyStore 去掉 profileID 键，改为单 catalog；删除 editingActiveProfile 和 browsedProfileID（DebugServer 同步调整）。
- 注意：①buildProfileJSON 中的 snapshot.profileID 必须继续是 "global-configuration"。它进入运行时配置指纹，改值或置空会让当前连接的指纹不匹配，导致误报「修改待应用」，并使 LineLatencyStore 的 bind 被拒绝。②ProfileLibrary.activeProfileID 和 editingProfileID 只能停止写入，不能从 Codable 中移除：init(from:) 用 decode（必需键）读取，Debug、Next、正式版共享 profiles.enc，旧版本会解码失败。③LineLatencyStore 的 profileID 在 LineGroupSelectionTests 中被大量使用：profileID "p"、:61 的跨 Profile 隔离测试、:610 的 updateCatalogs([record, other]) 多 catalog 测试。去键需要改写约 20 个测试，建议拆成独立 PR，在此之前只做 Switch 部分。④MainPopover:1392、1418 要改为只比较 scenarioID 或 scenarioSwitchTargetID != nil；:1256 的 guard 可以直接删除。

**P062　手动重试与 underlayChange 触发器已无入口，测试仍在覆盖**　〔dead｜复核修正｜可删约 75 行〕

- 结论：retryAutomaticReconnectNow 三层转发、AppState.automaticReconnectState、retryCountdownSeconds、AutomaticReconnectTrigger.underlayChange 都没有生产入口；AutomaticConnectionPolicy.defaultEnabled=true 与实际默认值 false 相矛盾，且只有测试使用。但 presentsConnectionReport 在生产代码 AppState:215 中被读取，属于「恒为 false 的常量应内联」，不是死代码。测试范围也漏掉了 AutomaticReconnectRetryPolicyTests:62-78。
- 位置：macos/Sources/XDial/AppState.swift:209-211,1427-1430；macos/Sources/XDial/GoEngine.swift:268-271；macos/Sources/XDial/TransparentProxyManager.swift:3158-3166；macos/Shared/AutomaticReconnectRetryPolicy.swift:11,56-59,128-132；macos/Shared/AutomaticConnectionPolicy.swift:6,218；macos/Tests/AutomaticReconnectRetryPolicyTests.swift:4-44,94-126；macos/Tests/AutomaticConnectionPolicyTests.swift:5,272
- 建议：删除这些成员及对应测试。underlayChange 分支删除后，delay(after:) 可以简化为只看 rollbackComplete 和预算。
- 注意：①ReconnectIncidentHistory 按 decode(AutomaticReconnectTrigger) 严格解码，只按数量保留 50 条、没有时间淘汰，2026-08-16 之前的 "underlay-change" 记录可能仍在文件里。直接删除这个 case 会让整份历史解码失败、返回空，下一次写入时覆盖全部诊断历史，不只是丢那一条。建议保留可解码的兼容（自定义 init，把未知值映射掉），或先迁移文件。②testRetriesOnlyCompletedUnderlayEgressFailure 还断言了退避序列 2/5/30/nil、maxAttempts=5、stableResetInterval=300，应改用 .unexpectedDisconnect 保留这些断言，不能整条删除。③testUnderlayRecoveryDoesNotRetryLineOrHandshakeFailures（:62-78）也用到 .underlayChange，需要一起删除。④presentsConnectionReport 只能改写为 wakeReconnectPhase != nil 时返回 nil，不能直接删除读取处。

**P063　SSID 断开边界与 forceMatching 从未接线，只有测试在验证**　〔test-bloat｜未复核｜可删约 55 行〕

- 结论：SSIDScenarioSelectionState.noteWiFiDisconnected()（NetworkEpochSwitchCoordinator.swift:23-26）在生产代码里从未调用过（git log -S 无记录），因此 .disconnected 分支不可达；forceMatching 参数 AppState 也从未传 true（activateScenarioForCurrentSSIDIfNeeded 唯一调用点 2071 不带参数）。测试 testConfirmedWiFiDisconnectAllowsSameSSIDToActivateAgain、testExplicitCurrentSSIDRuleEditCanReplaceManualSelection 断言了应用里并不存在的行为，给人虚假信心：实际上断开后重新连上同一 SSID 时，手动选择不会被清除。
- 位置：macos/Shared/NetworkEpochSwitchCoordinator.swift:16-55；macos/Sources/XDial/AppState.swift:2096-2118；macos/Tests/NetworkEpochSwitchCoordinatorTests.swift:91-140
- 建议：两条路二选一：按 ARCHITECTURE §8“手动选择持续到 SSID 下次变化”的本意，在 WiFiSSIDMonitor 的 powerState 或断开事件处接线 noteWiFiDisconnected；或者删除这两个入口和对应测试。不要保留“只有测试使用”的状态。
- 注意：若选择接线，会改变“关 Wi-Fi 再开同一 SSID”时的自动切换行为，需要产品确认。

**P064　Models.swift 中的场景模板、latencyTestLines 与 updateMatchingResource 无人调用**　〔dead｜复核成立｜可删约 55 行〕

- 结论：macOS Models.swift 中的 Profile.templateOverseas、templateDomestic、templateDomesticSS（1006-1040）和 latencyTestLines(for:)（1057-1070）没有引用；updateMatchingResource（1046-1054）只在 ProfileLibraryTests:281 使用。appletv/XDialTV/Models.swift 中有同名的独立副本，仍被 tvOS/iOS 使用，所以「全仓库 0 引用」应改为「macOS 版 0 引用」。
- 位置：macos/Sources/XDial/Models.swift:1006-1041；macos/Sources/XDial/Models.swift:1046-1054；macos/Sources/XDial/Models.swift:1057-1070
- 建议：删除，并去掉对应的单个测试断言。
- 注意：updateMatchingResource 唯一的测试断言位于 P079 要删除的 testGroupedConditionsSurviveStorageAndSourceRefresh 中，两项应在同一次改动中处理。不要动 appletv/XDialTV/Models.swift 的同名副本。

**P065　零散死代码与无效参数**　〔dead｜复核成立｜可删约 55 行〕

- 结论：以下零散死代码都成立，可以删除或简化：saveVisualOrderAsync 没有调用方；ConnectionReport.updateTasks(kind:state:) 没有调用方；cancelAutomaticReconnectRetry 的 resetAttempts 分支是死的（调用点是 5 个，不是 6 个，6 是连同定义的命中数）；setupHelper 的 thenConnect 轮询不可达，且 setupHelper 在 Release 中完全没有调用方；GoEngine.EngineStatus 没有引用；handleEvent 的 status/error 分支只是忽略事件。
- 位置：macos/Sources/XDial/AppState.swift:2661-2662；macos/Shared/ConnectionTransaction.swift:857-865；macos/Sources/XDial/TransparentProxyManager.swift:3396-3409；macos/Sources/XDial/AppState.swift:2575-2590；macos/Sources/XDial/GoEngine.swift:860-872,977-997
- 建议：直接删除。handleEvent 可以简化成只记录日志，或者在 daemon 端停止向桌面客户端广播 status。
- 注意：①setupHelper 可以简化为 installation.retry()，或直接内联到 DebugServer 的 setup-helper 路由。docs/agent/debug-server.md:32 记载了这个路由，路由本身要保留。②handleEvent 简化后仍要保留 appLog，daemon 侧的 status 广播仍服务 CLI，不要动。③删除 resetAttempts 参数后，5 个调用点要同步改签名。

**P066　helperInstalled/helperNeedsApproval 是安装状态的第二份真相，Release 版只写不读**　〔legacy｜复核成立｜可删约 20 行〕

- 结论：AppState.helperInstalled 和 helperNeedsApproval 在 Release 中只写不读，读取方只有 #if DEBUG 的 DebugServer（137-138、823-824）。写入点除了 checkHelper（2779-2790）和 $report 订阅（598），还有 init 中的 checkHelper()（679）和卸载成功分支（1323），审计员漏列了后两处。
- 位置：macos/Sources/XDial/AppState.swift:40-42；macos/Sources/XDial/AppState.swift:2779-2790；macos/Sources/XDial/AppState.swift:594-600
- 建议：删除这两个字段和 checkHelper；DebugServer 改为直接读 PrivilegeManager.status 或 InstallationReport。
- 注意：①DebugServer 中 5 处 state.checkHelper() 和 2 处读取需要改为直接读取 PrivilegeManager.status 和 legacyInstalled，键名可以保持不变，以兼容手工验收习惯。②「每次触发全量 UI 重算」的说法偏重：installation.objectWillChange 已经转发给 AppState，额外的 publish 属于冗余，不是独立的性能问题。

**P067　“已提交且仍接管”判定与 ingress 任务 ID 字面量散落多处**　〔duplication｜未复核｜可删约 50 行〕

- 结论：判定式 state == .committed && !systemTakeoverRemoved && 存在 id=="ingress:transparent-proxy" 且 kind=="ingress" 且 state==.committed 的任务，完整复制了 4 份：TransparentProxyRuntimeGate:43-50、ConnectionReportRuntimeFacts:20-28、TPM.committedReport:1861-1879、TPM.diagnosticsTransactionIsCurrent:2198-2216；另有部分版本（只判断 committed && !systemTakeoverRemoved）出现在 AppState 的 235-247、643-645、1601-1606、1697-1701 和 TPM:298-302、483-489。字面量 "ingress:transparent-proxy" 在 macOS 非测试代码中出现 21 次，它其实是 Go connection_plan.go:277 生成的任务 ID。
- 位置：macos/Shared/TransparentProxyRuntimeGate.swift:43-50；macos/Shared/ConnectionReportRuntimeFacts.swift:20-28；macos/Sources/XDial/TransparentProxyManager.swift:1861-1879,2198-2216；macos/Shared/ConnectionTransaction.swift:801,1003,1030-1052
- 建议：在 ConnectionReport 上加 holdsCommittedTakeover 计算属性，并加一个任务 ID 常量（或由 plan 标注 ingress 任务），其余调用点全部改为引用它们。
- 注意：低。注意 canCommitSystemTakeover 判断的是 .committing 而不是 .committed，不能合并。

**P068　恢复职责分裂成两套引擎，需要额外的所有权枚举来仲裁**　〔accretion｜未复核｜可删约 100 行〕

- 结论：ARCHITECTURE §5.4 只描述一套“完整恢复，共享五次预算”。实际有四个入口、三种预算：①TPM 处理宿主自己发起的会话掉线和启动自动连接失败，5 次，2/5/10/20/30 秒；②AppState 的期望连接 reconcile 处理唤醒、adopted 会话丢失和启动自动连接：等断开 12 秒、等网络 8 秒、再 connectAutomatically，每次唤醒都可能触发，不计入 TPM 预算；③AppState 的自动 Switch 重试，3 次，2/5/10 秒；④AppState.prepareAutomaticReconnect 通过 automaticReconnectPreparationHandler 回调参与 TPM 的重试决策。为仲裁①和②，又引入了 ConnectionDesiredState.RuntimeOwnership（adopted、restoring、owned）。此外还有三个“等网络”的组件：NetworkAvailabilityWaiter、HostUnderlayCapture 的 3 秒等待、epoch 的 1.2 秒静默窗口。git log 中恢复相关的 fix 反复出现：b6a91bb、7eb9a4f、d56a6f2、a99bb2a、30e6492、ea8d673、05af780、c90ceac。
- 位置：macos/Sources/XDial/TransparentProxyManager.swift:2466-2552,3060-3409；macos/Sources/XDial/AppState.swift:1102-1303；macos/Sources/XDial/AppState.swift:2180-2210,2314-2370；macos/Shared/AutomaticConnectionPolicy.swift:34-150；macos/Sources/XDial/NetworkAvailabilityWaiter.swift
- 建议：把“会话丢失后的完整恢复”统一由一个 RecoveryController 持有，覆盖 owned 和 adopted 两种情况，共享同一个预算和事件记录。AppState 只负责提供期望场景，唤醒时只通知它重新评估。合并后可以去掉 RuntimeOwnership.restoring 和 NetworkAvailabilityWaiter。
- 注意：高：这是事故最集中的区域。必须先给 TPM、AppState 抽出的控制器补时序测试（注入时钟），再合并；要特别保留 Dark Wake 期间不发起事务的语义（SystemSleepNetworkEpochGate）。

**P069　断线事件历史 journal 在 Release 版只写不读**　〔over-engineering｜未复核｜可删约 200 行〕

- 结论：ReconnectIncidentHistory.swift 共 382 行（模型、文件锁、持久化），TPM 在 9 个位置写入 reconnect-incidents.json，测试 203 行。生产中唯一的读取方是 DebugServer:239，而 DebugServer 整个文件包在 #if DEBUG 里。Release 和 Next 用户的数据只写不读，UI 也不展示。ARCHITECTURE §5.4 写着“断线历史均为结构化事实”，但没有消费方。
- 位置：macos/Shared/ReconnectIncidentHistory.swift；macos/Sources/XDial/TransparentProxyManager.swift:886-896,2488-2545,2740-2750,2790-2800,3120-3135,3255-3265,3375-3390
- 建议：二选一：如果需要用户可导出的诊断，就接入诊断导出或 UI；否则把事件并入 ConnectionReport.events（已有结构化事件），删除独立 journal，或限定为 DEBUG 构建。
- 注意：会影响 Debug 验收看到的 reconnectIncidents 字段；需要和 ARCHITECTURE 的“结构化事实”条款一起修订。

**P070　AppState 内 SSID 匹配块被复制粘贴**　〔duplication｜未复核｜可删约 45 行〕

- 结论：activateScenarioForCurrentSSIDIfNeeded（2096-2147）与 scheduleNetworkEpochSettlement 闭包里的 SSID 分支（2246-2295）几乎逐行相同：rawMatch、supersede、currentDesired 回退链、ssidScenarioSelection.resolve、recordSSIDSelectionReason、未匹配时 noteUnmatchedSSID、observeSSIDResolution。“清空 Switch 目标”的三连赋值（scenarioSwitchTargetID、scenarioSwitchTargetProfileID、scenarioSwitchRequiresUnderlayRefresh）重复 9 次。
- 位置：macos/Sources/XDial/AppState.swift:2096-2147；macos/Sources/XDial/AppState.swift:2246-2295；macos/Sources/XDial/AppState.swift:1585-1593,1819-1822,1834-1836,1910-1915,1936-1939,2331-2335,2467-2470,2516-2519
- 建议：抽出 resolveSSIDIntent(ssid:) -> QuietToken? 和 clearPendingSwitchTarget()，两处共用。
- 注意：低；注意闭包内使用的是采样得到的 wifi.ssid，不是 currentSSID。

**P071　小工具重复：IP 字面量校验、一次性完成闸门、daemon socket 客户端**　〔duplication｜未复核｜可删约 80 行〕

- 结论：①inet_pton 包装有 4 份：TPM.swift:10-26（按地址族）、TPM.swift:3834-3846（同一文件、HostUnderlayCapture 内又写一份）、NetworkInfo.swift:280-287、TransparentProxyProvider.swift:2808-2820。②一次性完成闸门有两套：TPM 的 HostCompletionGate（4074-4093，带锁并 hop 到主队列）和 GoEngine 的 TailscaleRequestCompletion（998-1007）。③连接同一个 daemon socket 的客户端有三份：GoEngine.openSocket/readAvailable/processLines（770-848，长连接）、PrivilegeManager.LocalDaemonConnection（678-760）、PrivilegeManager.canConnectSocket。
- 位置：macos/Sources/XDial/TransparentProxyManager.swift:10-26,3834-3846；macos/Sources/XDial/NetworkInfo.swift:280-287；macos/Sources/XDial/TransparentProxyManager.swift:4074-4093；macos/Sources/XDial/GoEngine.swift:770-848,998-1007；macos/Sources/XDial/PrivilegeManager.swift:678-780
- 建议：在 Shared 放一个 IPLiteral.isValid(_:family:)；统一使用一个 OneShotCompletion；daemon 客户端合并为一个 DaemonClient（长连接，同时支持一次性请求）。
- 注意：daemon 客户端合并牵涉 PrivilegeManager（安装范围），需要协调。

**P072　Tailscale 登录流程分散在 4 层；GoEngine 名不副实且有 14 个纯转发**　〔mixed-responsibility｜未复核｜可删约 60 行〕

- 结论：Tailscale 的 prepare、login、轮询、logout 分布在：SettingsView（1158-1230，编排状态位）、AppState（170-183、287-420，状态、错误、忙碌集合和 2 秒轮询）、GoEngine（451-688，租约、daemon 和 Provider 路由、解析 profile JSON）、TPM（1992-2023，Provider IPC）。GoEngine 这个名字来自 helper 托管数据面的时代（handleEvent 注释写着“helper 不再拥有桌面数据面”），如今只是 TPM 门面（245-372 有 14 处 transparentProxy. 纯转发）加 daemon 客户端、Tailscale 租约，再加 appLog 的混合体。
- 位置：macos/Sources/XDial/SettingsView.swift:1158-1230；macos/Sources/XDial/AppState.swift:170-183,287-420；macos/Sources/XDial/GoEngine.swift:245-372,451-688；macos/Sources/XDial/TransparentProxyManager.swift:1992-2023
- 建议：抽出 TailscaleConfigurationSession（@MainActor ObservableObject），持有状态、轮询、租约和路由；View 只调用 begin/cancel。把 GoEngine 改名为 ConnectionRuntime（或并入 TPM 的 MainActor 门面），daemon 客户端单独成类。
- 注意：中；租约挂起和恢复与 start/switchScenario 交织（GoEngine 145-225），迁移时要保持成对调用。

**P073　Shared 目录的含义是“可测试”而不是“两进程共享”**　〔boundary-violation｜复核修正｜可删约 0 行〕

- 结论：方向成立：Shared 里不少文件实际只服务一个进程，ConnectionTransaction.swift 也确实混放了计划/报告模型、状态机、journal、AnyConnect 证据和 Provider 回调闸门（行号核实无误）。但按文件划分所有权并不干净，因为有几处跨文件的类型依赖。ScenarioSwitchFailureCode 定义在被判为“只给宿主”的 AutomaticScenarioSwitchRetryPolicy.swift 中，却被只给 Provider 的 TailscaleReadiness.swift:488 使用。ConnectionFailureCode 定义在 AutomaticReconnectRetryPolicy.swift 中，被扩展的 EmbeddedSingBoxRuntime 使用。HostUnderlayCaptureEvidence 定义在宿主侧的 HostUnderlayCaptureDiagnostics.swift 中，却作为字段嵌在契约类型 ConnectionTransaction.swift:290（ConnectionFailureEvidence）和 AutomaticReconnectRetryPolicy.swift:23 里。因此三目录拆分必须按类型进行，先把这几个类型移进 Contract。
- 位置：macos/project.yml:68-74,183-188,402-406；macos/Shared/ConnectionTransaction.swift:212-263,265-520,1185-1417
- 建议：拆成三个目录：Shared/Contract（两进程真正共享的 IPC 和报告合同）、Host/Policies、Provider/Policies。测试 target 同时编译三者；ConnectionTransaction.swift 按模型、状态机、journal、AnyConnect 证据拆成 4 个文件。
- 注意：只按文件搬目录会导致 Provider 目录反向依赖 Host 目录，或者 Contract 依赖 Host 目录。必须先把 ScenarioSwitchFailureCode、ConnectionFailureCode、HostUnderlayCaptureEvidence 及其 FailureReason 移进 Contract。同样要更新 Makefile:206-207 中以 macos/Shared 为搜索根的门禁。

**P074　约 8.1k 行核心编排代码不在测试 target 中**　〔other｜复核成立｜可删约 0 行〕

- 结论：XDialTests 的 sources 不含 TransparentProxyManager.swift（4211）、AppState.swift（2902）、GoEngine.swift（1008），合计 8121 行。测试 target 没有 TEST_HOST，无法 @testable import XDial，所以这些编排逻辑只能通过抽到 Shared 的策略类型间接测试。实际缺口比这还大：扩展侧的 TransparentProxyProvider（3096）、EmbeddedSingBoxRuntime（3175）、UDPFlowSOCKSRelay（978）同样不在测试 target 里。
- 位置：macos/project.yml:402-447
- 建议：拆分上帝对象时，把 NE 依赖（NETransparentProxyManager、OSSystemExtensionManager、NWPathMonitor、Libbox）放到协议后面，让新的控制器进入测试 target。
- 注意：“策略类型繁多的根本原因是测试缝”属于推断，但与目录结构吻合。拆出来的新控制器必须逐个加进 project.yml 的 XDialTests sources，因为该 target 只自动编译整个 Shared 目录。Provider 侧的大文件也应列入同一测试改造范围，否则 Provider 的恢复和 Switch 逻辑依然没有测试缝。

**P075　运行中主线程每 200ms 同步阻塞地向 helper 请求 Provider 报告**　〔other｜复核修正｜可删约 0 行〕

- 结论：主线程确实会同步阻塞地向 helper 请求 Provider 报告：阻塞的 Unix socket，SO_RCVTIMEO 为 0.2s，每个周期还要读两次 journal 文件。但这不是“运行中”持续发生的。轮询只在连接事务期间进行：从 beginTransaction（2607）或中断恢复（2920）开始，到 journal 进入 committed/failed/cancelled 即停止（2646-2651）。此外每次 NEVPNStatusDidChange（主队列）以及 fetchLastDisconnectError 回调也会各请求一次。daemon 端处理 connection-report 只是读一个文件，正常耗时很短；最坏情况下每个周期阻塞约 0.2s 以上。
- 位置：macos/Sources/XDial/TransparentProxyManager.swift:2631-2695；macos/Sources/XDial/PrivilegeManager.swift:652-663,688-760
- 建议：把 Provider 报告获取移到后台队列；或者让 helper 通过 GoEngine 的长连接推送 connection-report 事件，取代轮询。
- 注意：推断出一个边界情况：宿主自己从不写 .committed（rg '\.committed' TPM 只有读取），停止条件完全依赖镜像过来的 Provider 报告。如果 helper 不可达，probe 每次都会立刻失败，阻塞很小，但 Timer 永远不会停，会在整个已连接期间以 5Hz 持续轮询并读文件，直到 currentTransactionID 变化。改成异步时必须在回调里重新校验 currentTransactionID，并保留“镜像写入 journal 之后才判定停止”的顺序。

**P076　schema 3 下恒为空的 subscriptionID 字段仍驱动范围内多处分支**　〔legacy｜未复核｜可删约 30 行〕

- 结论：GlobalConfiguration.validateReferences 要求 scene.defaultSubscriptionID 和 binding.subscriptionID 为空（GlobalConfiguration.swift:347-353），ProfileLibrary.validated 要求各 Profile 的 subscriptions 为空（ProfileLibrary.swift:172）。但范围内的 ConnectionConfigurationReadiness.swift:33、LineLatencyStore.swift:177-179、AppState（含死代码在内 14 处）仍按“订阅可能是出口”分支处理。这些字段只为迁移旧 schema 和 Go 跨平台合同保留。
- 位置：macos/Sources/XDial/ConnectionConfigurationReadiness.swift:33；macos/Sources/XDial/LineLatencyStore.swift:175-180；macos/Sources/XDial/GlobalConfiguration.swift:345-356
- 建议：在 macOS 宿主内把 Scenario 的出口视为只有 Line（subscription 字段只在迁移和 JSON 合同层保留），删掉范围内的订阅分支；MainPopover 等其他范围由对应审计确认。
- 注意：Go 合同和 iOS/tvOS 仍使用 Subscription，不能删除模型字段本身，只删除 macOS 宿主内的分支。

**P077　MenuBarTrackingRepair 会改写 Apple Control Center 的偏好设置 plist**　〔other｜未复核｜可删约 0 行〕

- 结论：它不是叠加出来的补丁：MenuBarRecovery 系列只有 fe86693、bb59a1c 两次提交，策略也有界（3 次重建后停止）。但 TrackingRepair 在 macOS 26 上用 CFPreferencesSetValue 改写 ~/Library/Group Containers/group.com.apple.controlcenter/…plist 中其他 App 名下的 menuItemLocations。它有备份和完整 schema 校验，但改的是 XDial 之外的系统组件状态，而且没有退役条件（只判断 majorVersion == 26）。
- 位置：macos/Sources/XDial/MenuBarTrackingRepair.swift:85-109；macos/Sources/XDial/MenuBarRecoveryController.swift:95-129
- 建议：保留重建逻辑；把 TrackingRepair 改成用户显式触发（或只提示），并加上 macOS 小版本上限，Apple 修复后即可移除。
- 注意：移除自动修复后，受 Tahoe bug 影响的用户可能再次丢失菜单栏图标。

需要作者回答的问题：

- cmd/xdial/daemon.go 的 parse-sub 命令除 macOS GoEngine（已死）以外还有其他客户端吗（CLI、脚本）？没有的话 daemon 端可以一起删。
- 断线事件历史（reconnect-incidents.json）是否计划在 Release 的 UI 或诊断导出中展示？如果不展示，是否接受并入 ConnectionReport.events，或限定为 DEBUG 构建？
- ARCHITECTURE §5.4 说完整恢复“共享五次预算”，但唤醒或 adopted 会话丢失的恢复（AppState reconcile）不计入 TPM 预算。这是有意的吗？可以合并成单一恢复控制器吗？
- SSIDScenarioSelectionState.noteWiFiDisconnected 和 forceMatching 从未接线：断开后重新连上同一 SSID 时，是否应该清除手动选择？测试断言的是“会清除”。
- MenuBarTrackingRepair 自动改写 Control Center 偏好设置：Apple 在哪个 26.x 版本修复了这个 bug？是否接受改成用户显式触发并设退役条件？
- TransparentProxyManagerSelector 中按 localizedDescription 匹配的迁移兜底，对应的是哪个版本创建的 NE 配置？还需要保留吗？
- 是否愿意把 TPM、AppState 的协调逻辑放到协议后面并纳入 XDialTests？大规模合并恢复与状态之前，这是降低风险的前提。

### macOS 安装 / 更新 / 配置库 / 诊断

**P078　macOS 的 KeychainStore.swift 整个文件无调用方**　〔dead｜复核成立｜可删约 173 行〕

- 结论：macOS 的 KeychainStore.swift（173 行）在 App、扩展、SettingsDockUI 和测试 target 中都没有调用方，可以整文件删除；iOS/tvOS 用的是 appletv/XDialTV/KeychainStore.swift，那是另一份独立文件。
- 位置：macos/Sources/XDial/KeychainStore.swift:1-173
- 建议：直接删除文件。project.yml 按目录纳入源文件，不用改。
- 注意：①ExistingXDialProfileReader.swift:4-5 的注释提到 KeychainStore.loadVault()，需要同步改写。②XDialBuildIdentity.legacyApplicationIdentifier、formalUserDataDirectoryName、allowsFormalDataMigration 仍被 InstallationTransaction 和测试使用，不能随文件一起删除。③用户 defaults 里残留的 'xdial.migratedFromSandboxVaultV1' 键无害。④macos/XDial.xcodeproj 被 .gitignore 忽略，由 xcodegen 按目录生成，不需要手改。

**P079　旧刷新合并 ProfileRecord.refreshed(with:) 只被测试调用，约 130 行测试在测死代码**　〔dead｜复核成立｜可删约 190 行〕

- 结论：ProfileRecord.refreshed(with:)（ProfileLibrary.swift:34-114）和 preservingProfileOrder（200-208）只被测试调用。schema 3 的真实刷新路径是 ProfileLibrary.refreshing(profileID:incoming:)，GlobalConfiguration.swift 中还有一份等价的 ordered()。对应约 129 行旧测试在测死代码。
- 位置：macos/Sources/XDial/ProfileLibrary.swift:34-114；macos/Sources/XDial/ProfileLibrary.swift:200-208；macos/Tests/ProfileLibraryTests.swift:56-76；macos/Tests/ProfileLibraryTests.swift:115-127；macos/Tests/ProfileLibraryTests.swift:192-221；macos/Tests/ProfileLibraryTests.swift:241-286；macos/Tests/LineGroupSelectionTests.swift:35-56
- 建议：删除 refreshed 和 preservingProfileOrder。先把仍有价值的断言改写为针对 refreshing 的用例，再删旧测试。这类断言包括：组的 URL 与 interval 保留、固定成员被移除时拒绝、importWarnings 子集规则、本地场景出口覆盖。
- 注意：①refreshing() 中的「importWarnings 必须是子集」规则在 GlobalConfigurationTests 里没有任何覆盖（rg -i warning 无命中），删除 testRefreshRejectsNewUnsupportedRulesButRetainsReviewedOnes 前必须先补一条针对 refreshing 的用例。同样要迁移的还有：importAdjustments 保留（:254），以及带 grouped conditions、noResolve 的 ProfileRecord Codable 往返（:264-286）。②:264 的测试里还有 updateMatchingResource 的断言（与 P064 联动）。③旧测试中组 URL/interval、场景出口覆盖这类断言，在 schema 3 下组和场景已全局化，没有对等语义，不必迁移。

**P080　ProfileVaultProjection 及其测试是死代码**　〔dead｜复核成立｜可删约 165 行〕

- 结论：ProfileVaultProjection.swift（75 行）、ProfileVaultProjectionTests.swift（89 行）以及 project.yml:423 的测试源条目都是死代码，可以一起删除。
- 位置：macos/Sources/XDial/ProfileVaultProjection.swift:1-75；macos/Tests/ProfileVaultProjectionTests.swift:1-89；macos/project.yml:423
- 建议：删除源文件、测试文件以及 project.yml 中的这一行。
- 注意：无运行时风险。xcodeproj 由 xcodegen 生成，只需改 project.yml。

**P081　4 个旧路由迁移的 Swift 包装已被 DebugServer 用 409 封死，文档仍写成可用**　〔dead｜复核成立｜可删约 85 行〕

- 结论：ProfileDocumentService 里 4 个迁移包装函数（:5-14、:24-67）自 54585fe 起没有任何 Swift 调用方。DebugServer 只在 Next（Debug+XDIAL_NEXT_IDENTITY）配置下对这 4 个 action 返回 409；Debug 配置会落到 default 分支，返回 400 unknown action；Release 和 NextRelease 根本不编译 DebugServer。docs/agent/debug-server.md:77-103 仍把它们写成可用的保存流程。
- 位置：macos/Sources/XDial/ProfileDocumentService.swift:5-14；macos/Sources/XDial/ProfileDocumentService.swift:24-67；macos/Sources/XDial/DebugServer.swift:691-694；docs/agent/debug-server.md:76-104
- 建议：删除 4 个 Swift 包装和 409 分支，同步删除 debug-server.md 的第 76–104 行。Go 侧这 4 个函数及 profile-document-check 是否保留，不在本范围内，另行决定。
- 注意：文档实际范围是 77-103 行，不是 76-104。85 行由三部分组成：Swift 包装 54 行、DebugServer 4 行、文档 27 行。删掉 Swift 包装后，Libbox 导出仍在，tools/profile-document-check.swift 直接调用 Libbox，不受影响；Go 侧的去留按 P002 一起决定，最好放在同一个 PR。

**P082　零散死成员和只有测试用到的分支**　〔dead｜未复核｜可删约 75 行〕

- 结论：共 6 处。(1) PrivilegeManager.isHelperRunning 无调用方。(2) PrivilegeManager.requestRespawn 无调用方；Go 侧 cmd/xdial/daemon.go:246-263 的 respawn 命令因此也没有生产调用方。(3) AppUpdateFeedConfiguration.validatedAcceptanceID 无调用方。(4) ApplicationRelocator 的错误 InstallationError.backupCleanupFailed 从未被抛出。(5) HelperRegistrationCoordinator 的错误 Failure.legacyMigrationFailed 从未被抛出。(6) ApplicationBundleReplacer.replace 的 retainBackupForRecovery=false 分支和 beforeRemovingBackup 回调：生产唯一调用传的是 true，备份由 receipt 负责回收；InstallationTransactionTests 中有两个用例断言「替换后删除备份」，这个行为在生产中从不发生。
- 位置：macos/Sources/XDial/PrivilegeManager.swift:25-27；macos/Sources/XDial/PrivilegeManager.swift:665-668；macos/Sources/XDial/AppUpdateReleaseLookup.swift:94-100；macos/Sources/XDial/ApplicationRelocator.swift:1018；macos/Sources/XDial/ApplicationRelocator.swift:1068-1069；macos/Shared/HelperRegistrationCoordinator.swift:41；macos/Shared/HelperRegistrationCoordinator.swift:51；macos/Shared/InstallationTransaction.swift:477-537；macos/Tests/InstallationTransactionTests.swift:713-760
- 建议：删除这些成员。ApplicationBundleReplacer 固定为保留备份，去掉 retainBackupForRecovery 参数和 beforeRemovingBackup 回调，对应两个测试改成断言「保留备份」。Go 侧的 respawn 命令另行确认后再删。
- 注意：低。

**P083　范围外但属旧配置转换：AppState 的旧比喻 key 改写已无入口**　〔dead｜复核成立｜可删约 76 行〕

- 结论：AppState.swift:2702-2777 的比喻命名迁移（hasLegacyMetaphorKeys、rewriteLegacyMetaphorKeys、rewriteLegacyScenario，都是 private static）已经没有入口；唯一调用点 loadSaved 中的 Self.hasLegacyMetaphorKeys(raw) 在 ec2f29d 被删。
- 位置：macos/Sources/XDial/AppState.swift:2702-2777
- 建议：直接删除。如果仍担心比喻命名的旧 plist，就在 ExistingXDialProfileReader.restore 里加 4 行精确改名，而不是保留这段死代码。
- 注意：①没有经过 v0.5–v0.9 直接升级的比喻命名旧配置，会被 ExistingXDialProfileReader.restore 的 guard root["lines"] is [Any] 明确拒绝（报「尚不支持迁移，原配置已保留」），不会静默丢数据。②action 说可以用「4 行」补到 reader 里，这个估计偏低：还需要改写 scenario 内的 default_port_id 和 binding 内的 cargo_id/port_id。③与 P060、P152 的范围重叠，不要重复计数。

**P084　旧应用身份迁移（≤v0.7.0 → com.kafeifei.xdial.app）依赖旧二进制并不支持的参数，大概率从未生效**　〔legacy｜复核修正｜可删约 220 行〕

- 结论：旧身份迁移确实依赖旧二进制不认识的参数，但它不是“大概率从未生效”，按代码推理是必然失败：v0.7.0 及更早版本（com.kafeifei.xdial）和 ne-probe 包手动升级到 v0.7.1+ 时，会把旧版 App 完整启动一次，5 分钟后被强杀，安装失败。审计员的备选方案“改由新包自己清理旧组件”不可行。
- 位置：macos/Shared/InstallationTransaction.swift:348-474；macos/Sources/XDial/ApplicationRelocator.swift:432-454；macos/Sources/XDial/ApplicationRelocator.swift:906-924；macos/Sources/XDial/main.swift:74-107；macos/Sources/XDial/PrivilegeManager.swift:460-480；macos/Shared/XDialBuildIdentity.swift:31-40；macos/Shared/ApplicationInstallationOccupancy.swift:26-31；macos/Tests/InstallationTransactionTests.swift:426-626
- 建议：先向作者确认是否还要支持 ≤v0.7.0 原地升级。若不支持，删除旧标识替换许可、replacementArgument 及 main.swift 中的对应处理、unregisterForIdentityReplacement、Occupancy 里的旧名称，以及相关测试；旧 id 只保留在 ConfigurationStorage 和 ConfigurationDataDeletion（数据迁移与删除仍需要）。若仍要支持，改由新包自己执行旧组件清理（参照现有的 --prepare-helper-for-replacement），并在正式配置下补测试。
- 注意：(a) 新包（com.kafeifei.xdial.app）无法用 SMAppService 注销别的 App 登记的 com.kafeifei.xdial.helper，也删不了 owner-scoped 的 NE 配置（TransparentProxyManager.removeOwnedNetworkConfigurationsOnly 的注释写明了这一点），扩展停用请求也必须由所属 App 提交，所以审计员的“仍要支持”方案不可行。真想支持时，可行做法是调用 v0.7.0 二进制本来就支持的 --deactivate-owned-system-extension 停用扩展、删除 NE 配置，或者调用 --uninstall（会注销 helper，但会把旧包移进废纸篓，和备份/替换事务冲突）。(b) 如果从 permitsReplacement 去掉 legacyRelease/legacyProbe，v0.7.0 用户会落到 rejectExisting，看到“已有另一份签名或标识不同的 XDial”，canRetry=false，提示有误导。应改成明确的“请先卸载旧版 XDial 再安装”。(c) legacyApplicationIdentifier 不能删：KeychainStore.swift:73 和 ConfigurationStorage/ConfigurationDataDeletion 的数据迁移与卸载删除还在用。legacyHelperIdentifier 同时被 P086 的 cleanupLegacy 使用。(d) Plan/run/helperReplacementArgument 还要保留，--prepare-helper-for-replacement 在用；testOutgoingCleanupRunsExactBoundedOldHostCommand 等测试要改成直接构造 Plan，不能整段删除。(e) 一并删除的还有 settingsUIIdentifier 中的 legacy 两个 case、obsoleteIdentifiers（负责 LaunchServices 反注册）、platformComponentIdentifiers/requiresComponentCleanup（只剩 Debug 组件变更这一种用途）、Occupancy 中的 legacyTransparentProxyIdentifier。(f) 300 行的估计包含测试；保守按约 170 行源码加约 50 行可直接删除的测试计算。

**P085　为无 handoff 协议的旧 daemon 保留的空闲窗口迁移整条路径**　〔legacy｜复核修正｜可删约 130 行〕

- 结论：handoffProtocolVersion<1 的 125 秒空闲窗口路径只服务 v0.7.1–v0.7.3 的 daemon，而且实际可达范围比审计员说的更窄。审计员“删除后归为 serviceBusy”的兜底会造成无限等待，不能照做。
- 位置：macos/Shared/HelperRegistrationCoordinator.swift:31；macos/Shared/HelperRegistrationCoordinator.swift:59-62；macos/Shared/HelperRegistrationCoordinator.swift:77-78；macos/Shared/HelperRegistrationCoordinator.swift:173-184；macos/Shared/HelperRegistrationCoordinator.swift:319-340；macos/Sources/XDial/PrivilegeManager.swift:194-220；macos/Sources/XDial/PrivilegeManager.swift:251-262；macos/Sources/XDial/InstallationCoordinator.swift:281-288；macos/Sources/XDial/InstallationCoordinator.swift:344；macos/Tests/HelperRegistrationCoordinatorTests.swift:257-308
- 建议：确认已无 ≤v0.7.x 在用后，整条删除。之后若遇到旧 daemon，归为 serviceBusy 或提示重装。
- 注意：删除后遇到 handoffProtocolVersion<1 时，必须抛出一个终止性错误（例如提示“请先退出并卸载旧版后重装”），不能走 serviceBusy。Fixture.legacyDaemon 被删后，603 行附近的测试要改用别的错误 hash daemon。InstallationCoordinator.swift:344 的文案、Stage.waitingForLegacyIdle、Limits.legacyIdle 及注释要一起删。PrivilegeManager.registrationRuntime 的 `?? 0` 可以保留，作为判别旧协议的依据。

**P086　旧 /Library 特权 helper 清理仍在每次安装时执行，checkHelper 的理由已失效**　〔legacy｜复核修正｜可删约 50 行〕

- 结论：/Library 特权 helper 清理只服务 ≤v0.5.0，checkHelper 注释的“同 label”前提确实已经失效。但每次安装执行的只是文件存在性检查，AppleScript 只在有残留时才弹；“v0.1.0–v0.5.0 写 /etc/sudoers.d/xdial”这一条是错的。
- 位置：macos/Sources/XDial/PrivilegeManager.swift:11-12；macos/Sources/XDial/PrivilegeManager.swift:503-535；macos/Sources/XDial/PrivilegeManager.swift:604-608；macos/Sources/XDial/InstallationCoordinator.swift:255-258；macos/Sources/XDial/AppState.swift:2779-2786；macos/Sources/XDial/DebugServer.swift:140；macos/Sources/XDial/DebugServer.swift:825；macos/Shared/ApplicationInstallationOccupancy.swift:26-31
- 建议：现在就修正 checkHelper 的错误前提，删除 DebugServer 中的 legacyInstalled 字段。确认没有 ≤v0.5.0 用户后，把 cleanupLegacy、legacyInstalled、allowsLegacyCleanup 和 Occupancy 里的旧名称一并退役。runAdminShell 要保留，卸载删除 root 目录还在用它。
- 注意：“现在就修正 checkHelper 的错误前提”只能改注释（改成“残留存在时引导走安装流程以触发一次性清理”），不能删掉短路，否则残留用户永远不会触发清理。sudoers 的 rm 可以无条件删掉。删除 allowsLegacyCleanup 要同步改 XDialBuildIdentityTests 第 53/106/140 行。Occupancy 中的 legacyTransparentProxyIdentifier 属于 v0.7.0 身份（P084），不属于 /Library 模型，两者现在由同一个 allowsLegacyCleanup 门控，退役时要分别处理。

**P087　Next 的 --import-xdial-debug 命令行属于隔离库时代，已被共享库自动转换取代**　〔legacy｜复核修正｜可删约 25 行〕

- 结论：--import-xdial-debug 写入分支确实是隔离库时代的遗留（只编进 Next）；但隔离期是 09-14~09-18，不是 09-14~09-23；而且审计员高估了可删行数，测试只能改写，不能删。
- 位置：macos/Sources/XDial/main.swift:13-52；macos/Sources/XDial/ProfileDocumentService.swift:69-72；macos/Sources/XDial/ExistingXDialProfileReader.swift:7-14；macos/Sources/XDial/ExistingXDialProfileReader.swift:108-110；macos/Tests/ExistingXDialProfileReaderTests.swift:17-83
- 建议：删除写入分支。check 分支若仍需要，改为调用 ExistingXDialProfileReader.read，传入 desktopLocations 中的 debug 项，从而去掉 readDebug、readDebugKeychainVault、importExistingDebug 这些特化函数；测试改为针对 read。
- 注意：测试必须改成直接调用 read(source, home:, keychainVault:)，不能删除，否则首转读取路径就没有测试了。check 分支仍有文档记载；如果保留，main.swift 只能删掉写入相关的约 12 行。convertLegacyProfile 还被 AppState+Profiles.swift:85 使用，不能一起删。

**P088　配置迁移与 seed 新功能缠在一起：首建库仍借 schema 2 晋升，Migration 文件六成是企业 seed 功能**　〔accretion｜复核修正｜可删约 30 行〕

- 结论：三处缠绕基本属实，但时间窗口和 needsSchemaBackup 的服务对象说错了；第三点只是文件拆分，删不掉代码。
- 位置：macos/Sources/XDial/ProfileLibraryMigration.swift:7-46；macos/Sources/XDial/ProfileLibraryMigration.swift:49-140；macos/Sources/XDial/ProfileLibraryMigration.swift:142-213；macos/Sources/XDial/ProfileLibraryStore.swift:15；macos/Sources/XDial/ProfileLibraryStore.swift:35；macos/Sources/XDial/ProfileLibraryStore.swift:72-77；macos/Sources/XDial/ProfileLibrary.swift:162-184；macos/Tests/ProfileLibraryMigrationTests.swift:75-97；macos/Tests/ProfileLibraryMigrationTests.swift:172-348
- 建议：改为由 library(with:) 直接构造 v3（场景与组提升到库级）。然后删除 pre-shared 库分支和 needsSchemaBackup，只保留单份旧 Profile 的转换。把 seed 相关代码拆到 SeedProfile.swift，测试也拆成独立文件。
- 注意：ARCHITECTURE.md §6 明确写了“只读复制历史库”，§顶部写了“旧库升级前保留加密原件”，删除前要同步改文档。这些文件只存在于作者或自行从源码构建者的机器上，删除前应确认作者本机的共享库已是 schema 3。只有在 library(with:) 改为直接构造 v3 之后，promoteEmbeddedObjects（约 32 行）、validated() 的 schema<3 分支和 decoder 的兼容字段才能一起退役，否则 seed 与旧单 Profile 转换会坏掉。seed 拆文件是净零行的重组。

**P089　两个维护用命令行入口从未有程序调用**　〔dead｜复核修正｜可删约 55 行〕

- 结论：两个参数在仓库任何版本中都没有调用方，这一点属实。但它们不是“人工排障入口”，而是 v0.7.0 为“后继版本调用旧身份二进制做清理”设计的跨版本清理接口；bb53e99 换身份时没用它们，另起了旧二进制不认识的新参数，这正是 P084 的根因。
- 位置：macos/Sources/XDial/main.swift:109-158；macos/Sources/XDial/TransparentProxyManager.swift:649-658
- 建议：向作者确认是否仍作人工排障用。不用就删除这两个分支以及只为它们存在的 TransparentProxyManager 方法。
- 注意：从当前代码删掉这两个参数，不影响已发布的 v0.7.0 二进制自带的处理。但删除前应先定下 P084 的处理方式：如果决定继续支持 v0.7.0，要在新包这边调用 v0.7.0 的 --deactivate-owned-system-extension，而不是删除当前代码中的同名处理。removeOwnedNetworkConfigurations（private）仍被 uninstallSystemExtension 使用，不能删。--uninstall 有 prepareCommandLineUninstall 等实现，应保留。

**P090　UNIX socket 连接代码手写了 4 份**　〔duplication｜未复核｜可删约 45 行〕

- 结论：PrivilegeManager 的 LocalDaemonConnection.init 和 canConnectSocket 连同一个 socketPath，各自完整手写一遍 socket()、strncpy(sun_path, 104)、connect；SiblingProductProcessIdentity.socketPeer 写了第三份（非阻塞，读 LOCAL_PEERPID 和 peereid）；GoEngine.openSocket 写了第四份。读取 LOCAL_PEERPID 的代码也有两份。
- 位置：macos/Sources/XDial/PrivilegeManager.swift:688-720；macos/Sources/XDial/PrivilegeManager.swift:777-795；macos/Shared/SiblingProductProcessIdentity.swift:41-68；macos/Sources/XDial/GoEngine.swift:776-805
- 建议：抽出一个 UnixSocket 小工具，提供 connect(path:timeout:nonBlocking:)、peerPID 和 peerUID。canConnectSocket 直接改为「LocalDaemonConnection(timeout:) 不为 nil」。
- 注意：低。注意保留各自的阻塞与超时语义：Sibling 必须非阻塞，GoEngine 是长连接。

**P091　安装与 helper 代码里的小块重复**　〔duplication｜未复核｜可删约 35 行〕

- 结论：共 4 处。(a) ApplicationRelocator.installApplicationFiles 中，「用新包子进程执行 --prepare-helper-for-replacement，失败转成 helperReplacementPreparationFailed」整块复制了两次。(b) 注销 SMAppService.mainApp 的代码在 ApplicationUninstaller 和 PrivilegeManager.unregisterForIdentityReplacement 中各写一份。(c) "xdial.installation.ready" 在 InstallationCoordinator 里是 private 常量，ApplicationUninstaller 又写了一遍字面量。(d) 「某进程是否属于本产品包」有三套规则：LocalProcessInventory.belongsToProductBundle（PrivilegeManager 两处以完全相同的参数调用）、ApplicationInstallationOccupancy.mayBeInUse（按名称表判断）、HelperUninstallCoordinator.ownedDaemonProcesses（按可执行路径判断）。
- 位置：macos/Sources/XDial/ApplicationRelocator.swift:455-466；macos/Sources/XDial/ApplicationRelocator.swift:485-497；macos/Sources/XDial/ApplicationUninstaller.swift:33-39；macos/Sources/XDial/PrivilegeManager.swift:461-466；macos/Sources/XDial/InstallationCoordinator.swift:38；macos/Sources/XDial/ApplicationUninstaller.swift:47-49；macos/Sources/XDial/PrivilegeManager.swift:175-207；macos/Shared/ApplicationInstallationOccupancy.swift:3-40；macos/Shared/HelperUninstallCoordinator.swift:116-143
- 建议：(a) 提取 runHelperTeardownChild()。(b) 共用一个 unregisterMainAppService()。(c) 公开 completionMarkerKey 常量。(d) 先不合并，在一处写清三种判定的差异和各自的事故来源，再评估能否收敛。
- 注意：(d) 的三套规则都是事故驱动的，合并前必须逐条对照 docs/incidents。

**P092　ApplicationRelocator 一个 1102 行静态枚举承担约 10 类事务**　〔mixed-responsibility｜未复核｜可删约 20 行〕

- 结论：它同时负责：启动时重定位决策与替换事务（246-551）、包签名与组件身份校验（810-995）、自动更新包校验（59-138）、卸载（154-180）、误拼 Debug 路径的接管与退役（182-238）、旧临时文件回收（552-651）、LaunchServices 注销（653-672）、重启与交接判定（674-741）、进程终止（743-808），以及 26 个错误及其中文文案（1005-1101）。更新包校验还对 bundle 标识做了三重检查：permitsAutomaticUpdates、validateDistributionBundle 里的 permitsIncomingInstallation、AutomaticUpdateBundlePolicy.permits。
- 位置：macos/Sources/XDial/ApplicationRelocator.swift:59-138；macos/Sources/XDial/ApplicationRelocator.swift:154-238；macos/Sources/XDial/ApplicationRelocator.swift:246-551；macos/Sources/XDial/ApplicationRelocator.swift:552-672；macos/Sources/XDial/ApplicationRelocator.swift:743-995；macos/Sources/XDial/ApplicationRelocator.swift:1005-1101
- 建议：按职责拆开：BundleSignatureValidator 只做校验；ApplicationReplacementTransaction 负责替换、回收与交接；AppUpdateBundleValidator 移到更新模块，并合并三重身份检查；卸载部分并入 ApplicationUninstaller。误拼路径接管等开发机迁移完成后删除。
- 注意：这条路径在 AppState 之前、由 main.swift 同步调用，拆分后不能引入 MainActor 或 AppState 依赖。替换与回滚的顺序是事故修复点，移动代码时不能改语义。

**P093　PrivilegeManager 混杂注册 IO、拆除、卸载、旧版清理、daemon 客户端和连接报告转发**　〔mixed-responsibility｜未复核｜可删约 0 行〕

- 结论：845 行同时承担：SMAppService 注册 IO 与维护意图编排（29-130、222-430）；helper 拆除（539-602）；卸载与删除 root 数据（604-621）；旧 /Library 清理（503-535）；旧身份注销（460-480）；daemon socket 客户端（671-795）。此外，probeProviderConnectionReport 通过 helper 转发扩展的 ConnectionReport，供 TransparentProxyManager.swift:2661 使用，属于连接事务而不是权限管理。只给 DebugServer 用的原始 register() 和 unregister() 绕过了安装事务，unregister() 还不经过 mutation gate，与 HelperRegistrationCoordinator 注释里「安装拥有注册」的原则相冲突。
- 位置：macos/Sources/XDial/PrivilegeManager.swift:29-130；macos/Sources/XDial/PrivilegeManager.swift:222-480；macos/Sources/XDial/PrivilegeManager.swift:503-621；macos/Sources/XDial/PrivilegeManager.swift:650-795；macos/Sources/XDial/DebugServer.swift:792-817
- 建议：拆出 DaemonControlClient，负责 socket、daemon-info 和 connection-report；拆出 HelperRegistrationIO，只实现两个 Coordinator 的 IO 接口。legacy 部分随问题 8、9 一起退役。DebugServer 的 sm-register 和 sm-unregister 改为走 InstallationCoordinator，或者直接删除。
- 注意：unregister 完成屏障、mutation gate 与租约的时序都是事故修复点，移动代码时必须保持语义不变。

**P094　只给宿主用的安装、更新、helper 代码放在 Shared，被编进以 root 运行的 Network Extension**　〔boundary-violation｜复核成立｜可删约 0 行〕

- 结论：XDialTransparentProxy 编译整个 Shared 目录（project.yml:71-73），其中 16 个只给宿主用的文件（约 2,155 行）被编进了系统扩展。这些文件包括 InstallationTransaction、HelperRegistration* 三个、HelperUninstallCoordinator、ApplicationInstallation* 三个、ApplicationReplacementExitWaiter、LocalProcessInventory、SiblingProductProcessIdentity、ServiceManagementErrorDiagnostics、InstallationReportSnapshot、ApplicationBundleInfo、RuleSetPresetCatalog、JSONValue。扩展对它们的引用为 0，它们之间只互相依赖，形成一个封闭簇，所以可以整体移出。
- 位置：macos/project.yml:68-74；macos/project.yml:131-138；macos/project.yml:401-406
- 建议：新建 macos/HostShared，或把这些文件移回 Sources/XDial，并把该目录加入 XDialTests 的 sources。Shared 只保留扩展与宿主真正共用的类型。
- 注意：移动文件时有三个隐患。(1) Makefile:441 的 test-profile-document-bridge 用 swiftc 直接编译 macos/Shared/JSONValue.swift 和 Models.swift，JSONValue 搬走后路径必须同步修改。(2) Makefile:206-207 的门禁以 macos/Sources/XDial 和 macos/Shared 作为搜索根（willSleepNotification 归属、禁止 screensDidSleepNotification）。新建 HostShared 目录时如果不加进去，门禁会静默变弱。(3) XDialTests 列出的 Models.swift 依赖 JSONValue，搬走后要在测试 sources 中补上新目录。

**P095　通道身份常量和凭据字段清单各自手抄多份**　〔duplication｜未复核｜可删约 30 行〕

- 结论：(a) 通道身份：XDialBuildIdentity.installedChannels 把各通道的 id、bundleName、socket 又手写了一遍；updateStagingDirectoryName 和 installationArtifactPrefix 靠字符串比较 "com.kafeifei.xdial.next"；XDialApplicationIdentifierPolicy.settingsUIIdentifier 硬编码了 Next 的映射；ConfigurationStorage.desktopLocations、ConfigurationDataDeletion.applicationIdentifiers 和 ExistingXDialProfileReader 又各写一份。Go 侧 cmd/xdial/identity.go 另有一份（不在本范围）。(b) 凭据字段有 4 份清单：DebugStateRedactor.secretKeys（实际是 Go schema 的 JSON tag 名）、Line.credentialFields、ExistingXDialProfileReader.restore 的 vault 后缀映射、main.swift 导入时的凭据计数。新增协议凭据时漏改任何一处，就会导致 Debug /state 泄露凭据，或 seed 刷新丢失凭据。
- 位置：macos/Shared/XDialBuildIdentity.swift:139-165；macos/Shared/InstallationTransaction.swift:369-378；macos/Sources/XDial/ConfigurationStorage.swift:19-35；macos/Sources/XDial/ConfigurationDataDeletion.swift:6-9；macos/Sources/XDial/ExistingXDialProfileReader.swift:10；macos/Sources/XDial/DebugStateRedactor.swift:5-10；macos/Sources/XDial/ProfileLibraryMigration.swift:196-213；macos/Sources/XDial/ExistingXDialProfileReader.swift:84-93；macos/Sources/XDial/main.swift:36-39
- 建议：用一张 InstalledChannel 表派生 installedChannels、旧数据位置和删除集合。凭据字段只在 Line 上维护一份清单（或使用 Go 导出的敏感字段表），由它派生脱敏规则和 keepingCredentials。
- 注意：低。

**P096　更新链路的局部过度设计：文件名不副实、三份同构结构、两套版本比较、十参数策略函数**　〔over-engineering｜未复核｜可删约 80 行〕

- 结论：先说结论：更新链路的切分是合理的，不重叠。Lookup 负责获取清单与缓存，Transaction 是模型与策略，另有 Downloader、Stager、Checker（状态机）和 View，大部分复杂度来自 updates.md 的明文合同。可以收紧的点有 4 个。(1) AppUpdateTransaction.swift 里没有事务，装的是候选模型、选择、归档与下载策略、阶段枚举、重启意图存储和包身份策略。(2) 同一条 9 字段的发布记录有三份结构：AppUpdateFeedRelease、私有 WireRelease、AppUpdateReleaseCandidate；FeedRelease 和 FeedManifest 声明了 Codable 却从不编解码，缓存存的是原始字节，读出后重新 parse。(3) 版本解析与比较有两套：VersionUpdatePolicy.NumericVersion 与 AppUpdateReleasePolicy.NumericSystemVersion 逐行同构；另外还有一个只给 DebugServer fake-update 用的宽松 stableVersion。(4) AutomaticUpdateBundlePolicy.permits 和 permitsVersionSet 分别有 10 个和 8 个 String 参数，测试因此大段重复实参。
- 位置：macos/Sources/XDial/AppUpdateTransaction.swift:1-424；macos/Sources/XDial/AppUpdateReleaseLookup.swift:3-21；macos/Sources/XDial/AppUpdateReleaseLookup.swift:155-255；macos/Sources/XDial/AppVersion.swift:22-91；macos/Sources/XDial/AppUpdateTransaction.swift:134-166；macos/Sources/XDial/AppUpdateTransaction.swift:369-424
- 建议：把 AppUpdateTransaction.swift 改名为 AppUpdateModels 或 AppUpdatePolicy。解码直接得到单一的 Release 类型，删掉多余的 Codable。合并两套数字版本比较，去掉 stableVersion。策略函数的入参改为 BundleFacts 结构体。
- 注意：低。合同测试保持不变即可。

**P097　AppUpdateCheckerTests 价值不虚，但格式冗长且一个文件覆盖六个模块**　〔test-bloat｜未复核｜可删约 350 行〕

- 结论：1658 行、30 个用例、125 个断言，覆盖 Lookup、Policy、Downloader 策略、Stager、RelaunchIntent、Checker 六个模块。被测的非 UI 源码约 2,430 行，又是「下载并执行签名代码」的安全路径，所以测试价值本身并不膨胀，也几乎没有在测死代码。膨胀来自格式：968 行（58%）短于 40 个字符，基本是一参一行；10 参数策略函数的每个正例、反例各占约 15 行；文件名也只对应 Checker 一个模块。
- 位置：macos/Tests/AppUpdateCheckerTests.swift:1-1658；macos/Tests/AppUpdateCheckerTests.swift:999-1105
- 建议：按模块拆成 ReleaseLookupTests、ReleasePolicyTests、StagerTests、CheckerTests 等文件，策略类改为表驱动。不删用例。
- 注意：低。

**P098　DebugServer 可以小幅修剪；tools/inspector.swift 已失效并与 /ax 重复**　〔accretion｜未复核｜可删约 260 行〕

- 结论：DebugServer 的 1054 行都在 #if DEBUG 内，Release 和 NextRelease 不包含。它是 Debug 验收以及 make restart 依赖的诊断面（scripts/restart-macos-app.sh:127 调用 quit），整体是必要的。可以修剪的有 4 处：问题 4 里的 409 死分支；三个 Provider 诊断 action 复制了同一段 connected 加 committed 守卫；404 和 default 分支各有一份过期的 action 清单，都漏了 prepare-system-extension、quit、sm-*、application-attribution-snapshot 等；sm-register 和 sm-unregister 绕过安装事务直接改注册。另外，tools/inspector.swift（209 行，对应 Makefile 的 inspector 目标）是 /ax 的前身，硬编码的 bundle id 是 "com.kafeifei.xdial"（v0.7.1 起已不存在），端口是 19876，最后一次修改在 v0.4.1，现在无法找到任何运行中的 XDial。
- 位置：macos/Sources/XDial/DebugServer.swift:76-84；macos/Sources/XDial/DebugServer.swift:513-523；macos/Sources/XDial/DebugServer.swift:571-580；macos/Sources/XDial/DebugServer.swift:620-630；macos/Sources/XDial/DebugServer.swift:792-817；macos/Sources/XDial/DebugServer.swift:838-843；tools/inspector.swift:1-209；Makefile:431-433
- 建议：删除 tools/inspector.swift 和 Makefile 的 inspector 目标。DebugServer 中抽出 requireCommittedTransaction() 守卫；只保留一份 action 清单，由同一处生成 404 和 default 的提示；sm-register 和 sm-unregister 改走安装事务，或者删除。
- 注意：低。注意 Makefile 里针对 DebugServer.swift 的 5 条 rg 结构检查需要同步更新。

需要作者回答的问题：

- 是否有下载统计或用户反馈能判断：还有用户停留在 ≤v0.5.0（/Library helper）、v0.7.0（com.kafeifei.xdial 身份）或 v0.7.x（daemon 没有 registration-handoff 协议）？问题 7、8、9 能否整体退役取决于这一点。
- 从 v0.7.0 升级到 v0.7.1 及以后的版本，是否实际成功过？当前代码要求旧包认识 --prepare-owned-components-for-replacement，但 v0.7.0 的 main.swift 里没有这个参数。
- --deactivate-owned-system-extension、--remove-owned-network-configurations、--uninstall 三个命令行入口，是否仍作为人工排障或卸载手段使用？仓库及所有历史 tag 中都没有程序调用。
- 作者本机以外，是否有 Next 测试者持有 2026-09-14~23 生成的 ~/.xdial-next/profiles.enc（schema 1/2）？next-v* 发布是否早于 54585fe？如果都没有，pre-shared 库迁移和 schema 备份可以删除。
- 共享库上线后，Next 的 --import-xdial-debug 和 --check-xdial-debug-import 还需要保留吗？
- 用户在 Finder 中直接覆盖 /Applications/XDial.app、绕过替换事务，是否属于要支持的场景？如果不是，HelperRegistrationCoordinator 的「注册仍指向旧包 → 租约刷新」路径与替换前的 teardown 有部分重叠，可以评估简化。
- Go 侧 cmd/xdial/daemon.go 的 respawn 命令，以及 core/libbox 的 4 个旧路由迁移函数（现在只被 tools/profile-document-check 使用），是否还需要？
- 误拼的「XDail Debug.app」接管（2026-10-13 引入）在你所有开发机都迁移完成后，可以删除吗？

### macOS UI

**P099　Popover 失败摘要靠匹配错误字符串猜类别，违反 DESIGN §4.4**　〔boundary-violation｜未复核｜可删约 30 行〕

- 结论：failurePresentation 用 localizedCaseInsensitiveContains 匹配 SERVFAIL、"lookup "、"context deadline exceeded"、"timed out"、"connection refused"、"certificate"、"tls handshake" 来生成“服务器域名解析失败/连接超时/TLS 验证失败”等结论。DESIGN §4.4 写明“摘要由 error code、task/resource 与 layer 生成……不靠错误字符串或日志猜类别”。ConnectionReportError 已有 code、taskID、evidence 字段。另外 LineLatencyPresentation 用 failure.contains("超时") 区分超时，属同类问题（程度较轻）。
- 位置：macos/Sources/XDial/MainPopover.swift:1161-1221；macos/Sources/XDial/LineLatencyView.swift:57；macos/Shared/ConnectionTransaction.swift:538-560
- 建议：由 Go/事务层输出结构化 error code（或在 ConnectionReportError.code 上补齐 dns/timeout/refused/tls 类别），Swift 只做 code 到文案的映射；删除字符串匹配分支。
- 注意：需要 Go 侧补 code；过渡期如果 code 缺失，统一回退为“连接失败”加原始错误全文（DESIGN 要求的原始错误仍完整展示）。

**P100　Tailscale 登录编排写在 LineRow 视图里，iOS 则放在 AppState**　〔mixed-responsibility｜未复核｜可删约 50 行〕

- 结论：LineRow 自己维护 busy/error 状态机：prepareTailscale → 已登录则结束，否则 beginTailscaleLogin → 校验 authURL 为 https → NSWorkspace.open → startTailscaleConfigurationPolling，外加 logout 与 requireInstallation。视图直接调用 state.engine.prepareTailscale/beginTailscaleLogin/logoutTailscale/stopTailscaleSetup。Tailscale 状态文案还有三份重叠推导：tailscaleStatusColor、tailscaleStatusLabel、lineBriefInfo 的 tailscale 分支，措辞不一致（“尚未检查”与“登录状态未检查”）。iOS 把同一流程放在 AppState.beginTailscaleLogin/logoutTailscale，并在 ios/XDialIOSTests/AppStateTests.swift 中测试；macOS 的 SettingsView 不在 XDialTests 编译清单（macos/project.yml:401-450），这段逻辑没有单测。
- 位置：macos/Sources/XDial/SettingsView.swift:754-768；macos/Sources/XDial/SettingsView.swift:847-878；macos/Sources/XDial/SettingsView.swift:1158-1294；macos/Sources/XDial/SettingsView.swift:2837-2873；macos/Sources/XDial/SettingsView.swift:541-543
- 建议：抽出 AppState（或 TailscaleLineSetupController）的 beginLogin/registerAuthKey/logout/refresh 意图，以及一个 TailscaleLinePresentation（label/color/brief），三处共用；视图只绑定按钮。
- 注意：Makefile test-macos-transaction 有 grep 守卫：SettingsView 的 onAppear/onDisappear 中不得出现 prepareTailscale（Makefile:239），迁移时要保持“打开编辑器不登录”的不变量。

**P101　Popover 场景动作状态机、进度投影与映射重建都在视图里，且三处重复判定**　〔mixed-responsibility｜未复核｜可删约 40 行〕

- 结论：visualState(for:)、performScenarioAction、actionHelp 各自重新判断 scenarioSwitchTargetID、currentRuntimeScenarioID、isConnected、isBusy，相当于把 DESIGN §4.2 的决策表写了三遍。actionHelp 没有像另外两处那样比较 scenarioSwitchTargetProfileID（目前因 profileID 恒等而无实际差异）。connectionProgressReport/connectionProgress/taskProgress/completedTaskCount 是事务进度投影；policyMappings 从配置重建 RuleSet→Line。上述逻辑都不在测试 target 中。
- 位置：macos/Sources/XDial/MainPopover.swift:1255-1325；macos/Sources/XDial/MainPopover.swift:1390-1507；macos/Sources/XDial/MainPopover.swift:1530-1615
- 建议：新增纯函数 ScenarioActionPolicy(state snapshot) → (visual, action, help)，以及 ConnectionProgressProjection，放入可测文件并纳入 XDialTests；视图只渲染。
- 注意：Makefile:232-233 用 rg 要求 MainPopover.swift 中出现 state.dismissScenarioSwitchFailure( 且不得有 @State dismissedScenarioSwitchFailure，移动代码时要同步守卫。

**P102　SettingsView.swift 是 2957 行、15 个类型的单文件，可按职责拆出**　〔mixed-responsibility｜未复核｜可删约 0 行〕

- 结论：可拆出的块：① 拖动排序基础设施 1-172 → SettingsReorder.swift（ScenarioBindingList 也在用）；② 窗口外壳、顶栏与待应用状态轨 174-403；③ LinesTab 407-578 及 NativeLinesView 2911-2957 → LinesTab.swift；④ RuntimeResourcePresentation 580-719 → 与 Popover 合并的任务状态呈现；⑤ LineRow 721-1570（其中 Tailscale 954-1294 → TailscaleLineSection，AnyTLS 1296-1492 → AnyTLSFields，表单帮助函数 1494-1569）；⑥ RulesTab/RuleSetRow/ApplicationRulePicker 1572-2083 → RuleEditor.swift；⑦ ScenariosTab/ScenarioRow/SSID 布局/图标选择器 2085-2834 → ScenarioEditor.swift；⑧ lineBriefInfo/lineTypeLabel 2836-2909 → LinePresentation。拆分本身不减少行数，但它是后续去重与下沉逻辑的前提。
- 位置：macos/Sources/XDial/SettingsView.swift:1-172；macos/Sources/XDial/SettingsView.swift:174-403；macos/Sources/XDial/SettingsView.swift:407-578；macos/Sources/XDial/SettingsView.swift:721-1570；macos/Sources/XDial/SettingsView.swift:1572-2083；macos/Sources/XDial/SettingsView.swift:2085-2834；macos/Sources/XDial/SettingsView.swift:2836-2957
- 建议：先做纯移动拆分（无行为变化），再依次处理本列表中的去重与下沉问题。
- 注意：Makefile:239 对 SettingsView.swift 有文本守卫，需改为对新文件路径生效；SettingsLayoutPreview 依赖 SettingsView 的公开类型。

**P103　状态带脚手架复制 6 份，dirtyConfigurationBlocker 原样复制两份**　〔duplication｜未复核｜可删约 140 行〕

- 结论：proxyOnlyBand、connectionBlockerBand、ssidAccessWarningBand、dirtyStatusRow/statusBand 背景、scenarioSwitchFailureBand 都是同一结构：HStack(图标 + 标题/说明 VStack + Spacer + 按钮) + padding(.leading 20/.trailing 14) + 双色 LinearGradient；SettingsView.dirtyBanner 又写了一份。dirtyConfigurationBlocker 在两个文件中逐字相同，它自行猜测 canConnect 为 false 的原因（安装/未选场景/“请先完善当前场景”），没有使用已有的结构化 ConnectionConfigurationBlocker，也漏掉 profileLibraryLoaded/profilePersistenceError 两种原因。DESIGN §5.6 要求设置页状态轨“文案与 Popover 一致”，但英文分别是 “Saved changes are not applied” 和 “Changes saved; the current connection has not applied them”。
- 位置：macos/Sources/XDial/MainPopover.swift:266-319；macos/Sources/XDial/MainPopover.swift:532-625；macos/Sources/XDial/MainPopover.swift:627-749；macos/Sources/XDial/MainPopover.swift:751-814；macos/Sources/XDial/MainPopover.swift:834-845；macos/Sources/XDial/SettingsView.swift:282-360；macos/Sources/XDial/AppState.swift:427-435
- 建议：抽出 StatusBand(icon,tint,title,detail,action) 组件；在 AppState 增加 connectBlockReason（枚举）取代视图猜测；两处共用同一份待应用文案。
- 注意：仅呈现层改动；需要截图核对 Popover 高度与间距没有变化。

**P104　折叠线路行头 AppKit 与 SwiftUI 各实现一份，已经发生漂移**　〔duplication｜未复核｜可删约 40 行〕

- 结论：SettingsLineTable.NativeHeader 用 AppKit 重画折叠行（徽标、名称、地址、延迟、类型、来源、开关、复制、删除），LineRow 的 CollapsibleCard header 用 SwiftUI 再画一遍（展开时显示）。7c1caa5（2026-10-13，预置 Profile 允许用户填凭据）只改了 SwiftUI 头的来源标签（“预置/订阅/自建”），NativeHeader 仍显示 value.sourceOwned ? "订阅" : "自建"，所以同一条预置线路折叠时显示“订阅”、展开后显示“预置”。NativeHeader 的无障碍标签“删除线路”“复制为自建副本”“启用”“展开 ”是写死的中文。
- 位置：macos/Sources/XDial/SettingsLineTable.swift:280-424；macos/Sources/XDial/SettingsLineTable.swift:375；macos/Sources/XDial/SettingsView.swift:771-803；macos/Sources/XDial/SettingsView.swift:2919-2930
- 建议：把来源标签、可删/可启停判定放进 SettingsLineTable.Summary，由一个函数生成；展开态的 SwiftUI 头复用这份 Summary，或者展开态只显示编辑区，不再重画头部。
- 注意：SettingsLineTableTests 对 NativeHeader 的无障碍标签有断言（"删除线路"/"复制为自建副本"），改本地化时要同步测试。

**P105　ConnectionTaskState → 文案/图标/颜色映射写了两份，词汇与颜色不一致**　〔duplication｜未复核｜可删约 50 行〕

- 结论：SettingsView 的 RuntimeResourcePresentation 与 MainPopover 的 progressStepSymbol/Color/StateText 分别映射同一个 ConnectionTaskState：running 一处是“检查中”、一处是“进行中”；committed 是“已接管”与“已提交”；rollingBack 是“正在回滚”与“回滚中”，颜色一处 selection、一处 secondary；图标也不同（clock.fill 与 ellipsis）。DESIGN §3 要求“同一状态在各窗口保持一致”。
- 位置：macos/Sources/XDial/SettingsView.swift:594-719；macos/Sources/XDial/MainPopover.swift:1327-1388
- 建议：建立一个 ConnectionTaskStatePresentation（label/symbol/color），放入可测文件；资源徽标只额外处理 disabled/notObserved/notPlanned 三个非任务态。
- 注意：低；文案统一需要产品确认用哪套词。

**P106　ProfileManagementView 执行领域操作，并在 Swift 中复制 Go 的导入常量**　〔boundary-violation｜未复核｜可删约 25 行〕

- 结论：perform() 在视图里构造 empty/copy/import 的 ProfileRecord，设置 source/baseline/resourceIDs，执行 NSSavePanel 写文件；chooseFile 自己做 4 MiB/UTF-8 校验；save() 自己校验 HTTPS URL。importDetails 用 URL 前缀判断 GEOIP/ASN 来源（GEOIP 与 ASN 公开规则集的固定地址前缀），这两个前缀是 Go 的 importedGeoIPURL/importedASNURL 常量；adjustment code "anytls-tfo-disabled" 也写死在视图里。4 MiB 限制在 Swift 中出现 4 处，Go 中还有 1 处。
- 位置：macos/Sources/XDial/ProfileManagementView.swift:297-312；macos/Sources/XDial/ProfileManagementView.swift:388-416；macos/Sources/XDial/ProfileManagementView.swift:419-489；core/config/subscription_profile.go:160-161；core/config/profile_document.go:77
- 建议：把新建/复制/导入/导出意图移到 AppState+Profiles 或 ProfileDocumentService（文件读取共用一个 bounded reader）；让 Go 为 GEOIP/ASN 来源输出 ImportAdjustment code，Swift 只按 code 显示文案。
- 注意：导入流程涉及 Keychain 与配置库写入，需要保留 ProfileLibraryTests 覆盖；Go 新增 code 后要同步 iOS/tvOS 的解码。

**P107　Profile 内 Subscription（sub:）出口目标是 schema v3 之后不可达的遗留**　〔legacy｜复核成立｜可删约 30 行〕

- 结论：schema 3 下，state.profile 和 editingProfile 都来自 ProfileLibrary.snapshot()，subscriptions 恒为空，validateReferences 也禁止 subscriptionID。因此 macOS UI 中的 sub: 选项、selectedName 的 sub: 分支、allowsSubscriptions 参数、policyTargetName 的订阅分支、moveSubscription 都不可达。Models 中的解码字段必须保留。
- 位置：macos/Sources/XDial/LineTargetPicker.swift:8-16；macos/Sources/XDial/LineTargetPicker.swift:45-47；macos/Sources/XDial/MainPopover.swift:1576-1588；macos/Sources/XDial/SettingsView.swift:564-577；macos/Sources/XDial/SettingsView.swift:1920-1925；macos/Sources/XDial/AppState.swift:2794-2808；macos/Sources/XDial/GlobalConfiguration.swift:343-349；macos/Sources/XDial/ProfileLibrary.swift:173
- 建议：删除 macOS UI 的 sub: 分支、allowsSubscriptions、moveSubscription、AppState.addSubscription/updateSubscription；视迁移需要保留 Models 中的解码字段。之后可评估去掉 port: 前缀编码。
- 注意：①RuleBinding.subscriptionID、Scenario.defaultSubscriptionID、Profile.subscriptions 的 Codable 字段要保留：它们用 decodeIfPresent 解码，配置库在各版本间共享，已发布的旧版本可能依赖这些键。②去掉 port: 前缀是安全的：targetID 的 setter 本来就接受裸 lineID（Models.swift:670），但要同时修改 SettingsView:1921-1922 和 LineTargetPicker 的 selectedLine。③AppState.add/updateSubscription 与 P060 重叠，这里的 30 行只计 P107 独有部分；含重叠约 50 行。

**P108　全局配置迁移后残留的恒值开关和多 Profile 运行判断**　〔legacy｜未复核｜可删约 35 行〕

- 结论：schema v3 之后 activeProfileID 恒为 "global-configuration"，runtimeRecord.id 也恒为该值，Profile 内不再有线路组，library.groups 全部 isGroup。于是：editingActiveProfile 恒为 true（4 处使用）；ScenarioRow.sourceOwned 恒为 false（控制删除按钮与 .disabled）；LineGroupRow.readOnly 恒为 false，其“订阅/本地”标签永远显示“本地”，即使组来自订阅；MainPopover.currentRuntimeScenarioID 中 browsingRecord.id == activeProfileID 恒真，visualState/performScenarioAction 中 browsingRecord.id == scenarioSwitchTargetProfileID 恒真；LinesTab 线路组页的 LineRow 分支、NativeLinesView 的 LineGroupRow 分支与 expanded: line.isGroup 不可达。此外 MainPopover 有 13 处 state.browsingRecord，每次访问都经 runtimeRecord 重建 snapshot()，与已发布的 state.profile 并存。
- 位置：macos/Sources/XDial/AppState+Profiles.swift:19-21；macos/Sources/XDial/AppState+Profiles.swift:46；macos/Sources/XDial/SettingsView.swift:186；macos/Sources/XDial/SettingsView.swift:2108；macos/Sources/XDial/SettingsView.swift:2189；macos/Sources/XDial/SettingsView.swift:440-444；macos/Sources/XDial/SettingsView.swift:2924-2935；macos/Sources/XDial/NativeResourceViews.swift:20；macos/Sources/XDial/NativeResourceViews.swift:81-82；macos/Sources/XDial/MainPopover.swift:1255-1258；macos/Sources/XDial/MainPopover.swift:1390-1447；macos/Sources/XDial/GlobalConfiguration.swift:74-76；macos/Sources/XDial/ProfileLibrary.swift:173-183
- 建议：删除恒值属性及其分支；LineGroupRow 的来源标签改用 groupSources 判断；MainPopover 统一使用 state.profile（或在 AppState 缓存一份 runtime 视图）；connectScenario 的 profileID 参数可以去掉。
- 注意：若未来恢复多 Profile 运行需要重新设计；连同 AppState.deleteScenario:2856 的 editingActiveProfile 一起清理。

**P109　确认无调用方的死代码**　〔dead｜复核成立｜可删约 85 行〕

- 结论：以下 UI 代码都没有使用方，可以直接删除：SettingsView.installationBanner、LineRow.toggleField、LinesTab.showAddSub、MainPopover 中 private extension String.nonEmpty、CollapsibleCard 中的 SettingsPanel、.xdialSettingsSelectTab 的声明与 onReceive、AppIcon.base(size:)、XDialPalette.focus，以及 XDialBrandPalette 的 8 个 NSColor 便捷常量。其中 XDialBrandPalette 常量的实际行号是 74-83，不是 80-90。
- 位置：macos/Sources/XDial/SettingsView.swift:362-391；macos/Sources/XDial/SettingsView.swift:1558-1569；macos/Sources/XDial/SettingsView.swift:410；macos/Sources/XDial/SettingsView.swift:213-216；macos/Sources/XDial/XDialApp.swift:59-61；macos/Sources/XDial/MainPopover.swift:1823-1827；macos/Sources/XDial/CollapsibleCard.swift:176-194；macos/Sources/XDial/AppIcon.swift:15-17；macos/Sources/XDial/XDialPalette.swift:16；macos/Sources/XDial/XDialBrandPalette.swift:80-90
- 建议：直接删除。
- 注意：XDialBrandPalette 和 AppIcon 会被 Makefile:86-88、105-107 单独用 swiftc 编译。已确认生成器不引用被删成员，但删除后仍建议执行一次 generate-*-app-icon 的编译（只编译，不需要改图标）。

**P110　本地化两套机制并存，与 DESIGN 描述不符，Next 时期新界面基本未本地化**　〔duplication｜未复核｜可删约 125 行〕

- 结论：DESIGN §3 写“文案集中在 Localizable.xcstrings”，实际上 xcstrings 只有 7 个 line.address.* 键，只供 LineAddressView 按 Lang 选 lproj bundle 使用。主机制是 AppState.tr(zh,en)，UI 中约 394 处。另有约 200 处中文字面量绕过两者，英文界面会显示中文，主要集中在 Next 时期的新代码：ProfileManagementView≈70、SettingsView≈43（字段标签“服务器/端口/密码/跳过证书验证/高级选项（sing-box）”、lineTypeLabel 的“直连”）、NativeResourceViews≈38、LineLatencyView≈17、LineGroupMemberTable≈13、SettingsLineTable≈7。SwiftUI Text("…") 字面量会去查 xcstrings，但 catalog 中没有这些键；field("服务器")、Text(String) 则完全不本地化。
- 位置：macos/Sources/XDial/Localizable.xcstrings；macos/Sources/XDial/LineAddressView.swift:109-116；macos/Sources/XDial/AppState.swift:185-187；macos/Sources/XDial/ProfileManagementView.swift:8-18；macos/Sources/XDial/LineLatencyView.swift:55-82；DESIGN.md
- 建议：二选一：(a) 保留 state.tr，删除 xcstrings 与 LineAddressView 的 bundle 查找，修改 DESIGN；或 (b) 迁移到 String Catalog 并用 locale 覆盖实现应用内语言切换。无论选哪种，都要把约 200 处裸中文纳入。
- 注意：应用内语言切换不跟随系统 locale，迁移到 xcstrings 需要处理运行时切换；纯整理不影响网络行为。

**P111　UI 文案与架构/身份不符的过期内容**　〔legacy｜未复核｜可删约 3 行〕

- 结论：① 通用 › 系统与权限写着“配置和凭据加密保存，与其他版本的数据独立。”，而 ARCHITECTURE.md:300-306、DESIGN §5.1、CLAUDE.md 都规定各版本共享 ~/.xdial/configuration/profiles.enc；该文案在 f065750（2026-09-15）写入，共享库在 54585fe（2026-09-23）落地。② LineLatencyPresentation 的“需先在 Next 中连接使用此线路的场景……”在正式版、Debug 中同样显示。③ ScenarioRow 的 onActivate 实际调用 copyEditingScenario（按钮是“复制场景”），旁边注释仍写“和主 popover 的 Picker、DebugServer 的 select-scenario 走同一个 intent”。
- 位置：macos/Sources/XDial/GeneralSettingsView.swift:170-175；macos/Sources/XDial/LineLatencyView.swift:73；macos/Sources/XDial/SettingsView.swift:2115-2117；macos/Sources/XDial/SettingsView.swift:2182；macos/Sources/XDial/SettingsView.swift:2203-2206
- 建议：改正文案（“配置在各版本间共享；运行状态与系统组件相互独立”），去掉 Next 字样（改用 XDialBuildIdentity.productTitle 或中性措辞），把 onActivate 重命名为 onCopy 并删除过期注释。
- 注意：低。

**P112　过期计划、未启用草稿与 DESIGN 内部重复段落**　〔legacy｜未复核｜可删约 1230 行〕

- 结论：docs/plans/next-interface-redesign.md（202 行）开头说只实施“通用改为独立分类设置窗口”，其余暂不实施；8 天后 DESIGN §5.1（54585fe）改为“通用嵌入同一窗口……不创建另一扇通用窗口”，因此唯一采纳项也被推翻，且全仓无引用。design/drafts（约 1027 行 Swift + 4 张 PNG，共 280K）不属于任何 target，仓库内无引用；flight-status 从未启用，rotary-dial 草稿（10 孔）已被 RotaryDial.swift（6 孔）取代。DESIGN.md 本身：§7 末尾附了一节无编号的“### Next 线路组与延迟”，与 §5.2 的线路组段落重复，并且互相矛盾（“逐项加入”与“多选添加”）；正式版已发布的功能仍冠以“Next”；§5.2 仍列出已不存在的 Subscription 卡片；§1 类别顺序“线路/线路组/规则/场景”与 §5.1 顶栏“线路 规则 \| 线路组 场景”不一致。
- 位置：docs/plans/next-interface-redesign.md；design/drafts/README.md；design/drafts/flight-status-icon；design/drafts/rotary-dial-icon；DESIGN.md
- 建议：删除 next-interface-redesign.md 与 design/drafts（git 历史已保留；如需留存可移到 docs/history）；把 DESIGN 的“Next 线路组与延迟”并入 §5.2，去掉 Next 前缀，删掉 Subscription 卡片描述，统一类别顺序。
- 注意：仅文档与非编译资产，无运行风险。

**P113　Popover 的 RuleSet→Line 映射来自已保存配置，不是本次事务**　〔boundary-violation｜未复核｜可删约 0 行〕

- 结论：policyMappings 用 state.profile.scenarios 中与 report.scenario.id 同 ID 的场景重建映射，用 state.profile.ruleSets/lines 取名称。ConnectionReport.scenario 只有 id/name（ConnectionPlanScenario），不含 bindings。当 configDirty（修改已保存但尚未应用）时，“已连接详情”会把未生效的 binding 当作当前分流显示，与 DESIGN §4.3“本次事务实际使用……当前 Scenario 完整的 RuleSet → Line 清单”和“不伪造运行中”相悖。lineOverview 取延迟时也按 state.profile 查线路。
- 位置：macos/Sources/XDial/MainPopover.swift:1530-1588；macos/Sources/XDial/MainPopover.swift:1061-1064；macos/Shared/ConnectionTransaction.swift:70-73
- 建议：由 Go 的 ConnectionPlan 把有效 binding 摘要（ruleSetID→lineID 与名称）写入 ConnectionReport；Popover 直接渲染。过渡期至少在 configDirty 时把映射标为“已保存配置”。
- 注意：需要改报告 schema（schemaVersion），iOS/tvOS 解码要同步。

**P114　运行时 Dock 图标随连接状态切换，是 Dock 载体出现前的遗留**　〔legacy｜未复核｜可删约 25 行〕

- 结论：AppIcon.applyDockState(connected:) 在 XDialApp 的 4 处，按连接状态把主实例的 NSApp.applicationIconImage 设为带齿轮徽标的 dock 图。该机制在 264813a（2026-08-08，主实例当时会进 Dock）引入；d56a6f2（2026-08-16）改为独立载体提供 Dock 入口后，主实例恒为 .accessory（Makefile:222-224 守卫），载体注释明确“不在运行时另设 applicationIconImage”。DESIGN §3.1：“App 图标不表达连接状态”。AppIcon.drawDial 的 connected:false 分支只被这条路径和两条测试使用，所有生成器都传 connected:true。
- 位置：macos/Sources/XDial/AppIcon.swift:59-62；macos/Sources/XDial/AppIcon.swift:118-128；macos/Sources/XDial/XDialApp.swift:126-131；macos/Sources/XDial/XDialApp.swift:301；macos/Sources/XDial/XDialApp.swift:448；macos/SettingsDockUI/main.swift:16-21；macos/Tests/AppIconPaletteTests.swift:24-40；macos/Tests/AppIconPaletteTests.swift:80-87
- 建议：确认主实例 icon 不在任何可见位置（Alert/About）承担状态后，删除 applyDockState 及其调用、dock/primary 的 connected 参数，以及相关的 disconnected 图标测试。
- 注意：若 NSAlert 或关于面板依赖 applicationIconImage，删除后会回退到 bundle 图标，这正符合 DESIGN。

**P115　线路/规则的增删与引用检查写在视图里，场景的却在 AppState**　〔mixed-responsibility｜未复核｜可删约 20 行〕

- 结论：LinesTab.add 在视图里生成 ID 和默认名称，LinesTab.delete 手写引用检查（URL 规则获取线路、场景 binding/默认出口、组成员）并停止 Tailscale 会话，RulesTab 的添加与删除也手写引用检查；而 createBlankScenario/copyEditingScenario/deleteScenario 在 AppState。GlobalConfiguration 已有 validateReferences。LineGroupMemberSheet 预先过滤 vpn/tailscale，与 Profile.lineGroupMemberIssue（Models:1123）重复同一条规则，导致后者给出的原因永远不显示。
- 位置：macos/Sources/XDial/SettingsView.swift:514-546；macos/Sources/XDial/SettingsView.swift:1633-1659；macos/Sources/XDial/NativeResourceViews.swift:198-203；macos/Sources/XDial/Models.swift:1096-1125；macos/Sources/XDial/AppState.swift:2835-2870；macos/Sources/XDial/AppState+Profiles.swift:211-237
- 建议：新增 AppState.addLine(type:)/deleteLine/addRule/deleteRule，引用检查复用 validateReferences 或一个 references(of:) 查询；成员候选只用 lineGroupMemberIssue 禁用并显示原因。
- 注意：删除时的错误文案会改变；需要补测试覆盖引用阻止删除。

**P116　Wi-Fi 权限状态的呈现写了 4 份，判定条件不一致**　〔duplication｜未复核｜可删约 40 行〕

- 结论：WiFiSSIDAccessState 到文案/按钮/图标/颜色的映射分别在 MainPopover（needsSSIDAccess、ssidAccessActionTitle）、InstallationView（needsSSIDAccess、ssidAccessSymbol/Color/Detail/ActionTitle）、GeneralSettingsView（wifiAccessStatus）、ScenarioRow（读取当前 Wi-Fi/打开位置设置按钮与说明）。Popover 的 needsSSIDAccess 排除 .checking，安装窗口不排除；同一 .permissionRequired 的按钮在 Popover 是“开启位置权限”，在安装窗口是“继续”，各处文案不同。
- 位置：macos/Sources/XDial/MainPopover.swift:883-907；macos/Sources/XDial/InstallationView.swift:581-646；macos/Sources/XDial/GeneralSettingsView.swift:220-228；macos/Sources/XDial/SettingsView.swift:2304-2330；macos/Sources/XDial/SettingsView.swift:2379-2386
- 建议：在 WiFiSSIDAccessPolicy 旁增加一个 presentation（symbol/color/detail/actionTitle(context)），各处共用；按场景需要区分动作文案。
- 注意：InstallationView 在 .checking 时显示步骤可能是有意设计（DESIGN §6.1），合并时需保留这个差异。

**P117　场景 binding 整行都可起拖，DESIGN 规定只能从把手起拖**　〔other｜未复核｜可删约 0 行〕

- 结论：ScenarioBindingList 把 settingsReorderable 施加在整个 bindingRow 上，SettingsReorderModifier 对 content 整体加 .onDrag；行首的 line.3.horizontal 把手只提供悬停手形光标和无障碍上移/下移。DESIGN §5.2：“binding 只从行首固定的小型系统把手起拖……名称、行本体、目标 Picker 与删除按钮不参与起拖”。
- 位置：macos/Sources/XDial/ScenarioBindingList.swift:22-38；macos/Sources/XDial/ScenarioBindingList.swift:157-197；macos/Sources/XDial/SettingsView.swift:78-88
- 建议：把 onDrag 只挂在 reorderHandle 上，或者修改 DESIGN 接受整行拖动。
- 注意：需要实机验证拖放手感；离屏检查覆盖不到。

**P118　卸载事务状态与更新恢复意图放在视图 @State/计算属性里**　〔mixed-responsibility｜未复核｜可删约 0 行〕

- 结论：安装状态由 InstallationCoordinator 持有，卸载状态（isUninstalling、uninstallError、runUninstall 及成功后 requestQuit）却是 InstallationView 的局部 @State，关窗或视图重建会丢失进度和错误，安装与卸载互斥也只靠视图里的 guard。AppUpdateView.reconnectScenarioID 在视图中决定“更新后恢复哪个场景”，再传给 updater.installPreparedUpdate，这是更新事务的输入。
- 位置：macos/Sources/XDial/InstallationView.swift:9-12；macos/Sources/XDial/InstallationView.swift:504-522；macos/Sources/XDial/AppUpdateView.swift:131-136；macos/Sources/XDial/AppUpdateView.swift:257-264
- 建议：把卸载 phase/error 移入 InstallationCoordinator（与 install 同一事务对象，天然互斥）；reconnectScenarioID 由 AppState/AppUpdateChecker 在安装时自行读取 committed report。
- 注意：涉及卸载与更新事务，需要按 docs/agent 的验证流程回归。

**P119　DEBUG 布局检查工具有效性存疑，并复制了 Keychain 读取逻辑**　〔accretion｜未复核｜可删约 25 行〕

- 结论：SettingsLayoutPreview（195 行，仅 DEBUG）有两个入口：--check-scenario-layout（make test-scenario-layout）与 --render-settings-preview（docs/agent/profile-next.md:170）。可选的 --user-configuration 手写了一份与 ProfileLibraryStore.key() 相同的 Keychain 查询（account "profile-library-key-v1"）。事故文档承认“旧实现的离屏检查也能通过，说明该检查尚未覆盖现场卡死”。Makefile:222 把该文件写进 setActivationPolicy 白名单。
- 位置：macos/Sources/XDial/SettingsLayoutPreview.swift:41-69；macos/Sources/XDial/ProfileLibraryStore.swift:104-111；macos/Sources/XDial/main.swift:3-11；docs/incidents/2026-09-23-scenario-layout-livelock.md；Makefile:222
- 建议：保留截图入口；--user-configuration 改为调用 ProfileLibraryStore 的只读加载（禁止 UI 交互），或直接删除；评估 test-scenario-layout 是否仍有价值。
- 注意：仅影响 Debug 构建；删除文件需同步 Makefile:222 守卫。

需要作者回答的问题：

- Localizable.xcstrings 只有 7 个键，state.tr 有约 400 处：要统一成哪一种机制？Next 时期约 200 处裸中文（Profile 管理、线路组、延迟）在英文界面显示中文，是有意暂缓还是遗漏？
- Popover 的“已连接详情”分流映射目前取自已保存配置。是否接受让 Go 在 ConnectionReport 中带上有效 binding 摘要（需要升级报告 schema）？
- ScenarioBindingList 现在整行可拖。以 DESIGN §5.2 的“仅把手起拖”为准，还是改 DESIGN？
- SettingsLineTable/LineGroupMemberTable 这类原生 NSTableView 方案，是否有真实配置的线路数量证据支撑？规则页用分页 SwiftUI 就够了，线路页能否同样处理，从而去掉 AppKit 折叠行头这一份重复实现？
- 主实例为 .accessory 时，AppIcon.applyDockState 设置的运行时图标是否在任何可见位置（NSAlert、关于面板）被有意使用？如果没有，是否可以删除，并让 App 图标不再区分连接状态？
- --check-scenario-layout 与 --render-settings-preview 还在发布或验收流程中使用吗？事故文档说离屏检查在旧实现上也能通过，这个检查是否还值得保留？
- design/drafts 与 docs/plans/next-interface-redesign.md 是否可以只留在 git 历史里，从工作树删除？
- v2→v3 迁移是否还需要读取 Profile 内的 subscriptions/subscriptionID？如果迁移只做拒绝或转换，macOS UI 与 AppState 中的 sub: 目标、addSubscription/updateSubscription 是否可以整体删除？

### macOS Transparent Proxy 扩展

**P120　Direct 的 IPv6 地址族由固定 Cloudflare / Google 的 IPv6 TLS 探测裁决**　〔boundary-violation｜复核修正｜可删约 0 行〕

- 结论：探测确实存在，也确实与现行 ARCHITECTURE §4.3 的字面冲突。但它不是“从未获准的越界”，而是文档漂移：这个探测是 2026-08-21 实机事故驱动、当时写进 ARCHITECTURE 的明确契约，2026-09-12 的纯文档重写 63299e8 把契约和事故记录一起删掉了，代码没改。它也不是就绪门槛：探测失败只把 Direct 收敛到 ipv4_only，只有取消才会抛错。审计员给的替代方案“按接口是否有全局 IPv6 地址或默认路由决定”，恰好就是那次事故已证明不够用的信号，照做会直接回归。
- 位置：macos/TransparentProxyExtension/EmbeddedSingBoxRuntime.swift:387-390；macos/TransparentProxyExtension/EmbeddedSingBoxRuntime.swift:693-696；macos/TransparentProxyExtension/EmbeddedSingBoxRuntime.swift:1490-1496；macos/TransparentProxyExtension/EmbeddedSingBoxRuntime.swift:2724-2745；macos/Shared/UnderlayIPv6TLSProbe.swift:36-50；core/libbox/configgen.go:52-55,92-116；core/config/generator.go:263-272
- 建议：删除 Swift 的 UnderlayIPv6TLSProbe（含测试）和 directIPv6Available 管道，Direct 地址族改由 Go 基于 Underlay 上下文决定（接口是否有全局 IPv6 地址或默认路由）；或者先在 ARCHITECTURE 中写明例外，再决定是否保留。
- 注意：在作者确认前，不应删除探测。需要作者回答两件事：63299e8 删掉 IPv6 TLS 契约是有意弃用，还是精简时误删？“有 IPv6 地址和默认路由但 TLS 黑洞”的网络现在是否仍要支持？如果仍要支持，正确的改动是在 §4.3 写回明确例外（Direct 的地址族能力由 Provider 在提交前用冗余 TLS 握手测定，只约束 Direct 的解析视角，不作就绪门槛），并把事故证据补进 docs/incidents。如果改成基于 Underlay 地址或路由判断，会让 Chrome 的 ERR_CONNECTION_CLOSED 回归。删除时还要同步处理：Go 的 legacy 和 line-capabilities 两条入参、core/config/transparent_proxy_dns_test.go 中的 ipv4_only 用例、macos/Tests/UnderlayIPv6TLSProbeTests.swift，以及 Direct 用到的 sing-box 补丁 0010-reresolve-stale-ipv6-flow-domains（该补丁另被逐 Line 能力复用，不能一起删）。另外，探测在 IPv6 黑洞网络上会给每次冷启动和 Switch 增加最多 2.5 秒；这是可讨论的成本，但不构成删除理由。

**P121　Tailscale 就绪与 RuleSet 获取以 Direct 的 Cloudflare trace 出口探测作为门槛**　〔boundary-violation｜复核修正｜可删约 25 行〕

- 结论：Tailscale 就绪前的 Direct 出口探测确实是硬门槛：失败抛 underlay-egress-unavailable，归因到 underlay:system，整笔 start、Switch 或 Tailscale RuleSet 预取都会失败。冷启动时 Direct RuleSet 的 preflight 会话（无缓存）也以出口探测为硬门槛；后台会话失败只记日志。但审计员认错了端点：ProbeOutboundIP 用的是 checkip.amazonaws.com 和 1.1.1.1/cdn-cgi/trace，不是 r.inews.qq.com 或 IPv6 trace。更关键的是，这个预检是 underlay-egress-unavailable 的唯一生产者，而宿主的自动重试策略依赖这个码，直接删除会悄悄关掉 Underlay 变化后的自动重试。
- 位置：macos/TransparentProxyExtension/EmbeddedSingBoxRuntime.swift:2164-2179；macos/TransparentProxyExtension/EmbeddedSingBoxRuntime.swift:1889-1900；core/libbox/libbox.go:540-575
- 建议：删除 Tailscale 就绪前的 Direct 出口预检，以及 RuleSet 获取前对 Direct 的出口预检。RuleSet 获取失败本身已归因到对应 RuleSet（§7），Tailscale 失败由其自身的 control / DERP / 握手事实归因。
- 注意：删除前必须先给 underlay-egress-unavailable 找到新的、基于事实的生产者，例如 Go 基于 Underlay 上下文或 Tailscale control/DERP 拨号失败的结构化分类；同时调整 AutomaticReconnectRetryPolicy 的 .underlayChange 分支。否则 Tailscale 场景在网络切换失败后将不再自动重试，行为会变化。AutomaticLineReadinessFailurePolicyTests 也要同步。RuleSet 预检对代理 Line 走的是该 Line 自己的出口，§4.3 允许这类“经该 Line 的精确出口验证”，但它测的是出口展示服务而不是 RuleSet URL 本身，可以一并删除；删除后 preflight 失败会改由 rule-set-refresh-failed 归因到对应 RuleSet。

**P122　Tailscale 就绪等待与 DERP 诊断在 Swift 里实现（约 730 行协议层知识）**　〔boundary-violation｜复核修正｜可删约 55 行〕

- 结论：Tailscale 就绪的轮询、DERP 分类和事实采集确实都写在 Swift 里，行数基本属实：TailscaleStatus 解码 106 行、waitForTailscale 428 行、5 个 active/prepared 分派包装 119 行、TailscaleReadiness.swift 507 行。但“违反 §1 边界”没有对应的明文条款：§1 禁止 Swift 复制 Go 的 tag、schema、依赖闭包和指纹算法，并没有禁止 Provider 宿主编排就绪等待。“可删 450 行”本质上是把逻辑搬进 Go，不是删除，净减少有限。现在就能直接删的，是其中从未被生产代码调用的 Home DERP 重选判定（约 53 行）。
- 位置：macos/TransparentProxyExtension/EmbeddedSingBoxRuntime.swift:186-319；macos/TransparentProxyExtension/EmbeddedSingBoxRuntime.swift:1440-1481；macos/TransparentProxyExtension/EmbeddedSingBoxRuntime.swift:2156-2701；macos/TransparentProxyExtension/EmbeddedSingBoxRuntime.swift:3056-3069,3096-3117,3141-3164；macos/Shared/TailscaleReadiness.swift:1-507
- 建议：在 Go libbox 提供一个调用，例如 WaitTailscaleReady(endpointTag, prepared bool, timeoutMS)，返回结构化失败码和 facts，并在 Go 内完成 DNS 准备。Swift 只负责把结果写进报告。这样可删掉 TailscaleStatus 解码、轮询循环、分派包装，以及 TailscaleReadiness.swift 中的分类逻辑。
- 注意：迁移到 Go 时，失败码（tailscale-home-derp-not-ready、tailscale-peer-handshake-failed、tailscale-readiness-timeout、underlay-egress-unavailable）必须保持不变，因为 AutomaticLineReadinessFailurePolicy 和 AutomaticReconnectRetryPolicy 依赖它们；19 个报告 facts 的键名也被 docs/verification/tailscale.md 当作证据层级使用。迁移还会改变 MagicDNS 快照“在 Commit 前于 Swift 侧取一次并注入”的时序（prepareTailscaleGenerationDNS），要按 §3.2 契约回归。删除死代码时，要连同 TailscaleReadinessTests 中的 4 个 HomeDERPReselection 用例和 makeRecoveryFacts 辅助函数一起删（见 new_findings 中的 Go 侧同链）。

**P123　线路地址族就绪在 Swift 和 Go 各编排一遍，二次收敛编译由 Swift 驱动**　〔duplication｜复核修正｜可删约 12 行〕

- 结论：事实成立：Swift 用 OperationQueue 对非 Direct 的 Line 并发调 ProbeOutboundTLSCapabilities，自己解码并推导能力，再由 Swift 驱动约束重编译和稳定性确认；随后 Go 的 Ensure*LinesReady 串行遍历同一组 tag，靠 proof 缓存避免第二次网络探测；Go 的 report() 也独立算出每条 Line 的 IPv4/IPv6 可用性。LineAddressFamilyCapability.strategy 在生产代码中零调用。但“可删 250 行”大部分是迁移：Go 的 ensure 目前是串行的，迁移后必须在 Go 里补上并发和收敛逻辑。现在能直接删的只有 strategy。
- 位置：macos/TransparentProxyExtension/EmbeddedSingBoxRuntime.swift:1428-1614；macos/TransparentProxyExtension/EmbeddedSingBoxRuntime.swift:1616-1704；macos/TransparentProxyExtension/EmbeddedSingBoxRuntime.swift:2758-2825；macos/Shared/LineAddressFamilyCapability.swift:49-60,97-124；core/libbox/line_network_readiness.go:452-512,572-650,680-756
- 建议：让 Go 的 Ensure*LinesReady 并发探测，并直接返回每条 Line 的 capability 和是否需要约束重编译；最好把“探测 → 约束重编译 → 确认”整体放进 Go 的 prepare 流程。Swift 删除 OperationQueue 编排、LineAddressFamilyProbeState、Convergence 和 strategy。
- 注意：迁移到 Go 后，line-address-family-* 的 note 码和文案、line-address-family-capability-changed 的失败码与 data-plane:sing-box 归属、isStable 只确认已用地址族的语义（ab650e4 刚修过的切换误报）都必须保留。如果 Go 仍串行探测，多 Line 场景的准备时间会从约 8 秒变成 8 秒乘以 Line 数。冷启动的收敛路径借用了 prepareSwitch/commit/retire 并换新端口，Switch 的收敛路径是 abort 后用原端口重新 prepare，两者在 Go 中也要保留这一差异。

**P124　EmbeddedSingBoxRuntime 的 start() 与 prepareSwitch() 大段复制**　〔duplication｜复核修正｜可删约 90 行〕

- 结论：start() 和 prepareSwitch() 确实大段重复：端口与凭据生成、bootstrap 生成、reporter 任务初始化、单例冲突过滤、Session 构造几乎逐行相同。但“逻辑相同，仅变量名不同”说过头了。约束重编译在两处的语义不同：冷启动换新端口和新凭据，再 prepare、commit、retire；Switch 是 abort 后用原端口和凭据重新 prepare。此外 preflight 会话一边执行、一边拒绝；冲突过滤只在 start 记日志；复用 Line 的 note 只出现在 Switch；verifySubscriptionReadiness 的位置也不同。保守估计可净减约 90 行，而不是 130 行。
- 位置：macos/TransparentProxyExtension/EmbeddedSingBoxRuntime.swift:364-648；macos/TransparentProxyExtension/EmbeddedSingBoxRuntime.swift:653-934
- 建议：抽出 makeSession(envelope:readiness:port:credentials:prepared:)、convergeAddressFamily(...)、filterBackgroundSessions(...)、newSessionPortAndCredentials(avoiding:)。中期评估让冷启动复用 prepare / commit 路径。
- 注意：抽 makeSession、filterBackgroundSessions、newPortAndCredentials 是低风险的纯重构。constrained 收敛块要先参数化“新端口 vs 原端口”和“commit+retire vs 留待 commit”，才能合并。“冷启动等于空引擎加 prepare/commit”在 Go 侧不成立：probeOutboundIP 和 PrepareSwitch 都要求 l.running，并且需要有一个 source generation；首次启动还有 callback.attach、setNetworkInterfaces、setDefaultInterface，以及仅在 DEBUG 下的 routing probe。这一项与 P157 是同一个问题，行数不要重复计算。

**P125　Swift 复刻 Go 的 tag、任务 ID、runtime identity 格式和单例复用判定**　〔boundary-violation｜复核成立｜可删约 40 行〕

- 结论：成立，而且审计员漏了几处：Swift 不仅校验，还自己拼接 Go 的任务 ID（835 行 "line:\(lineID)"，1885/1903 行 "rule-set:"+id），并硬编码 underlay:system、data-plane:sing-box、dns:scenario 等计划任务 ID。审计员列出的格式校验和 AnyConnect 预判都核实属实。
- 位置：macos/TransparentProxyExtension/EmbeddedSingBoxRuntime.swift:1148-1179；macos/TransparentProxyExtension/EmbeddedSingBoxRuntime.swift:1294-1335；macos/TransparentProxyExtension/EmbeddedSingBoxRuntime.swift:1374-1378,1398-1419；macos/TransparentProxyExtension/EmbeddedSingBoxRuntime.swift:579-593,848-857,2169
- 建议：删除 Swift 侧的格式校验（Go 生成即权威，最多保留“非空且属于计划”的结构检查）。AnyConnect 不可复用改由 Go 返回结构化码（复用 LineReadiness 的 code 通道），单例冲突由 Go 直接不下发或标注 deferred。
- 注意：去掉 Swift 的 AnyConnect 预判之前，Go 必须先返回结构化码，且码值保持 switch-anyconnect-rebuild-required。dc364c3（最新的 Switch 完整重连修复）依赖这个码；现在 Go 侧只有一条字符串错误，直接删除会让这次修复失效。Swift 的预判还避免了调用 prepareSwitch 带来的候选构造副作用，迁移后要确认 Go 在 acquireCandidate 之前没有不可回滚的动作。start() 的冲突过滤会记 rule-set-refresh-deferred 日志，Switch 的过滤不记；迁移后可以借机统一。

**P126　Session 与 Reporter 中的死字段和死参数**　〔dead｜未复核｜可删约 30 行〕

- 结论：看到的事实： - EmbeddedSingBoxRuntime.Session 的 networkEpochID（30）、lineRuntimeIdentities（40）、tailscaleRuntimeIdentity（50）只在构造时赋值，全扩展没有任何读取。 - tailscaleRuntime(in:) 的返回值只流向 tailscaleRuntimeIdentity，所以这个函数实际只剩复刻 Go tag 的格式校验。 - ConnectionTransactionReporter.setTasks 的 excludingResourceType / matchingResourceType 参数没有调用方传入。 - firstTaskID 的 resourceType 参数没人用；firstTaskID 本身只被 #if DEBUG 的故障注入调用。 - TCP / UDP relay 的 credentials 是可选类型，并带无认证分支（method 0x00），但所有调用方都传非空凭据。§3.1 本就要求随机凭据保护回环 SOCKS。
- 位置：macos/TransparentProxyExtension/EmbeddedSingBoxRuntime.swift:30,38-40,49-50,607,627-628,638-639,880-881,892-894；macos/TransparentProxyExtension/ConnectionTransactionReporter.swift:51-69,340-349；macos/TransparentProxyExtension/TCPFlowSOCKSRelay.swift:24,209-222；macos/TransparentProxyExtension/UDPFlowSOCKSRelay.swift:19,544-555
- 建议：删除三个 Session 字段、tailscaleRuntime(in:) 与 TailscaleRuntimeReference，删除 Reporter 的无用参数，把 SOCKS 凭据改成非可选并删掉无认证分支。
- 注意：低。只要确认没有通过 Mirror 或日志反射读取这些字段。

**P127　macOS 流量速率用 Swift relay 账本，与 Go Router trafficCounter 重复**　〔duplication｜复核成立｜可删约 80 行〕

- 结论：成立。macOS 上同时存在两套流量计数：Swift 的 ProviderTrafficLedger（b8ba939，2026-08-07 引入，供 Popover 速率使用），以及 Go 的 trafficCounter（5ab8ff1，2026-10-11 为 iOS 引入，无条件挂在每一代 Box 的 Router 上）。macOS 宿主不读 Go 这套，但每条路由连接仍要付它的计数包装开销。去重有两个方向：改用 Go 的 TrafficTotals，或者在 macOS 上不挂 Go tracker。
- 位置：macos/Shared/ProviderTrafficLedger.swift:1-61；macos/TransparentProxyExtension/TransparentProxyProvider.swift:174,275,862-875,1694,2114,2131；macos/TransparentProxyExtension/TCPFlowSOCKSRelay.swift:26,70-71,321-348；macos/TransparentProxyExtension/UDPFlowSOCKSRelay.swift:66,192-195,482-485；macos/TransparentProxyExtension/LocalSOCKSShareListener.swift:138,227-228,261-281；core/libbox/traffic_counter.go:17-106；core/libbox/libbox.go:1343,1974
- 建议：traffic-snapshot 改为返回 runtime 的 TrafficTotals，事务归零改由宿主记录基线差值；然后删除 ProviderTrafficLedger 和各 relay 的 traffic 参数。
- 注意：口径差异：Swift 账本在事务 reset 后会丢掉仍在排空的旧代 relay 的字节（transactionID 不匹配），Go 计数会把它们算进去。完整重连会新建 Libbox，计数归零，现有“下降置 0”的逻辑可以覆盖这种情况。审计员担心的“跨两代重复累加”，Go 的注释和设计已经排除。traffic-snapshot 仍应保留事务 ID 校验，防止跨事务采样。如果选择保留 Swift 账本、关掉 Go tracker，需要按平台给 Libbox 加开关，改动面更小，但 Go 侧要多一个配置项。

**P128　应用归属诊断账本在 Release 里逐流记录却只有 DEBUG 能读，并让 Provider 持有 Line / RuleSet / Subscription ID**　〔dead｜复核成立｜可删约 120 行〕

- 结论：成立。ProviderApplicationAttributionLedger 自 30e6492 引入起，读取路径就只存在于 DEBUG 构建（宿主 TransparentProxyManager、GoEngine 和整个 DebugServer）。Release 与 NextRelease 构建里，它是每个 flow 都加锁写入、却没有任何读者的账本。credentials() 在判断 activeSelectors 是否为空之前就调用 proc_pidpath_audittoken，所以没有应用规则时，每个 flow 也付一次 syscall。
- 位置：macos/TransparentProxyExtension/TransparentProxyProvider.swift:13-126；macos/TransparentProxyExtension/TransparentProxyProvider.swift:172-173,337-343,876-891,1695-1699,2204-2255；macos/TransparentProxyExtension/EmbeddedSingBoxRuntime.swift:17-23,63-79,611-625,864-878；macos/Shared/ProviderDiagnosticsIPC.swift:400-411
- 建议：整体包进 #if DEBUG，或直接删除账本。把 ruleSetID / lineID / subscriptionID 从 ApplicationProcessCredential 中移除，让 Provider 只持有不透明的 selector→凭据对。把 activeSelectors.isEmpty 判断提前到取路径之前。
- 注意：建议中的两项改动彼此有牵连：如果选择保留 DEBUG 账本而不是删除，它按 ruleSetID、lineID、subscriptionID 计数，就不能同时把这三个字段从凭据里移除，或者要连同计数维度一起用 #if DEBUG 包住。移除字段时，要同步删掉 decodeSessionEnvelope 1321-1323 中“ruleSetID 非空，且 lineID 与 subscriptionID 恰有一个”的校验。Go 端可以继续下发这些字段，JSONDecoder 默认忽略未知键。docs/agent/debug-server.md:25 记载了 application-attribution-snapshot，完全删除时要同步文档。

**P129　TCP 与 UDP relay 的 SOCKS 客户端代码逐函数复制**　〔duplication｜未复核｜可删约 170 行〕

- 结论：看到的事实：UDPFlowSOCKSRelay 以 private 形式复制了 TCPFlowSOCKSRelay 里已是 internal static、并被 LocalSOCKSShareRelay 复用的 SOCKS 客户端原语： - isExpectedFlowClosure：TCP 96-103，UDP 489-496。 - diagnosticCode：TCP 105-134，UDP 498-540，只多三个 case。 - authenticate：TCP 275-298，UDP 621-644，逐字相同。 - 方法协商：TCP 214-222，UDP 547-555。 - start(connection)：TCP 182-205，UDP 720-743。 - send：TCP 423-436，UDP 745-758。 - receiveExactly：TCP 468-492，UDP 760-784。 - open(flow)：TCP 300-314，UDP 704-718。 - OneShotGate 与 UDPRelayGate 两个相同的类：TCP 558-573，UDP 806-821。  去重后 UDP relay 约 800 行，剩下的规模来自跨代重关联（supervisor / associationLoop / channel），属于必要复杂度。
- 位置：macos/TransparentProxyExtension/TCPFlowSOCKSRelay.swift:96-134,182-222,275-314,423-436,468-492,558-573；macos/TransparentProxyExtension/UDPFlowSOCKSRelay.swift:489-555,621-644,704-784,806-821
- 建议：抽出 SOCKS5Client（connect / greet+auth / connect / udpAssociate / receiveExactly / send）和 NEFlowIO（open / read / write、预期关流判定），放到 macos/Shared 并纳入测试目标；两种 relay 和 LocalSOCKSShareRelay 共用。
- 注意：低。注意 UDP 的 RelayError 与 TCP 的 RelayError 诊断码映射要合并而不改变日志码值。

**P130　TransparentProxyProvider 3096 行承担 7 类事务，样板重复且无法单测**　〔mixed-responsibility｜未复核｜可删约 300 行〕

- 结论：看到的事实，按块划分： - 1-126：应用归属账本（114）。 - 128-205：状态。 - 206-576：冷启动事务（371，含 DEBUG 注入约 55）。 - 578-633：停止。 - 635-666：Tailscale 控制 IPC。 - 668-734：本机 SOCKS IPC 与 accept。 - 736-989：消息路由加诊断分发（254）。 - 991-2081：Switch 事务（1091）。 - 2083-2296：flow 接入与进程归属（214）。 - 2298-2462：出口与测速探测（165）。 - 2464-2767：致命错误、提交超时与回滚（304）。 - 2769-2819：快照校验 helper。 - 2822-3008：ProviderScenarioSwitchOperation 状态机（187）。 - 3010-3096：错误。  占比：诊断约 550 行（约 18%），Switch 约 1280 行（41%）。  可压缩的样板： (a) “setTunnelNetworkSettings + asyncAfter(5s) + ID 守卫”出现 4 次：422-427/2513-2552、1496-1527、1784-1812、2741-2766。 (b) ProviderScenarioSwitchResponse 手写构造 7 次：1014、1124、1143、1192、1233、1741、2060。 (c) completionHandler(encodeDiagnosticsResponse(.failure(...))) 约 15 次。 (d) ProviderDiagnosticsSessionState 构造 2 次：791-800、2387-2399。 (e) Underlay 快照解析 2 份：startProxy 235-262 与 switchNetworkSnapshot 1880-1905。isNumericIPAddress 另在宿主有 3 份（TransparentProxyManager.swift:10-26、3834-3846，NetworkInfo.swift:283-286）。 (f) 同一 IPC 通道有三套信封：kind 头、cmd 头（Switch），以及 Codable 的诊断请求，一条消息最多被 JSON 解析 3 次（741、991-1000、762）。  Provider 文件不在 XDialTests 的 sources 中，所以 Switch 状态机和 PendingCommitAbort 都没有单测。
- 位置：macos/TransparentProxyExtension/TransparentProxyProvider.swift:1-3096；macos/project.yml:400-450
- 建议：按事务拆文件或类型：ProviderStartTransaction、ProviderSwitchTransaction（并把 ProviderScenarioSwitchOperation 移到 Shared 加单测）、ProviderDiagnosticsHandler、ProviderFlowIngress、ProviderRollback。抽出 applySettings(_:timeout:id:)、switchResponse(...)、diagnosticsFailure(...) 三个 helper。在 Shared 定义可 Codable 的 UnderlayNetworkSnapshot，供宿主和 Provider 共用（含 IP 校验），并统一 IPC 信封为 {kind,...}。
- 注意：Switch 与回滚的竞态窗口（settingsCommitID、pendingCommitAbort、engineQueue.sync）很敏感，拆分必须保持所有状态只在 engineQueue 上读写。建议先抽纯函数和状态机再动控制流。

**P131　EmbeddedSingBoxRuntime 3175 行混合 9 类职责**　〔mixed-responsibility｜未复核｜可删约 0 行〕

- 结论：看到的事实，按块划分： - 1-350：类型，含 TailscaleStatus 106 行。 - 364-648：冷启动编排（285）。 - 650-1006：Switch prepare / commit / retire / abort（357）。 - 1008-1121：就绪失败映射、AnyConnect 解析、network context、epoch。 - 1123-1356：信封生成与校验（234）。 - 1357-1769：generation 就绪（地址族、二次收敛、订阅；413）。 - 1771-1990：RuleSet 冷获取与后台刷新（220）。 - 1992-2100：诊断透传（109）。 - 2102-2154：stop 与运行目录。 - 2156-2701：Tailscale 就绪与分派（545）。 - 2703-2754：AnyConnect 等待与 IPv6 探测。 - 2758-2825：探测状态。 - 2827-3049：三个 Libbox 回调（223）。 - 3051-3175：错误（125）。  Tailscale 相关约占 23%。另有小的补丁性写法：EngineCallback.retarget 通过向 gate 喂伪造的 "{\"status\":\"connected\"}" JSON 来切换状态（2925），而不是提供显式的 markRunning。  该文件同样不在测试目标中。
- 位置：macos/TransparentProxyExtension/EmbeddedSingBoxRuntime.swift:1-3175
- 建议：按块拆为 SessionEnvelope（解码与校验）、GenerationReadiness（迁移进 Go 后会大幅缩小）、RuleSetAcquisition、TailscaleReadiness（迁入 Go）、RuntimeCallbacks、RuntimeDiagnostics。给 EngineCallbackRuntimeGate 加 markRunning() 替代伪造 JSON。实际可删行数已计入其他问题，本条只计拆分。
- 注意：engineLock 保护的 engine、preparedSwitchState、background* 状态跨块共享，拆分时要集中在单一 owner。

**P132　Home DERP 重选判定是死代码（Swift 谓词和 Go 导出都只有测试调用）**　〔dead｜复核成立｜可删约 140 行〕

- 结论：shouldReselectTailscaleHomeDERP、私有的 isTailscalePeerRecoveryCandidate 和 TailscalePeerRecoveryFacts 自 a5f761f 引入后，在任何分支上都只被 TailscaleReadinessTests 调用。这个谓词按“Prepare 期间自动触发一次”设计，与 d35 §4“不能成为连接启动事务中的自动恢复动作”的结论相冲突，即使将来保留 Go 的显式维护能力，这个谓词的形状也不对。
- 位置：macos/Shared/TailscaleReadiness.swift:16-27,441-482；macos/Tests/TailscaleReadinessTests.swift:128-181,439-472；core/libbox/tailscale_status_gvisor.go:517-575
- 建议：删除 Swift 谓词、TailscalePeerRecoveryFacts 和对应测试。Go 侧的 ReselectTailscaleHomeDERP 交给 Go 范围审计决定：删除，或接上显式维护入口。
- 注意：tailscaleRealEgressTimedOut（484）和 shouldReleaseTailscaleNonHomeDERP（497）紧挨着谓词，生产在用（EmbeddedSingBoxRuntime.swift:2378/2384）。测试 helper facts(...) 被其他测试共享，要保留。Go 的 ReselectTailscaleHomeDERP 去留由 P018/P154 决定。

**P133　Relay 小类型的轻度过度抽象与重复**　〔over-engineering｜未复核｜可删约 40 行〕

- 结论：看到的事实： - RelayConnectionCancellationMode 枚举和 mode(for:) 只在 RelayTaskPairTests 中断言，生产路径只用 cancel(_:error:)，本质是一个三元表达式。 - RelayTaskPair 与 RelayTaskGroup 各有一份相同的 drain（RelayTaskPair.swift:84-97 与 127-138）。 - UDPRelayOneShotBox（UDP 943-978）与 RelayPendingOperation 都是一次性的 continuation 桥。 - UDPFlowSOCKSRelay.AssociationTicket 手写的 init（26-38）与自动生成的成员 init 等价。  整体判断：Relay* 拆进 Shared 主要是为了能单测（扩展文件不在测试目标里），不算过度拆分；以上只是零碎冗余。
- 位置：macos/Shared/RelayConnectionCancellation.swift:4-18；macos/Shared/RelayTaskPair.swift:84-97,127-138；macos/TransparentProxyExtension/UDPFlowSOCKSRelay.swift:26-38,943-978
- 建议：删掉 Mode 枚举（测试改为断言行为），把 drain 合成一个私有函数，用 RelayPendingOperation 替代 OneShotBox，删除冗余 init。
- 注意：低。

需要作者回答的问题：

- Direct IPv6 TLS 探测（UnderlayIPv6TLSProbe，固定 Cloudflare / Google IPv6）现在仍然决定 Direct 的 IPv6 地址族，Go 侧已把这个入参命名为 legacyDirectIPv6Available。这是有意保留的例外吗？当初引入它（b6a91bb）要解决的现场问题是什么？能否改为由 Go 根据 Underlay 上下文判断？
- Tailscale 就绪前用 Direct 的 ProbeOutboundIP（Cloudflare trace / r.inews.qq.com）做 Underlay 出口预检，RuleSet 获取前也有同样的预检；失败会让整笔事务失败并归因到 underlay:system。这与 §4.3“展示服务失败不升级为门槛”冲突，是有意的吗？
- Tailscale 就绪的轮询、DERP 分类和 non-home DERP 释放目前只在 macOS 的 Swift 里，iOS / tvOS 没有。是否接受整体迁入 Go libbox，由 Go 返回结构化失败码和 facts，并让三个平台共用？
- 应用归属账本（application-attribution-snapshot）只有 DEBUG 的 DebugServer 读取，Release 下却逐流记录。还需要它吗？可以只在 DEBUG 编译，或者直接删除吗？
- Popover 的速率是否必须精确到 Provider 入口字节、并按事务清零？如果可以接受 Go Router 的 TrafficTotals 加宿主差值，就能删掉 ProviderTrafficLedger。
- Home DERP 重选（Go 的 ReselectTailscaleHomeDERP 和 Swift 谓词）计划做成用户显式触发的维护入口吗？如果没有计划，两侧都可以删除。
- core/libbox/flow_ingress_test.go 已验证可以把 flow 直接以 net.Conn 送进 sing-box Router。是否有计划用 gomobile 直连 flow 替代回环 SOCKS relay？如果做，TCP / UDP / 本机 SOCKS relay 约 1500 行的去留会完全不同，现在的去重投入应该相应调整。
- 冷启动的 instance.start 与 Switch 的 prepare / commit 是两条路径（冷启动做约束重编译时又在内部走了 prepare / commit / retire）。是否可以统一为“空引擎加 prepare / commit”？

### iOS / tvOS

**P134　数据链路验收依赖固定公网探针、强注入锁定规则、失败即断开（约 1300 行）**　〔boundary-violation｜复核成立｜可删约 900 行〕

- 结论：移动端的数据链路验收依赖固定公网探针（1.0.0.1、1.1.1.1、www.apple.com，加上逐出口的 Cloudflare trace），给每个场景强制注入锁定的验收规则（1.1.1.1/32 会被改道到场景的首个非 Direct 出口），并在失败时 stopVPNTunnel。Go 的 generator 和 routing_probe 为此保留了特例。移动端没有使用 Go 已有的 EnsureActiveLinesReady/LineReadiness。这与 ARCHITECTURE §4.3、§2 冲突。补充：受 P028 影响，这套验收自 a5f761f 起恒失败。
- 位置：appletv/XDialTV/Models.swift:114-137；appletv/XDialTV/Models.swift:418-589；appletv/XDialTV/Models.swift:604-646；appletv/XDialTV/AppState.swift:628-659；appletv/XDialTV/AppState.swift:1068；appletv/XDialTV/AppState.swift:1326；appletv/XDialTV/TunnelManager.swift:140-722；appletv/XDialTV/TunnelManager.swift:1348-1485；appletv/XDialTV/TunnelManager.swift:1692-1941；appletv/XDialTVTunnel/PacketTunnelProvider.swift:876-884；ios/XDialIOS/ConfigurationView.swift:167-205；ios/XDialIOS/ScenariosView.swift:219-224；core/config/generator.go:34-35；core/config/generator.go:1989；core/libbox/routing_probe.go:33-34
- 建议：先请作者确认这是不是移动端有意的产品契约。如果按架构收敛：Provider 在 completion(nil) 之前调用 Go 的 EnsureActiveLinesReady，把结果作为结构化就绪事实；删除 Swift 的 TunnelAcceptancePlan/DataPathProbe/ConfiguredDataPathResult/RoutingProbeSnapshot 以及 Models 里的 connectivity 扩展；加一次迁移，从持久化的 profile 中移除 xdial-connectivity-* 规则和绑定；最后删掉 Go generator 和 routing_probe 里的特例。
- 注意：粗算：TunnelManager 中 TunnelAcceptancePlan、DataPathProbe、ConfiguredDataPathResult、RoutingProbeSnapshot、verifyDataPath 与各类探针请求约 850 行；Models 中 connectivity 部分约 170 行；AppState 的 appendConnectivityAcceptanceIssues 约 33 行；UI 锁定约 25 行；Provider 的两个命令约 50 行；Go 特例约 100 行。毛删约 1250 行，再加 DataPathProbeTests 422 行。扣除接入 Go 就绪证明的胶水代码和一次性迁移（约 150 行），900 行属于保守数。P149 与本条重复，只计一次；P148 的 TunnelAcceptancePlan 部分也在这里。风险要补一条：现状并不是“连上就能上网才算成功”，而是按 P028“永远不会成功”（推断）。所以先修 P028，或者直接按本条收敛，优先级都应该提高。dataPathVerified 和 on-demand 的武装条件（TunnelManager.swift:734-740）也要一并重写。

**P135　Swift 复制 Go 的 outbound tag 方案和已过期的“Tailscale 全局生成”语义**　〔boundary-violation｜未复核｜可删约 60 行〕

- 结论：看到的事实：TunnelAcceptancePlan.lineTag 在 Swift 里重新拼出 direct/vpn/tailscale-<id>/proxy-<id>，与 Go 的 resolveOutboundTag 字符串完全相同；AppState.tailscaleEndpointTag、ConfiguredDataPathResult.safeTargetLabel 也按 tag 前缀反解。Swift 侧（AppState:594-611、TunnelManager:151-154/229-236、OnDemandStartEnvelope:6-8）假设 Go 会为所有已启用的 Tailscale 线路生成全局 endpoint。但 Go 当前只为活动场景引用的 Tailscale 生成 endpoint（generator.go:420-424 注释“未被 active Scenario 引用的 Line 不计入”，464 行 `if !activeTailscaleIDs[line.ID]`）。推断的后果：已启用但未被引用、且未登录的 Tailscale 线路会阻止连接；如果它此前已登录，验收会去轮询一个不存在的 endpoint，约 30 次失败后自动断开（TunnelManager 1621-1631）。测试 testUnreferencedEnabledTailscaleRequiresLoginBecauseItIsGloballyGenerated 把这个过期语义固定了下来。
- 位置：appletv/XDialTV/TunnelManager.swift:151-154；appletv/XDialTV/TunnelManager.swift:195-236；appletv/XDialTV/TunnelManager.swift:551-557；appletv/XDialTV/AppState.swift:594-611；appletv/XDialTV/AppState.swift:2322-2324；appletv/XDialTV/AppState.swift:2331-2333；appletv/XDialTV/OnDemandStartEnvelope.swift:6-8；ios/XDialIOSTests/AppStateTests.swift:1162-1194
- 建议：由 Go 在 ConnectionPlan（或新导出函数）里返回本次需要验收/登录的 endpoint 和 outbound tag，Swift 只消费它；删除 Swift 的 tag 拼接，以及对“全局 Tailscale”的校验和测试。
- 注意：需要 Go 侧补一个导出字段；OnDemandStartEnvelope 的 schema 要升级，旧信封作废，需要用户重新验收一次。

**P136　Swift 重复实现 Go 已有的配置校验（悬空引用、AnyConnect 单例、订阅策略组可达性、规则格式）**　〔duplication｜未复核｜可删约 450 行〕

- 结论：看到的事实：AppState 545-983 约 440 行，在连接前做完整校验，包括逐协议字段、订阅策略组可达性不动点（785-808 和 834-857 是同一段逻辑写了两遍）、规则 HTTPS 和格式、多 AnyConnect、悬空引用。MobileConfigurationSupport 205-356 在导入时又写了一套（策略组成员、REJECT 常量、规则类型、格式列表都重复）。注释 545-546 的前提是“生成器会跳过无效目标并回落到 direct”，但 Go 现在在生成入口就拒绝悬空引用（generator.go:389-393 INV6a），对多 AnyConnect/Tailscale 报错（418/423），禁用对象则通过 CollectProfileWarnings / ConnectionPlan.Warnings 给出。macOS 对应的宿主侧检查只有 ConnectionConfigurationReadiness.swift 的 87 行（AnyConnect 字段）。推断：大部分 Swift 校验可以改为调用 GenerateConnectionPlan；但我没有逐协议核实 Go 是否对每个缺字段的情况都报错。
- 位置：appletv/XDialTV/AppState.swift:545-983；ios/XDialIOS/MobileConfigurationSupport.swift:205-356；appletv/XDialTV/TunnelManager.swift:2213-2246；ios/XDialIOS/HomeView.swift:215
- 建议：连接前和导入时调用 LibboxGenerateConnectionPlan（或 ValidateProfileDocument），用 Go 的错误和 warning 驱动阻断与提示；Swift 只保留与 macOS 对齐的“缺字段引导”提示（服务器/用户名/密码/端口）。
- 注意：Go 的报错文案目前是英文，需要做本地化映射；HomeView 每次渲染都对每个场景跑校验，改成跨语言调用要注意性能（可以缓存，或只算活动场景）。

**P137　tvOS 目标在真机上不可用，只是 Simulator 演示外壳**　〔dead｜复核成立｜可删约 600 行〕

- 结论：tvOS 真机构建下，RootView 走 #else 分支，构造 AppState()，默认引擎是 NoopTunnelEngine、tunnelManager 为 nil。isConnectionConfigured 在 AppState.swift:515 返回 false，所以 canConnect 恒为 false。tvOS 端从不实例化 GoEngine 或 TunnelManager（只有 ios/XDialIOS/MobileIntentHost.swift:29-30 在用），XDialTVTunnel 扩展在真机上不会被拉起。只有 Makefile 的 appletv 目标会编译它（Simulator、CODE_SIGNING_ALLOWED=NO），CI 不构建它。
- 位置：appletv/XDialTV/RootView.swift:19-33；appletv/XDialTV/AppState.swift:513-518；appletv/XDialTV/AppState.swift:1014-1016；appletv/XDialTV/AppState.swift:2768-2795；appletv/XDialTV/SettingsView.swift:84-117；appletv/XDialTV/CredentialsView.swift:6-8；appletv/XDialTV/DebugSmokeTest.swift:1-61；appletv/project.yml:1-66；Makefile:510-517；appletv/XDialTV/TunnelManager.swift:30-36；appletv/XDialTVTunnel/PacketTunnelProvider.swift:68-74
- 建议：请作者决定：(a) 删除 tvOS 目标（tvOS UI、DebugSmokeTest、appletv/project.yml、Makefile 的 appletv 和 libbox-xcframework 目标、#if os 分叉、NoopTunnelEngine），并把共享源文件从 appletv/XDialTV 移到 ios/ 下的共享目录；或 (b) 接上真实的 GoEngine/TunnelManager，并补上 CI 构建。
- 注意：审计员说 CI“只有” macOS 两个目标，不准确：CI 还跑 Go 的 vet/build/test，只是确实不构建 iOS/tvOS。删除前要注意：(1) iOS 通过 ../appletv/XDialTV/*.swift 和 ../appletv/XDialTVTunnel/PacketTunnelProvider.swift 的相对路径编译共享源，搬迁目录时要同步改 ios/project.yml:44-45、121-128；(2) PacketTunnelProvider 有 5 处、TunnelManager 有 1 处 #if os(iOS)/#else，删 tvOS 后改成单分支；(3) README.md:4、AGENTS.md:3、DESIGN.md:4、ARCHITECTURE.md:59/127/352 以及 Makefile:105/140/446 的注释都写着“iOS / tvOS”，Go 注释里也有 tvOS 字样；(4) scripts/generate-mobile-app-icons/main.swift:86 写死了 tvOS 资源路径；(5) 删 libbox-xcframework（-target=tvos）目标时要同步改 .PHONY。这是产品线决策，需要作者拍板。

**P138　旧格式迁移处理移动端从未写过的格式，却漏掉了真实写过的 modes→scenarios**　〔legacy｜复核修正｜可删约 300 行〕

- 结论：方向成立，而且问题比审计员写的更大。移动端在 a12b44e 到 9b815dd（2026-07-01 至 08-01）之间写入的一直是 "modes"/"active_mode_id"。0abde98 改名时，没有为 envelope 或 raw 两种存储写迁移。结果有两种：c56cda4 之后的 envelope（schema_version 恒为 1）会被 decodeIfPresent 静默解成空场景；c56cda4 之前的 raw JSON 无法通过 hasCurrentShape（需要 scenarios），migrate(oldProfile:) 也返回 nil，于是变成 .corrupt，persistence 被阻断。因此整个 .legacy 分支在 0abde98 之后对真实数据都不可达，包括审计员认为“真实存在”的扁平 vault（\(id)-vpn）和 vault.json 迁移。比喻 key 重写、v0.2 迁移和逐条 Keychain 读取则从来没有数据来源。
- 位置：appletv/XDialTV/AppState.swift:1868-1971；appletv/XDialTV/AppState.swift:1993-2113；appletv/XDialTV/AppState.swift:1637-1653；appletv/XDialTV/AppState.swift:378-406；appletv/XDialTV/Models.swift:365-409；appletv/XDialTV/KeychainStore.swift:227-248；appletv/XDialTV/KeychainStore.swift:363-368；ios/XDialIOSTests/AppStateTests.swift:2656-2907
- 建议：删除比喻 key 重写、v0.2 迁移、逐条 Keychain 读取和 legacyOwnerCounts 的逐条部分，以及对应测试。请作者确认 08-08 之前是否分发过 iOS 构建：如果有，补一条明确的 modes→scenarios 转换并升级 envelope schema；如果没有，扁平 vault 迁移也可以一并删除。
- 注意：有两处事实需要更正。(1) 审计员说“移动端 Keychain 没有 access group”不准确：iOS 有 keychain-access-groups 权限（UVZM439VGU.com.kafeifei.xdial.shared，用于 App 与隧道之间的 on-demand envelope），只是 KeychainStore 的 production context 把 accessGroup 设为 nil。没有数据来源的真正原因是：移动端从未逐条写过，macOS 的 Keychain 条目也不会出现在 iOS/tvOS 设备上。(2) 扁平 vault 迁移同样不可达。是否删除整条 .legacy 链路（restoreLegacyValues、loadLegacyPerItemValues、legacyOwnerCounts、loadSaved 的 .legacy 分支，以及 AppStateTests 2656-2907 中的对应用例），取决于作者是否要补一条 raw 格式的 modes→scenarios 迁移；如果要补，这条链路需要保留并改造。补 envelope 迁移时，要么升级 schema_version，要么在 envelope 分支识别 profile.modes。KeychainStore 的 legacy 清理（cleanupRequired/removeLegacyKeychainItems）仍然在 envelope 分支生效，不要误删。normalizeLegacyProfile（ss→shadowsocks、tailscaleAuthenticated）在 envelope 路径上仍然在用，同样不能删。

**P139　移动端模型、持久化和导入导出与 macOS Profile Next 分叉；Swift 自己计算配置脏标记**　〔legacy｜未复核｜可删约 200 行〕

- 结论：看到的事实：移动端 Models.swift（647 行）是 macOS Models（1165 行）的旧分叉，缺少线路组（group_members/group_default）、AnyTLS、应用规则、fetch_line_id、condition_ids、profile_id 等。持久化格式是移动端自有的 UserDefaults 信封（xdial-profile v1）加 Keychain vault；导入导出又是一套自有格式 xdial-mobile-configuration v1。Go 的 ImportProfile/ExportProfile/ValidateProfileDocument（profile_document.go:19/82/138）在移动端零调用。hasPendingRuntimeChanges 通过对整个 Profile 做 JSON 编码比较得出（AppState:1414-1437），而 ARCHITECTURE §5.2 要求“Swift 只比较指纹判断 configDirty”，指纹“排除显示名称、图标”；Go 的 ConnectionPlan 已提供 configuration_fingerprint（connection_plan.go:14）。推断：已连接时只改线路名称也会出现“配置已保存，等待重新连接后应用”的横幅（HomeView:434）。
- 位置：appletv/XDialTV/Models.swift:1-409；appletv/XDialTV/AppState.swift:378-406；appletv/XDialTV/AppState.swift:1414-1437；ios/XDialIOS/MobileConfigurationSupport.swift:43-204；ios/XDialIOS/MobileSettingsView.swift:245-321
- 建议：短期：脏标记改用 Go 的 configuration_fingerprint 比较；导入导出改走 Go 的 ImportProfile/ExportProfile。长期：请作者决定移动端是否收敛到 Profile Next（schema 3），以及是否与 macOS 共用一份 Swift 模型包。
- 注意：导入导出格式变化会让用户手里已导出的 mobile JSON 失效，需要保留一个只读的旧格式导入，或者明确声明不再兼容。

**P140　生产代码中无法到达的死代码**　〔dead｜未复核｜可删约 230 行〕

- 结论：看到的事实，逐项：TunnelManager.serverAddress(for:) 零调用；TunnelManager.bind(engine:) 零调用；AppState.isTailscaleLineGeneratedByRunningProfile 零调用；AppState.activeTailscaleLineIDs 只有测试在用；GoEngine.start/stop 与 Provider 的 "start"/"stop"/"parse-sub" 分支只在 tunnelManager == nil 时被走到，而 iOS 生产环境恒注入 TunnelManager（MobileIntentHost:29-35），tvOS 真机是 Noop，Simulator 是 Fake，所以任何构建都到不了；GoEngine.handleMessage/handleEvent/handleResponse 与 EngineStatus.scenarioID/connectedAt 是 macOS socket 协议的残留，Provider 的 encodeResponse 只输出 ok/message/data，从不带 event/id；DataPathProbe.Result 的 isUsable/linesReachable/splitRoutingOK/diagnosticSummary/failureMessage/withRoutingEvidence 生产上不用，directLineEgressIP/anyConnectLineEgressIP 恒传 nil；RoutingProbeSnapshot.provesConfiguredRouting(after:)（注释为“兼容旧断言”）只有测试在用；KeychainStore 的 load(account:)、delete(account:) 和静态 legacyVaultFileURL 零调用，save(password:) 只有测试在用；Provider 诊断里给“旧 App”写的 physical_interface_* 键也无意义，因为 App 与扩展在同一个 bundle 内一起升级。
- 位置：appletv/XDialTV/TunnelManager.swift:2267-2281；appletv/XDialTV/TunnelManager.swift:938-941；appletv/XDialTV/AppState.swift:2549-2554；appletv/XDialTV/AppState.swift:535-543；appletv/XDialTV/AppState.swift:1192-1194；appletv/XDialTV/AppState.swift:1253-1255；appletv/XDialTV/GoEngine.swift:83-108；appletv/XDialTV/GoEngine.swift:411-449；appletv/XDialTV/GoEngine.swift:473-492；appletv/XDialTVTunnel/PacketTunnelProvider.swift:784-801；appletv/XDialTVTunnel/PacketTunnelProvider.swift:1314-1316；appletv/XDialTV/TunnelManager.swift:321-379；appletv/XDialTV/TunnelManager.swift:646-663；appletv/XDialTV/KeychainStore.swift:129-130；appletv/XDialTV/KeychainStore.swift:227-248
- 建议：直接删除，并同步删除测试 testDisconnectWithoutManagerFallsBackToEngineStop、testRequiresBothLinesBeforeTestingRouting 等专测死代码的用例。
- 注意：低。RoutingProbeSnapshot 的六个计数字段目前用 decode（必填）解码，Go 仍然在输出，删除方法时把这些字段改成可选或一并删除即可；若删 GoEngine.start/stop，需要从 TunnelEngine 协议中同步去掉。

**P141　敏感字段清单、Tailscale 状态解析、标识常量、场景切换入口多处各写一份**　〔duplication｜未复核｜可删约 150 行〕

- 结论：看到的事实：线路敏感字段的枚举出现 7 次：AppState 的 persist 全角清洗 1329-1341、splitSensitiveValues 1456-1468、containsSensitiveValues 1665-1671、restoreStructuredValues 1690-1702，MobileConfigurationService.removeCredentials 157-167，MobileDiagnosticsService.sensitiveValues 438-447，Provider 的 collectDiagnosticSensitiveValues 1360-1365。Tailscale backend_state 的解析（running/needslogin/needs_login/needsmachineauth/needs_machine_auth）有 5 份：AppState 2349-2357 和 2681-2690、TunnelManager 1540-1572、ConfigurationView 672 和 1024-1035。authURL 校验有 2 份独立实现：AppState 2517、TunnelManager 1639。脱敏实现 2 份：MobileDiagnosticsService.redacted 和 Provider.sanitizedDiagnosticText。App Group 和 bundle id 字面量 4 处（另加 project.yml）。normalizedASCII 拷自 macOS ASCIIField.swift（注释 302-303 自认“独立复制一份”）。设置活动场景有 5 个入口直接写 app.profile.activeScenarioID 再 save()：HomeView、ScenariosView ×2、MobileIntentHost、tvOS ScenarioPickerView。推断：新增一个协议（例如 macOS 已有的 AnyTLS）需要同步改 7 处，漏一处就会让凭据留在 UserDefaults 或诊断里。
- 位置：appletv/XDialTV/AppState.swift:1329-1341；appletv/XDialTV/AppState.swift:1456-1468；appletv/XDialTV/AppState.swift:1665-1671；appletv/XDialTV/AppState.swift:1690-1702；ios/XDialIOS/MobileConfigurationSupport.swift:157-167；ios/XDialIOS/MobileConfigurationSupport.swift:418-468；appletv/XDialTVTunnel/PacketTunnelProvider.swift:1332-1398；appletv/XDialTV/AppState.swift:2349-2357；appletv/XDialTV/AppState.swift:2681-2690；appletv/XDialTV/TunnelManager.swift:1540-1572；appletv/XDialTV/TunnelManager.swift:1639-1644；ios/XDialIOS/ConfigurationView.swift:672；ios/XDialIOS/ConfigurationView.swift:1024-1035；ios/XDialIOS/HomeView.swift:217-219；ios/XDialIOS/ScenariosView.swift:34-35；ios/XDialIOS/ScenariosView.swift:175-176；ios/XDialIOS/MobileIntentHost.swift:113-114；appletv/XDialTV/ScenarioPickerView.swift:80-81；appletv/XDialTV/AppState.swift:302-324
- 建议：抽出 Line.sensitiveKeyPaths 作为唯一清单，供 vault 拆分/恢复、导出、诊断复用；建立 TailscaleBackendState 枚举和唯一的 authURL 校验；新增 AppState.activateScenario(id:) 作为唯一入口；把标识常量集中到一个共享文件。
- 注意：低；vault 的 key 拼法不能变，否则已保存的凭据会丢。

**P142　LocalTailscaleSetupRuntime 仍按 utun/ipsec/ppp 前缀过滤 Underlay（Provider 修了，副本没修）**　〔boundary-violation｜复核成立｜可删约 10 行〕

- 结论：048b878（07-28）从 PacketTunnelProvider 删除了按 utun/ipsec/ppp 前缀过滤 Underlay 的逻辑，并写明理由。但 c3feaa9（07-26）创建的 ios/XDialIOS/LocalTailscaleSetupRuntime.swift 从未再修改，至今保留 selectPhysicalInterface/isTunnelInterface 的前缀过滤，只调用 setDefaultInterface，不发布 setNetworkInterfaces 的完整快照。
- 位置：ios/XDialIOS/LocalTailscaleSetupRuntime.swift:189-199；ios/XDialIOS/LocalTailscaleSetupRuntime.swift:572-586；appletv/XDialTVTunnel/PacketTunnelProvider.swift:118-120；appletv/XDialTVTunnel/PacketTunnelProvider.swift:1148-1150
- 建议：抽一个共享的 UnderlaySnapshot 构造器（Provider 和 setup 会话共用），发布完整的 availableInterfaces，不按前缀筛选；按规则修掉这一类问题，而不是只改这一个函数。
- 注意：ARCHITECTURE §3.1 的“不按名称前缀筛选、不取首候选”位于“macOS 与 Underlay”小节，不能直接套用到 iOS。约束 iOS 的是 §1（Underlay 不按产品拆解）和 platform.go 的注释。Provider 的 availableInterfaces.first 在 iOS 上就是系统给出的优先顺序，是否违规需要作者确认。这个修改不是删除，而是改为共享快照构造器，净删很少。设置会话只能在没有正式隧道时运行（canMutateConfiguration），影响面是“设备已有其他 VPN 时 Tailscale 登录会话绕过该 VPN”，需要实机验证。

**P143　AppState 一个类型承担 9 类独立职责（2808 行）**　〔mixed-responsibility｜未复核｜可删约 0 行〕

- 结论：可以拆出的块：1-406 是协议、类型和持久化上下文（TailscaleRuntime 类型、TunnelEngine/TunnelManaging、ParseResult、AppPersistenceContext、ProfilePersistenceEnvelope、normalizedASCII）；545-983 是配置校验（应交给 Go）；1074-1293 是连接状态机和自动重连；1295-1747 是持久化 vault；1749-2113 是旧格式迁移；2147-2320 是订阅；2322-2692 是 Tailscale 设置和运行时编排；2694-2765 是场景；2768-2808 是 Noop 和模板。tvOS UI 只用到其中约 12 个成员（profile/tr/save/activeScenario/isConnected/isBusy/canConnect/connect/disconnect/statusText/helperInstalled/language），其余都是 iOS 的需求。UI 层（ConfigurationView/HomeView/ScenariosView/MobileIntentHost）大量直接修改 app.profile，绕过 AppState 的保护（canMutateConfiguration 由调用方自己检查）。ConfigurationView 在 386/1700/1833 行用 `(app.engine as? GoEngine) ?? GoEngine.shared` 穿透引擎抽象，在 Simulator 下会直接用到真实的 Libbox 单例。
- 位置：appletv/XDialTV/AppState.swift:1-406；appletv/XDialTV/AppState.swift:545-983；appletv/XDialTV/AppState.swift:1074-1293；appletv/XDialTV/AppState.swift:1295-1747；appletv/XDialTV/AppState.swift:1749-2113；appletv/XDialTV/AppState.swift:2147-2320；appletv/XDialTV/AppState.swift:2322-2692；ios/XDialIOS/ConfigurationView.swift:386；ios/XDialIOS/ConfigurationView.swift:1700；ios/XDialIOS/ConfigurationView.swift:1833
- 建议：按块拆成 ProfileStore（持久化+vault，迁移单独成文件或删除）、ConnectionController（状态机、自动重连、连接/断开、场景激活）、SubscriptionService、TailscaleSetupCoordinator；配置变更统一走 Store 的方法，UI 不直接写 profile。
- 注意：测试几乎都通过 AppState 驱动（AppStateTests 3009 行），拆分时要同步迁移测试替身。

**P144　TunnelManager 混合了 NE 管理、按需重连、验收、Tailscale 轮询、诊断格式化，还有第二个 Provider RPC 客户端**　〔mixed-responsibility｜未复核｜可删约 80 行〕

- 结论：可以拆出的块：29-138 是并发小工具；140-722 是验收计划和探针模型（约 580 行）；724-846 是策略和诊断格式化；848-879 是会话包装；886-1346 是 NE 偏好、按需重连和状态映射；1348-1690 是验收编排和 Tailscale 就绪轮询；1692-1941 是 RPC 包装和失败处理；1943-2263 是启动/停止。GoEngine 已经是 Provider 的 RPC 客户端，但 TunnelManager 又绕过它，直接对 providerSession 写了 5 个几乎一样的 sendProviderMessage + OneShotContinuation + 超时包装（1646-1690、1776-1825、1827-1851、1853-1877、1879-1902）。文件头仍写着“本文件是「薄骨架」”，并保留 6 处“真机联调 TODO”，与 2303 行且已经实机验证（ff40066）的现状不符。
- 位置：appletv/XDialTV/TunnelManager.swift:10-27；appletv/XDialTV/TunnelManager.swift:1646-1902；appletv/XDialTV/GoEngine.swift:326-409；appletv/XDialTV/TunnelManager.swift:867-871；appletv/XDialTV/TunnelManager.swift:949-952；appletv/XDialTV/TunnelManager.swift:1218-1238；appletv/XDialTV/TunnelManager.swift:1983-1985
- 建议：建立唯一的类型化 ProviderClient（async，自带超时），GoEngine 和 TunnelManager 都改用它；验收/Tailscale 轮询（如果保留）拆到 ConnectionAcceptance；NE 偏好和按需重连单独成 SystemTunnelProfile；删除过期的骨架注释和 TODO。
- 注意：中等：按需重连与验收之间的时序（dataPathVerified → arm）要保持不变。

**P145　测试固化了死代码、过期语义和不可能发生的迁移**　〔test-bloat｜未复核｜可删约 150 行〕

- 结论：看到的事实：AppStateTests（3009 行）前约 400 行是 8 个专用替身类；1162-1194、2099-2139、2322-2360 固化了“Tailscale 全局生成”的过期语义；2274-2321 和 2656-2907 测试旧迁移（其中比喻 key、逐条 Keychain 的路径在移动端没有数据来源）；1713-1722 测试生产上到不了的 engine.stop 回退；DataPathProbeTests 240-296 和 312-340 测试 DataPathProbe.Result.isUsable 与旧版 provesConfiguredRouting(after:)，二者在生产上都无调用。
- 位置：ios/XDialIOSTests/AppStateTests.swift:1-399；ios/XDialIOSTests/AppStateTests.swift:1162-1194；ios/XDialIOSTests/AppStateTests.swift:1713-1722；ios/XDialIOSTests/AppStateTests.swift:2099-2139；ios/XDialIOSTests/AppStateTests.swift:2274-2360；ios/XDialIOSTests/AppStateTests.swift:2656-2907；ios/XDialIOSTests/DataPathProbeTests.swift:240-296；ios/XDialIOSTests/DataPathProbeTests.swift:312-340
- 建议：随对应生产代码一起删除；替身类合并成一个可配置的 SpyEngine/SpyManager。（这里只计替身合并带来的约 150 行，避免与其他问题重复计数。）
- 注意：低；注意别误删 vault revision 配对、按需信封等仍然有效的测试。

**P146　PacketTunnelProvider 的事故叠加残留：同一份 NE 设置应用两次，旧 App Group 清理写了两份**　〔accretion｜未复核｜可删约 40 行〕

- 结论：看到的事实：AnyConnect 路径在 254 行和 317 行两次调用 buildNetworkSettings(remoteAddress: remoteIPv4)，参数完全相同；在两次之间读取 tunnelNameServers 只用于判断非空，读到的值并没有进入设置（注释说“握手 DNS 只用于确认企业 resolver 可用”）。清理旧 App Group 明文 key 的逻辑同时存在于 Provider（76-82、1007-1010）和 App（TunnelManager 925、1947-1960、2110）。推断：第二次 setTunnelNetworkSettings 是早期“下发企业 DNS”方案的遗留；如果它被用来刷新 DNS 缓存，注释里没有写明。
- 位置：appletv/XDialTVTunnel/PacketTunnelProvider.swift:254；appletv/XDialTVTunnel/PacketTunnelProvider.swift:309-337；appletv/XDialTVTunnel/PacketTunnelProvider.swift:76-82；appletv/XDialTVTunnel/PacketTunnelProvider.swift:1006-1010；appletv/XDialTV/TunnelManager.swift:922-925；appletv/XDialTV/TunnelManager.swift:1943-1960；appletv/XDialTV/TunnelManager.swift:2110
- 建议：确认第二次设置是否有意（用于刷新 DNS）：无意就删掉，有意就补注释。旧 App Group 清理只保留一处（Provider 每次启动时），并定一个删除期限。
- 注意：去掉第二次 setTunnelNetworkSettings 可能影响引擎启动后系统 DNS 缓存的行为，需要实机验证。

**P147　Simulator 演示与 UI 测试夹具混在 App target 里，演示凭据写入生产持久化**　〔mixed-responsibility｜未复核｜可删约 60 行〕

- 结论：看到的事实：FakeTunnel.swift 整个文件包在 #if targetEnvironment(simulator) 里，真机和发布产物不包含，属于脚手架而不是发布路径。但非 UI 测试的普通 Simulator 运行也会走 seedDemoDataForSimulator，用 .production 持久化上下文写入 DemoCredentials（connect.demo.example.com/demo/demo123）和两个场景；7 个 -XDialUITesting* 启动参数分支（约 120 行夹具）写在 App 代码里。tvOS 的 DebugSmokeTest 没有包 #if DEBUG，Release 也会编译进去，只是没有入口。
- 位置：appletv/XDialTV/FakeTunnel.swift:405-592；ios/XDialIOS/MobileIntentHost.swift:13-27；ios/XDialIOS/XDialIOSApp.swift:46-48；appletv/XDialTV/DebugSmokeTest.swift:1-61
- 建议：夹具改为由 UI 测试通过 launchEnvironment 注入一份 profile JSON；普通 Simulator 不再往生产 key 写演示数据；DebugSmokeTest 随 tvOS 一起删除，或者包进 #if DEBUG。
- 注意：低；HomeViewUITests（911 行）依赖这些启动参数，需要同步修改。

需要作者回答的问题：

- tvOS 现在还是在维护的产品线吗？真机构建用的是 NoopTunnelEngine、根本连不上：是删掉 tvOS 目标（把共享源文件搬到 ios/ 下），还是接上真实的 GoEngine/TunnelManager 并加进 CI？
- 2026-07-19 至 08-08 之间有没有把 iOS 构建分发出去（TestFlight 或别人的设备）？那一时期持久化的是 modes/active_mode_id 和扁平 vault key：如果有，需要补一条 modes→scenarios 迁移；如果没有，扁平 vault、旧 vault 文件迁移也可以一起删掉。
- 1.0.0.1/1.1.1.1 的锁定验收规则，加上“任一线路或探针失败就自动断开”，是不是移动端有意的产品契约？它与 ARCHITECTURE §4.3 冲突；能否改用 Go 的 EnsureActiveLinesReady 按 Line 就绪，并迁移掉用户 profile 里的 xdial-connectivity-* 规则？
- 移动端要不要收敛到 macOS 的 Profile Next（schema 3、Go 导入导出、线路组、AnyTLS、ConnectionPlan 指纹）？还是继续维持单 Profile + 自有 xdial-mobile-configuration 格式？
- DESIGN §4.2 规定已连接时点击其他场景执行 Switch；iOS 现在要求先断开（Home 和快捷指令都会拒绝）。移动端需要候选 Switch 吗？还是“断开再重连”就是移动端认可的语义？
- PacketTunnelProvider 的 AnyConnect 路径对同一份 NE 设置应用两次（254 行和 317 行），这是有意用来刷新系统 DNS 缓存，还是早期“下发企业 DNS”方案的遗留？

### 横切：跨平台重复与改动热点

**P148　移动端用 Swift 重新实现了 Go 的 Profile 校验、依赖闭包、outbound tag 与运行指纹**　〔boundary-violation｜复核修正｜可删约 350 行〕

- 结论：方向成立：移动端在 Swift 里自行实现了连接前判定（configurationIssues/routeLineConfigurationIssues/appendTargetIssue）、两份逐行相同的 Clash 组 REJECT 不动点、自拼 outbound tag、用整份 Profile JSON（抹掉 verified/tailscaleAuthenticated）比较 hasPendingRuntimeChanges，以及 MobileConfigurationService.validate，没有调用 Go 已导出的 GenerateConnectionPlan/ValidateProfileDocument。但审计员举的漂移例子“lineTag 漏掉 anytls”在移动端走不到：移动端 Line 模型没有 anytls 字段，导入白名单 supportedLineTypes 也不含 anytls。真正存在的漂移是订阅节点可用性：Swift 只认 trojan/shadowsocks/vmess，Go 的 subscriptionNodeUsable 还包含 AnyTLS。不过这一点又被 P150 的解码丢字段掩盖了。
- 位置：appletv/XDialTV/AppState.swift:557-984；appletv/XDialTV/AppState.swift:1414-1437；appletv/XDialTV/AppState.swift:2322-2324；appletv/XDialTV/TunnelManager.swift:145-308；appletv/XDialTV/Models.swift:456-540；ios/XDialIOS/MobileConfigurationSupport.swift:205-347
- 建议：在 Go 侧给移动端导出两个入口：(a) 结构化的连接前 issues（代码+对象ID，复用 BuildConnectionPlan/ValidateDocumentProfile 的同一逻辑）；(b) 带配置指纹的 ConnectionPlan（mobile 也调用 LibboxGenerateConnectionPlan）。Swift 只负责本地化渲染和比较指纹。删掉 Swift 的 lineTag、effectiveReferencedLineIDs、runtimeProfileData、两份不动点求解和 MobileConfigurationService.validate。
- 注意：550 行与 P134/P149 有重叠：TunnelAcceptancePlan（TunnelManager.swift:145-306）和 Models.swift:456-540 的 connectivityOutboundBinding 属于验收机制，应计在 P134。只算本条：AppState 校验约 375 行，MobileConfigurationService.validate 约 140 行，runtimeProfileData 约 20 行，减去 Swift 端渲染 Go issue 代码与本地化所需的新增代码，净删约 350 行。MobileConfigurationService.validate 校验的是移动端导入 JSON 的形状和类型白名单，Go 的 ValidateProfileDocument/ValidateDocumentProfile 不一定覆盖同样的移动端限制（例如移动端不支持的 native/application/group 规则和 anytls），替换前必须逐条对照。Go 端需要先导出结构化 issue（代码加对象 ID），否则 Swift 只能拿到英文 error 字符串。iOS 不在 CI 里，必须手工跑 make ios。

**P149　移动端连接验收依赖固定外部 IP 探针，并向每个场景注入两条验收 RuleSet**　〔boundary-violation｜复核修正｜可删约 0 行〕

- 结论：机制事实成立：连接后主 App 请求 1.0.0.1/1.1.1.1 的 cdn-cgi/trace 和 www.apple.com；每个目标经 probe-outbound-address 走 Go 的 1.1.1.1 trace；再比对 routing probe 计数；任何一项失败就自动断开。每次 init/persist 都会把两条 xdial-connectivity-* RuleSet 强制写到每个场景 bindings 的最前面，规则不可禁用；缺少或被改动时拒绝连接。这与 ARCHITECTURE §4.3 和 §2（供给规则可禁用、可不用）冲突。来源提交应为 c56cda4（07-23），ff40066 是在其上的强化。此外，由于 P028，这套验收从 a5f761f 起不可能通过。
- 位置：appletv/XDialTV/TunnelManager.swift:310-575；appletv/XDialTV/TunnelManager.swift:587-722；appletv/XDialTV/TunnelManager.swift:1351-1490；appletv/XDialTV/TunnelManager.swift:1704-1880；appletv/XDialTV/Models.swift:123-137；appletv/XDialTV/Models.swift:418-455；appletv/XDialTV/Models.swift:540-583；appletv/XDialTV/AppState.swift:628-660；ios/XDialIOSTests/DataPathProbeTests.swift:1-422
- 建议：先由作者确认这是不是有意保留的移动端例外。若不是，让移动端改用 Go 的 Line 就绪证明（Libbox 已有 EnsureActiveLinesReady/LineReadiness），删除 DataPathProbe、TunnelAcceptancePlan、验收 RuleSet 注入与对应测试，并加一次性迁移，从已保存的 Profile 中剔除 xdial-connectivity-* 两条 RuleSet 与 binding。
- 注意：本条与 P134 描述的是同一套机制，行数统一计入 P134（约 900 行），这里写 0，避免重复计数。审计员的风险判断有误：删除后并不会“失去现有的连上即验证保护”。按 P028，tracker 在移动端从未安装，这套验收现在只会把每次连接判为失败并断开（推断，未实机验证）。所以它目前不是保护，而是故障源。其余风险仍然成立：需要一次性迁移，从已保存的 Profile 里剔除两条 xdial-connectivity-* RuleSet 和对应 binding，否则 1.1.1.1/32 会继续被导向第一条非 Direct 线路；OnDemandStartEnvelope 里的 acceptance_plan（PacketTunnelProvider.swift:1038-1050）也要一并修改。

**P150　两份 Swift 领域模型：重复 67% 且已漂移，移动端解码会静默丢字段**　〔duplication｜复核修正｜可删约 300 行〕

- 结论：移动端（tv）Models.swift 手工镜像 Go 模型，且已经漂移。Line 缺少 anytls_*（9 个）、udp、tfo、group_*、native_options、identity_*；RuleSet 缺少 fetch_line_id、invert、applications、processes、native_rule、conditions，以及审计员漏掉的 no_resolve。移动端多出 Go 不认识的 tailscale_authenticated。关键缺陷属实：iOS 订阅刷新把 LibboxParseSubscription 的结果解码进移动端 Line 后原样保存，udp/tfo 和全部 anytls 字段被静默丢弃。所以同一份订阅在 iOS 上生成的出站与 macOS 不同（没有 udp_over_tcp/tcp_fast_open），AnyTLS 节点则会静默变得不可用。“67% 重叠”的数字取决于统计口径。
- 位置：macos/Sources/XDial/Models.swift:1-980；appletv/XDialTV/Models.swift:1-410；appletv/XDialTV/GoEngine.swift:111-137；appletv/XDialTV/AppState.swift:20-40
- 建议：抽出一个共享 Swift 包（如 XDialModel），macOS 与 iOS/tvOS 都引用它，字段以 Go 为准；增加契约测试：用 Go 生成的 fixture（全字段）做 Swift decode→encode 往返，要求等值，覆盖两个平台。移动端不支持的协议在 UI 层隐藏，不在模型层丢弃。
- 注意：RuleSet 缺的 applications/processes/native/group 大多是 macOS 专属能力，移动端导入白名单（MobileConfigurationSupport.swift:291-294）只允许 url 和 manual，会直接拒绝这些类型，算不上静默丢失。真正会静默丢失的是导入 url/manual 规则时的 invert、fetch_line_id、no_resolve，以及订阅刷新路径上的 udp/tfo/anytls。抽共享包时，移动端特有的 connectivity 扩展（约 170 行，属于 P134）和 tailscale_authenticated 需要另行处理：已持久化的数据要能兼容读取，Go 侧也要确认这个字段被忽略而不是被拒绝。mac 版字段默认值（例如 anytlsClientFingerprint="chrome"）与移动端 UI 的假设可能不同。保守估计净删约 300 行，不是 400 行。最小修复是给移动端 Line 补齐字段并加契约测试，不需要等共享包。

**P151　移动端停在上一代连接架构，且 CI 从不编译 iOS/tvOS**　〔legacy｜未复核｜可删约 0 行〕

- 结论：macOS 走 GenerateConnectionPlan → 会话 envelope → ConnectionReport/journal → Switch 与 Line 租约；iOS/tvOS 走 GenerateNEConfig → engine.startResolved/startStandalone，状态来自 status JSON 回调，没有 transaction ID，场景切换一律走 reconnectToApplyChanges 完整重连，配置也没有进入 schema 3 全局场景库（ARCHITECTURE §2 的 Next 配置库只在 macOS 实现）。docs/plans/profile-subscriptions.md:72 规划“iOS / tvOS 复用同一模型与导入结果”，至今没有落地。这种分叉是上面三条重复问题的根因：移动端没有 Go 的计划与报告，只能自己在 Swift 里补校验和验收。移动端 Swift 约 14.2k 行，测试约 4.9k 行，但 .github/workflows/ci.yml 只跑 go-vet/go-build/test/ci-macos-build/test-macos-transaction；appletv/project.yml:17-19 的注释记录过 tvOS 因漏引用文件而构建断裂。
- 位置：appletv/XDialTV/TunnelManager.swift:1986-2250；appletv/XDialTV/AppState.swift:1169-1265；appletv/XDialTVTunnel/PacketTunnelProvider.swift:156-412；core/libbox/configgen.go:240-245；appletv/project.yml:17-19；.github/workflows/ci.yml:16-59
- 建议：先决定平台范围（见 questions）：要么把 iOS 迁到 Go 计划/报告路径（GenerateConnectionPlan 已与平台无关），并把 `make ios` 加入 CI；要么明确冻结 tvOS（删除 tvOS 专属 UI 约 590 行，只保留 iOS 共用文件）。在作出决定前，不建议继续往移动端 Swift 里补规则。
- 注意：迁移涉及 Packet Tunnel 启动协议与 App Group 中已持久化的启动 envelope（OnDemandStartEnvelope），需要兼容按需连接（On-Demand）已经武装的旧版本。

**P152　macOS 在 Next 配置库切换后遗留约 500 行无调用方代码**　〔dead｜复核成立｜可删约 520 行〕

- 结论：ec2f29d 和 76e746c 之后，macOS 留下的无调用方代码包括：KeychainStore、ProfileVaultProjection 及其测试、比喻命名迁移、AppState 的 add/update/deleteSubscription、GoEngine 的 parseSubscription/sendSubRequest/ParseResult/EngineStatus、Models 的三个场景模板。各项逐一核实为死代码，合计约 580 行，按 520 行保守计。
- 位置：macos/Sources/XDial/KeychainStore.swift:1-173；macos/Sources/XDial/ProfileVaultProjection.swift:1-75；macos/Tests/ProfileVaultProjectionTests.swift:1-89；macos/Sources/XDial/AppState.swift:2702-2777；macos/Sources/XDial/AppState.swift:2792-2829；macos/Sources/XDial/GoEngine.swift:69-80；macos/Sources/XDial/GoEngine.swift:397-428；macos/Sources/XDial/GoEngine.swift:697-728；macos/Sources/XDial/GoEngine.swift:977-997；macos/Sources/XDial/Models.swift:1007-1040
- 建议：直接删除上述符号及 ProfileVaultProjectionTests.swift，并从 macos/project.yml 的 XDialTests 源列表中移除 ProfileVaultProjection.swift。daemon 的 parse-sub 处理（cmd/xdial/daemon.go:353-361）在 App 里已无发送方，CLI 的 cmd_sub.go 直接调用 subscription.Parse，可以一并评估删除（registration_handoff_test.go:86 的命令列表需同步）。
- 注意：①registration_handoff_test.go:86 中的 "parse-sub" 只是一个「非诊断命令」样例（同一列表里还有 "unknown"），删除 daemon 的处理分支后测试仍然通过，不必须同步。②删除 daemon 的 parse-sub 后，protocol.go:16-18 的 SubURL/SubContent/SubFormat 字段，以及 GoEngine.swift:4、:875 提到 parse-sub 的注释也随之失效，应一并清理。③daemon 与 App 来自同一个 bundle，不存在旧 App 对新 daemon 的兼容需求。④与 P060、P064、P065、P078、P080、P083 重叠，汇总时只计一次。

**P153　Libbox 导出面以 With… 后缀变体堆叠，多数变体只剩测试调用，Makefile 门禁还把变体名写死**　〔accretion｜复核修正｜可删约 85 行〕

- 结论：“导出面以 With… 变体堆叠”的方向成立：GenerateTransparentProxySession（无后缀，只有测试调用）、…WithCallback（零调用）、GenerateTransparentProxyRuleSetBootstrap（无后缀，只有测试调用）、SetTunOpener（Go 中零调用，gomobile 也不导出）可以删除，PrepareSwitch / Start 变体与 P017 重复。但 ProbeOutboundIPForFamily 无 Swift 调用的说法是错误的：Swift 通过拆分后的 probeOutboundIP(forFamily:…) 在生产中调用它，它和 address_probe_policy.go 都必须保留。Start 也不只被 DebugSmokeTest 调用（cmd/libboxtest 也在用）。Makefile:216-217 只钉住 Swift 实际使用的两个变体名，218-219 钉的是 TLS probe 名，不妨碍删除死变体。400 行与 P017/P018 大量重复计算，扣除重复后独有可删约 85 行。
- 位置：core/libbox/configgen.go:247-360；core/libbox/configgen.go:398-430；core/libbox/libbox.go:1024-1120；core/libbox/libbox.go:1565-1760；core/libbox/libbox.go:333；core/libbox/libbox.go:576-600；core/libbox/tailscale_status_gvisor.go:299-310；core/libbox/tailscale_status_gvisor.go:442-515；Makefile:216-219；macos/TransparentProxyExtension/EmbeddedSingBoxRuntime.swift:1185-1225
- 建议：每个能力只保留 Swift 实际调用的那一个入口；以后新增参数统一通过 options JSON 传入，不再新增导出名；active/preparedSwitch 两套 API 改为传 generation 参数。同步删除 Makefile:216-219 这类钉死名字的门禁，改为行为测试。把只覆盖已删变体的测试改写为覆盖保留入口。
- 注意：凡是以“Swift 0 命中”为依据删除导出的，都必须按 Libbox.objc.h 推导的 Swift 名（With/For 会被拆成参数标签）重新核对。本条中的 ProbeOutboundIPForFamily 就是这种误报，误删会破坏设置页的线路出口地址探测。无后缀的 GenerateTransparentProxySession 在测试中有 8 处调用，要改写而不是直接删除，以保住覆盖面。把 active / preparedSwitch 两套 API 合并为“传 generation 参数”是重构，不是删死代码，收益应单独评估，不能计入可删行数。

**P154　HomeDERP 重选：上游补丁、Libbox 与 Swift 都在维护，但生产代码中没有任何调用入口**　〔dead｜复核修正｜可删约 700 行〕

- 结论：HomeDERP 重选在 Swift、cmd、DebugServer、IPC 中都没有入口，删除方向成立，但剥离方案和风险描述有事实错误。补丁 0009 改的是 XDialNormalizeNetInfoForControl 的签名和语义，以及 setNetInfo，并没有改 XDialPrepareHomeDERPReselection / xdialPickAlternateDERP（那两处只是 hunk 上下文）。0009 实现的是通用的过期 NetInfo 回调拒绝，并把 PreferredDERP 规范化为 myDerp，直接影响生产就绪事实 preferredDERPRelation / SetForCurrentClient，必须保留并迁出重选文件。0005 的 local.go 中还有与重选无关的 SetControlClientStatus 旧 client 防护和 xdialNetInfoSendMu，也要保留。NetInfo receipt（xdial_update.go 等）并没有被就绪事实使用，只有重选在消费它；删掉它会让 SetNetInfo 的去重行为回到上游，属于行为变化，不是纯删死代码。
- 位置：patches/tailscale/0005-add-bounded-homederp-reselection.patch；core/libbox/tailscale_status_gvisor.go:521-574；core/libbox/tailscale_status_stub.go:36-40；macos/Shared/TailscaleReadiness.swift:16-26；macos/Shared/TailscaleReadiness.swift:441-482
- 建议：请作者决定：若近期没有接入 Debug/UI 维护入口的计划，就删除 Libbox.ReselectTailscaleHomeDERP 与 stub、Swift 的三处判定代码与对应测试，从 patch 0005 中剥离 reselection 文件，并重新生成 patch 0009；同时把 ARCHITECTURE §3.2 的表述改为现状。
- 注意：剥离时必须保留并迁移以下内容：XDialNormalizeNetInfoForControl（去掉 pin 逻辑，保留 netInfoLast 指针校验和 myDerp 规范化）、setNetInfo 中的 xdialNetInfoSendMu、SetControlClientStatus 旧 client 防护、TestXDialNetInfoControlBoundaryRejectsSupersededCallbacks。prepare-patched-go-mod.sh 中 351-367 行的 grep 保留，只删 311-350、369 等纯重选的检查，以及 403-409 针对重选文件的禁用 hook 检查。删除 receipt 会恢复上游的 SetNetInfo 去重，需要 make test-patched-tailscale 加真实 Tailscale 线路回归。0006 和 0009 都要重新生成。ARCHITECTURE.md:133 和 d35 §4 的表述要同步修改。

**P155　失败的重试资格靠 Swift 白名单与错误文本转译决定，与酒店事故同类的问题仍未消除**　〔accretion｜未复核｜可删约 40 行〕

- 结论：Go 已经在源头把 Line 就绪失败分成 transient/terminal（core/libbox/line_network_readiness.go:95-107 readinessErrorCode）。但 Provider 先把错误包成 Swift 的 RuntimeError，在 EmbeddedSingBoxRuntime.reportCode 里映射出约 20 个字符串码，未列出的落入 "scenario-switch-prepare-failed"；AutomaticLineReadinessFailurePolicy 再用一份 5 个码的白名单映射回 "line-readiness-transient"。2026-09-20 的酒店事故正是在这一转译层丢失了分类（waitForTailscale 把结构化错误改成文字），修复 6b21331 只补了这一个分支。同类问题仍存在于 LineLatencyStore.swift:512：`error.localizedDescription.contains("probe-busy")`，而 ProviderDiagnosticsHostError.providerRejected(code) 本身就带结构化 .code，Provider 发送的也是 code:"probe-busy"。更干净的规则是：失败在源头带上 retryClass（transient/terminal/cancelled），各层只透传，任何一层都不维护来源码的白名单，也不按文本匹配。
- 位置：macos/Shared/AutomaticLineReadinessFailurePolicy.swift:1-20；macos/TransparentProxyExtension/EmbeddedSingBoxRuntime.swift:3141-3172；macos/Sources/XDial/LineLatencyStore.swift:505-514；macos/Sources/XDial/TransparentProxyManager.swift:4011-4045；macos/Shared/AutomaticScenarioSwitchRetryPolicy.swift:3-14；macos/Shared/AutomaticReconnectRetryPolicy.swift:3-7；core/libbox/line_network_readiness.go:95-107
- 建议：LineLatencyStore 改为 `(error as? ProviderDiagnosticsHostError)?.code == "probe-busy"`（立即可做）；ConnectionRuntimeFailure 增加 retryClass 字段，由 Go readinessErrorCode 与 Provider 原生错误在源头填写，删除 AutomaticLineReadinessFailurePolicy 白名单，宿主只读 retryClass；错误码常量集中到一个 Shared 文件。
- 注意：低到中。改动发生在 Provider↔Host IPC 的报告字段上，需要兼容旧 Provider 写下的 journal（缺少 retryClass 时按 terminal 处理）。

**P156　Tailscale 协议恢复决策写在 Swift Provider 中**　〔boundary-violation｜未复核｜可删约 250 行〕

- 结论：waitForTailscale（约 445 行）读取 Go 导出的 control generation、NetInfo receipt、home DERP 状态与 key 关系、peer DERP 写路径序号等内部事实，由 Swift 判定失败分类（classifyTailscaleReadinessFailure），以及何时释放非 home DERP（shouldReleaseTailscaleNonHomeDERP，6ab2759 于 2026-10-13 新增）。TailscaleReadiness.swift 507 行几乎都是对 Tailscale 内部状态机的镜像。ARCHITECTURE §5.4 规定“Line 自己处理协议恢复”，§1 规定 Swift 宿主只负责“用户意图、平台生命周期、结构化状态展示”，§3.2 规定“握手失败归因到该 Line，不靠……固定 DERP……解决”。现在是 Swift 在驱动 Go 内的 DERP 连接生命周期，两侧又通过 10 个 Tailscale 补丁传递细粒度事实，形成跨语言的紧耦合。这一区域的修复链：a5f761f → 6b21331 → 6678f90 → 6ab2759。
- 位置：macos/Shared/TailscaleReadiness.swift:1-507；macos/TransparentProxyExtension/EmbeddedSingBoxRuntime.swift:2156-2640；core/libbox/tailscale_status_gvisor.go
- 建议：在 Go 的 Tailscale runtime 中实现“等待就绪 + 有界清理非 home DERP”，对外只返回一个带 retryClass 的 LineReadiness 结果；Swift 只做超时与取消，以及展示结构化 evidence。TailscaleReadiness.swift 中只用于诊断展示的结构体（TailscalePeerDERPPath）可以保留为解码类型。
- 注意：中。Tailscale 现场问题难以复现（见事故记录），迁移时要保留现有的结构化 evidence 字段，以免诊断能力回退；需要把 Swift 测试移植为 Go 测试。

**P157　EmbeddedSingBoxRuntime 的 start() 与 prepareSwitch() 是两份近似实现，已被成对修改 7 次**　〔duplication｜复核成立｜可删约 0 行〕

- 结论：成立。我独立复核了历史：自 0abde98（2026-08-08）引入 prepareSwitch 以来，凡是改动 start 或 prepareSwitch 的非合并提交，都同时改了两者，正好是审计员列出的 7 个（d56a6f2、b6a91bb、417f5b6、05af780、ec2f29d、6678f90、ab650e4），没有任何提交只改其中一个。抽查发现 ec2f29d、6678f90、ab650e4 是把同一段改动逐字复制到两处。这一项与 P124 是同一个问题，应合并处理。
- 位置：macos/TransparentProxyExtension/EmbeddedSingBoxRuntime.swift:364-652；macos/TransparentProxyExtension/EmbeddedSingBoxRuntime.swift:653-938
- 建议：抽出共享的 generation 构建管线（envelope → readiness → tailscale → 应用凭据 → rule set），start 与 prepareSwitch 只在最后的 start/commit 步骤上不同；用 generation 参数取代成对的 Libbox API（见变体问题）。
- 注意：可删行数已计入 P124（约 90 行），这里记 0，以免重复计算。审计员 action 中“用 generation 参数取代成对的 Libbox API”属于另一个问题（变体 API），不在本条范围内。合并重构会碰到连接与切换的主路径，需要回归冷启动、Switch、地址族降级收敛、AnyConnect 不可复用转完整重连（dc364c3），以及带 Tailscale 的 Switch。

**P158　AnyConnect 凭据完整性在 5 处各写一份，“active VPN Line”在 Go 内部也有两种闭包语义**　〔duplication｜未复核｜可删约 100 行〕

- 结论：“AnyConnect 服务器/用户名/密码不能为空”这条规则写在：core/libbox/configgen.go:572-575（RuleSet 获取会话）、configgen.go:732-737（主会话）、core/engine/engine.go:250-255（旧 TUN，不做 TrimSpace）、macos/Sources/XDial/ConnectionConfigurationReadiness.swift:39-44（2e25d22 新增，注释写着“判定与 Go 生成器拒绝的条件一致”）、appletv/XDialTV/AppState.swift:689-698。更深一层：Go 的 Profile.ActiveVPNLine()（model.go:328-344）不过滤停用的 RuleSet，而 effectiveActiveVPNLineIDs/effectiveActiveTargetIDs（generator.go:817-938）会过滤；configgen 选择会话 AnyConnect 时用的是前者。macOS Swift 镜像了前者，移动端 Swift 镜像了后者，同一份 Profile 在两端可能得出不同的阻断结论。macOS 的 lineGroupMemberIssue 同样手抄了 Go validateGroupReferences 的规则（环、深度 32、vpn/tailscale 不入组、urltest 不含 Direct），ed91700 需要同步改它的文案就是这种重复的代价。
- 位置：core/libbox/configgen.go:571-584；core/libbox/configgen.go:731-745；core/engine/engine.go:249-256；macos/Sources/XDial/ConnectionConfigurationReadiness.swift:28-48；appletv/XDialTV/AppState.swift:668-698；core/config/model.go:328-344；core/config/generator.go:817-938；macos/Sources/XDial/Models.swift:1100-1150；core/config/native_resources.go:76-125
- 建议：在 Go 中保留唯一的 ValidateLineCredentials 与唯一的有效依赖闭包，删除或改写 Profile.ActiveVPNLine 使其基于 effectiveActiveTargetIDs；GenerateConnectionPlan 返回结构化 blocker（scenario/line/missing 字段），macOS 的 ConnectionConfigurationBlocker 只负责渲染；lineGroupMemberIssue 改为把候选 Profile 交给 LibboxValidateProfileDocument（或新增一个窄接口），用 Go 的判定结果。
- 注意：中。ActiveVPNLine 语义一改，“AnyConnect 只绑定在停用规则上”的场景是否启动 AnyConnect 会随之变化，需要作者先确认预期语义（见 questions）。

**P159　安装与 helper 注册：事故驱动的分支层层叠加**　〔accretion｜复核修正｜可删约 0 行〕

- 结论：事实描述基本准确：58 个 fix 提交，3 份相关事故，10-13 一天连发 v0.9.2–v0.9.6，prepare() 由 4 个布尔标志驱动。但 1d12b0a 是构建与部署目标脚本的修复，不属于安装逻辑。“可删 60 行”与 P085 重复计算；状态枚举改写是重构，不是删除。
- 位置：macos/Shared/HelperRegistrationCoordinator.swift:113-225；macos/Shared/HelperRegistrationCoordinator.swift:227-300；macos/Shared/HelperRegistrationCoordinator.swift:320-347；macos/Sources/XDial/ApplicationRelocator.swift:246-404；macos/Shared/XDialBuildIdentity.swift:31-40,144-146
- 建议：把 prepare() 改写成显式的状态枚举（observe → repair-once → verify），把规则写进类型，取代 4 个布尔标志；给旧 helper（<v0.8.0）交接分支设定 sunset 版本，到期删除；评估登记重试预算与“重建一次”能否合并为同一条修复路径。
- 注意：可删部分（旧 helper 交接分支）已经计入 P085，这里不应重复计入。把 4 个布尔改成显式状态机，行数未必减少，而且真实 BTM 故障无法复现，测试只能依赖模拟 IO，风险高。建议放在删除旧版分支之后、单独发版。

**P160　自动恢复/重连逻辑分散在 AppState、GoEngine、TransparentProxyManager 三层，是 fix 最密集的区域**　〔mixed-responsibility｜未复核｜可删约 100 行〕

- 结论：13 个 fix 提交（abc827c、ea8d673、fe46273、30e6492、a99bb2a、d56a6f2、b6a91bb、7eb9a4f、05af780、6b21331、ab650e4、c90ceac、dc364c3）反复同时改动 AppState、GoEngine、TransparentProxyManager、Provider、EmbeddedSingBoxRuntime 这 5 个文件，每次修复往往还会新增一个 Shared 策略文件：AutomaticConnectionPolicy、AutomaticReconnectRetryPolicy、AutomaticReconnectPreparation、AutomaticLineReadinessFailurePolicy、AutomaticScenarioSwitchRetryPolicy、NetworkEpochSwitchCoordinator、ReconnectIncidentHistory，合计约 1,400 行。两套重试机分属不同对象：完整恢复的 5 次预算在 TransparentProxyManager.scheduleAutomaticReconnectRetry，自动切换的 2/5/10 秒重试在 AppState.scheduleAutomaticScenarioSwitchRetry；两者各有一套失败码命名空间，唤醒/休眠门也分别写在两处（AppState 的 suspend/resumeAutomaticScenarioSwitch 与 TPM 的 resumeAutomaticReconnectRetryAfterWake）。GoEngine 只负责转发两个闭包（automaticReconnectPreparationHandler、underlayChangeHandler）。ARCHITECTURE §5.4 定义了两种预算，属于必要功能；问题在于没有一个单一的意图协调者。
- 位置：macos/Sources/XDial/AppState.swift:1500-1930；macos/Sources/XDial/AppState.swift:2446-2560；macos/Sources/XDial/TransparentProxyManager.swift:2466-2560；macos/Sources/XDial/TransparentProxyManager.swift:2988-3410；macos/Sources/XDial/GoEngine.swift:41-47,112-140；macos/Shared/AutomaticConnectionPolicy.swift:34-176
- 建议：以 ConnectionDesiredState 为核心，收敛出一个 ConnectionIntentReconciler，同时拥有 epoch、自动切换重试、完整恢复预算与唤醒门；AppState 只提交意图，TPM 只执行事务并上报结果，GoEngine 不再转发闭包。两套预算保留为参数，失败分类统一用 retryClass（见重试分类问题）。
- 注意：高。这是事故最密集的区域，必须保留 NetworkEpochSwitchCoordinatorTests、AutomaticReconnectRetryPolicyTests 等全部行为测试，并分阶段迁移。

**P161　Makefile 中约 40 条源码 grep 门禁：事故化石，阻碍重构**　〔test-bloat｜复核修正｜可删约 10 行〕

- 结论：test-macos-transaction 中确实有 42 条门禁（Makefile:205-246，其中 41 条使用 rg），许多条绑定的是标识符文本或出现次数，逐条由 fix 提交追加，所引行号（212、216-219、233、245）都准确。但“216-219 在保护本应删除的 API 变体”不成立：GenerateTransparentProxySessionWithCapabilitiesAndCallback 和 …WithLineCapabilitiesAndCallback 是 EmbeddedSingBoxRuntime.swift:1195、1210 的两条活跃分支（先无能力生成，再按能力约束生成），probeOutboundTLSCapabilities 和 probePreparedSwitchOutboundTLSCapabilities 在 1626、1633 处被调用。另外有一批门禁表达的是安全或隐私不变量，不是事故化石：240-244（DebugServer 不读取安全文本框和多行文本的 AX 值）、236（NetworkInfo 不使用 URLSession 或 ip-api）、238（设置页出现时不发起网络探测）、205（不使用 Clash API）。
- 位置：Makefile:204-246
- 建议：逐条分类：能表达架构不变量的改写为单元测试或 core/config/invariants_test.go 风格的结构化检查；只用于钉住某次修复写法的（名字、出现次数、变体名）直接删除。
- 注意：可以直接删的主要是钉死名字或次数的条目：212、215-219、245，以及 0010 撤销后的 221。安全和隐私相关的条目只能改写成行为测试，不能删除。这些门禁在 CI 的 macOS job 中运行，删除前要确认已有对应的 XCTest 覆盖。

**P162　移动端从 macOS 拷来的配置迁移代码，在移动端从来没有数据来源**　〔legacy｜复核成立｜可删约 125 行〕

- 结论：移动端 loadStoredProfile 里的比喻 key 重写（hasLegacyMetaphorKeys、rewriteLegacyMetaphorKeys、rewriteLegacyScenario）和 v0.2 的 migrate(oldProfile:) 在移动端从来没有数据来源。移动端首个提交 a12b44e 写的就已经是 lines/rule_sets（场景键是 modes）。Lang.ipAPILang 没有调用方。macOS 的同名三个函数也没有调用方，那 77 行与移动端逐字相同。
- 位置：appletv/XDialTV/AppState.swift:1636-1652；appletv/XDialTV/AppState.swift:1993-2113；appletv/XDialTV/Localization.swift:14-20
- 建议：删除移动端的 hasLegacyMetaphorKeys、rewriteLegacyMetaphorKeys、rewriteLegacyScenario、migrate(oldProfile:) 与 ipAPILang；loadStoredProfile 对不符合当前形状的数据直接返回 .corrupt（现有逻辑已经会阻止覆盖）。
- 注意：小更正：iOS 的 Profile 存在 App 自己的 UserDefaults.standard 里，不在 App Group；结论不变，因为不可能读到 macOS 的数据。重复块是 77 行，不是 38 行。删除这些函数本身不改变行为，因为它们走不到。但要和 P138 一起处理：真正缺的是 modes→scenarios 迁移，删除时不要让人以为旧数据已经有兜底。macOS 那 77 行死代码在 macOS 死代码问题里另算，不要重复计数。

**P163　未接线的 1029 行 e2e 测试，驱动 App 已不使用的 daemon 旧数据面**　〔test-bloat｜复核修正｜可删约 0 行〕

- 结论：结论与 P040 相同，是重复条目：e2e_test.py 没有接入任何入口，驱动的是 App 自 a5f761f 起已不再使用的 daemon 旧数据面。但其中两处事实有误：一是正式通道的 socket 至今仍是 /tmp/xdial.sock，与脚本默认值一致，只有 Debug 和 Next 不同，而且脚本支持 --socket；二是旧比喻命名用例在当前 daemon 上并非「偶然通过」，而是必然失败（返回 invalid profile，触发 e2e_test.py:286 的 Failure；即使走到异步路径，错误信息里也不会出现 ghost）。
- 位置：test/e2e_test.py:1-1029；macos/Sources/XDial/GoEngine.swift:860-872；cmd/xdial/daemon.go:281-330
- 建议：与旧原生 TUN 的去留一起决定（见 questions）：若 CLI 的 start 仍要支持，就把 e2e 接入一个显式的 make 目标并修正 socket 路径与失效用例；若不支持，就删除 e2e_test.py，并评估删除 daemon 的 start/stop/kill-session/runtime-lines 与 status 事件广播。
- 注意：它与 P040 是同一个 1029 行文件。为避免重复计算，这里记 0，删除量统一记在 P040。风险中提到的「dns_takeover 残留清理不依赖 engine.Start」成立：RestoreLeftoverDNS（engine.go:115）只依赖 e.dns 和 e.status。

**P164　移动端进程内 Tailscale setup 生命周期与 Go 的 tailscalesetup 管理器重复**　〔duplication｜未复核｜可删约 300 行〕

- 结论：iOS 的 LocalTailscaleSetupRuntime（595 行 Swift）实现了 setup 会话的 start/status/beginLogin/logout/stop、接口可用等待、操作看门狗与停止排队；macOS 经 daemon 使用 Go 的 core/tailscalesetup/manager_gvisor.go，其中 Prepare/Status/BeginLogin/Logout/Stop/StopLine 与 idle touch 承担同样的职责。tvOS AppState 中的 TailscaleSetupRuntime 协议（AppState.swift:48-69）的方法集合也与 Go Manager 一一对应。该 Go 包的 build tag 是 darwin && with_gvisor，在 GOOS=ios 下同样满足 darwin 约束。
- 位置：ios/XDialIOS/LocalTailscaleSetupRuntime.swift:1-595；core/tailscalesetup/manager_gvisor.go:47-262；appletv/XDialTV/AppState.swift:48-69
- 建议：评估把 tailscalesetup.Manager 通过 Libbox 导出给 iOS（会话管理留在 Go），Swift 只保留与 NWPathMonitor 相关的接口事实注入。
- 注意：中。iOS 的 setup 运行在 App 进程内，需要满足后台与内存限制；Go 侧的 idle 超时语义要与移动端 UI 预期对齐。

需要作者回答的问题：

- iOS/tvOS 的产品定位是什么？tvOS 目前只有无签名的模拟器构建、CI 不编译、没有发布路径，是否冻结或移除？iOS 是否计划迁到与 macOS 相同的 Go ConnectionPlan/ConnectionReport 路径？这决定移动端约 14k 行 Swift 是迁移、冻结还是删减。
- 移动端的连接验收（强制注入 1.0.0.1/1.1.1.1 两条 RuleSet，探测 cdn-cgi/trace 与 apple.com，失败即自动断开）与 ARCHITECTURE §4.3 冲突。这是有意保留的移动端例外（若是，应写进 ARCHITECTURE），还是等待迁移到 Go 就绪证明？
- ARCHITECTURE §3.2 把 Home DERP 重选称为“显式维护能力”，但 Libbox.ReselectTailscaleHomeDERP 在 Swift、cmd、DebugServer 中都没有调用入口，Swift 判定函数从引入起就只被测试调用。是否计划接入？若不接入，能否剥离 patch 0005 中约 1200 行 reselection 代码？
- 旧原生 TUN 数据面（daemon 的 start/stop/kill-session/runtime-lines、core/engine.Start、test/e2e_test.py）除 CLI 外还有使用者吗？ARCHITECTURE §9 说的“恢复路径”只指 dns_takeover 残留清理，还是也需要 engine.Start？
- Go 中 Profile.ActiveVPNLine() 不过滤停用的 RuleSet，而 effectiveActiveTargetIDs 会过滤；configgen 选择会话 AnyConnect 用前者，生成 route 用后者。哪一个是预期语义？（macOS Swift 的 ConnectionConfigurationBlocker 跟前者，移动端 Swift 跟后者。）
- 旧 helper（handoffProtocolVersion < 1，即 v0.8.0 之前）的交接兼容分支，最低需要支持从哪个版本升级上来？能否设定 sunset 版本？
- macOS 用户中还存在 v0.3–v0.4 比喻命名（ports/cargoes/cruises）的旧配置吗？ExistingXDialProfileReader 目前只转换 v0.2 的 exits 格式，AppState 里比喻命名的迁移函数已经没有调用方：是删除这些函数，还是把它们接回首次迁移流程？

### 复核中新发现的问题

- **DNS 软失败的启动时上报在任何版本里都不可能送达用户**（legacy-tun，可删约 0 行）：daemon 在 net.Listen 之前就调用了 RestoreLeftoverDNS。其中 reportDNSPending 先把软失败服务标记为已上报（pendingReported），再把 error 事件广播给一个空的 ClientSet。之后每次周期 tick 时，notePendingSoftLocked 会保留这些已上报的条目，所以不会再报。结果是，启动时就存在的被禁用服务残留永远不会通知用户，连 v0.6.0（当时宿主还会显示 error）也一样。只有在 daemon 运行期间才新出现的软失败，才有机会被一个已经连上的客户端收到。这进一步说明 P035 的上报链路形同虚设。
- **当前版本 daemon 仍会真实接管系统 DNS，残留并非只来自 v0.6.0**（legacy-tun，可删约 0 行）：v0.7.0 到 v0.9.6 的 daemon 都仍然执行 AllowSystemDNSTakeover(true)，并且接受 socket 上的 start。只要有人发送 start（e2e 的 Tier B、手工 nc、任何同用户进程），就会接管到 198.18.0.2 并写入 dns-takeover.json。因此 P036「确定最低升级起点后整体删除自愈」必须排在删除 daemon start 之后，否则会出现能接管却无法自愈的窗口。P040 说 e2e 脚本风险低，但对当前 daemon 跑它的 Tier B 会真实改动整机 DNS。
- **随 App 分发的 xdial-daemon 就是完整 CLI，start、stop、status 都可直接执行**（legacy-tun，可删约 0 行）：发布包里的 Contents/MacOS/xdial-daemon 就是 cmd/xdial 的产物。main.go 不区分 argv[0]，所以 `sudo /Applications/XDial.app/Contents/MacOS/xdial-daemon start -f x.json` 能在 root 下跑起整套旧数据面（不接管 DNS，但会 exec sing-box）；不带 sudo 执行 stop 或 status，也能经 socket 控制 root daemon。审计员把这条入口描述成「xdial start」，没有指出它其实随产品分发。
- **Debug 和 Next 的引擎目录固定在 /tmp**（legacy-tun）：与 P034 同一攻击面，已由 #34 修复。
- **macOS 宿主的订阅编辑和状态残留自 v0.9.0 起不可达**（go-config-dead，可删约 70 行）：editingProfile 和 profile 都来自 snapshot()，subscriptions 恒为空；applyDraft 也不回写 subscriptions。因此以下代码要么没有调用方，要么只在空数组上运行：AppState.addSubscription、updateSubscription、deleteSubscription（AppState.swift:2792-2828）；activeSubscriptions（:518-527，无调用方）；SettingsView.moveSubscription（:564-577，private，调用点在 ec2f29d 被删除）；LineTargetPicker 的 'sub:' 分支（:14-16、:45-47）；MainPopover.policyTargetName 的订阅分支（:1580-1583）。
- **AppState 的旧命名（比喻命名）key 迁移是没有调用方的 private 死代码**（go-config-dead，可删约 75 行）：hasLegacyMetaphorKeys、rewriteLegacyMetaphorKeys、rewriteLegacyScenario（AppState.swift:2702-2776，约 75 行）都是 private static，全仓库没有调用方。最后的调用点 'Self.hasLegacyMetaphorKeys(raw)' 在 ec2f29d（v0.9.0）被删除。旧配置现在统一由 ExistingXDialProfileReader 转换。
- **TP 的 Swift 侧订阅任务管道比 P001 列出的多，应随 P001 一起删除**（go-config-dead，可删约 60 行）：除了 EmbeddedSingBoxRuntime 的 subscription_outbounds 解码和校验之外，还有：ProxyLineReadiness.swift 中的 'subscription' 任务分支和 subscriptionFailureCode，以及 targets(subscriptionOutbounds:)；ConnectionTransaction.swift:943、:1011 的 'subscription' 会话任务种类和 :149-178 的 subscriptionID；EmbeddedSingBoxRuntime 的 verifySubscriptionReadiness（:1706 起）和 reporter.setTasks(kind:"subscription")（:426、:730）；ProviderDiagnosticsIPC.matchedSubscriptionIDCounts，以及 TransparentProxyProvider:23/69-70 和 DebugServer:604 的对应透传。Go 侧既然不会再产出 ConnectionTaskSubscription，这些都执行不到。
- **root daemon 的 start、stop 和 Desktop TUN 引擎自 v0.7.0 起没有 App 调用方，test/e2e_test.py 只驱动这条路径**（go-config-dead，可删约 1060 行）：macOS App 只给 daemon 发 tailscale-*、resolver-refresh、parse-sub、status、connection-report、respawn，不发 start、stop、kill-session、runtime-lines。daemon 的 start 会走 engine.Start → GenerateSingBoxDesktop（PlatformMacOS），现在只有 CLI `xdial start` 能触达。test/e2e_test.py（1029 行）读的是已废弃的存储（defaults com.kafeifei.xdial/xdial.profile 和 ~/.xdial/vault.json），通过 /tmp/xdial.sock 驱动 daemon 的 TUN 模式，Makefile、CI、docs 都没有引用它。另外，architecture invariants_test 中的订阅和资源不变量用的也是 GenerateSingBoxDesktop，测的不是 App 实际运行的 TP 平台。
- **删除 TailscaleDNSCaptureDomains 后，sing-box 补丁 0002 的 DNSCaptureDomains 访问器会跟着变成死代码**（libbox-dead，可删约 15 行）：在 0004 之后，sing-box 的 Endpoint.DNSCaptureDomains() 和 dnsCaptureDomains TypedValue 字段唯一的消费者是 libbox 的 TailscaleDNSCaptureDomains，PrepareTailscaleDNS 改用 DNSMemorySnapshot().CaptureDomains。tailscaleDNSCaptureDomains(dnsCfg) 在 0004 后也只剩 0002 的测试在调用。按 P018 删除 libbox 导出后，应同步精简补丁 0002/0004 中的访问器、字段和对应的 Store，并删掉 prepare-patched-go-mod.sh:214 的 grep。
- **补丁 0005 和文件 xdial_derp_reselection.go 名不副实，里面藏着与重选无关、影响生产的修复**（libbox-dead，可删约 0 行）：0005 的 local.go hunk 除了重选，还加入了 SetControlClientStatus 在 TKA 同步后忽略旧 client 的修复，以及 xdialNetInfoSendMu。0009（拒绝过期 NetInfo 回调、把 PreferredDERP 规范化为 myDerp）的实现位于 magicsock/xdial_derp_reselection.go 中的 XDialNormalizeNetInfoForControl。这些修复直接决定生产就绪事实 SetForCurrentClient / preferredDERPRelation，也就决定了 Swift 会不会报 homeDERPReportMismatch。按 P154“从 0005 剥离 reselection 文件”的字面做法，会把它们一起删掉。剥离时应把这些修复迁到独立补丁或独立文件，例如 xdial_netinfo_boundary.go。
- **controlclient 的 XDial receipt 测试从未执行**（libbox-dead，可删约 0 行）：补丁 0005 新增的 control/controlclient/xdial_update_test.go（88 行，TestXDialNetInfoReceipt* 系列）只被 prepare-patched-go-mod.sh 用 grep 校验函数名是否存在。make test-patched-tailscale 只跑 derphttp、magicsock、ipnlocal 三个包，CI 从来没有执行过这些测试。如果按 P154 删除重选，它们会一起删掉；如果保留，应把 controlclient 加入 test-patched-tailscale。
- **文档仍把死导出列为证据来源和能力**（libbox-dead，可删约 3 行）：docs/verification/tailscale.md:15 把 ProbeTailscalePeer / ProbePreparedSwitchTailscalePeer 列为“结构化来源”，读者会以为可以用它们取证，实际上没有任何入口能调用。ARCHITECTURE.md:133 把 Home DERP 重选写成现有的“显式维护能力”。docs/agent/profile-next.md:154 用名字提到不带 URL 的 ProbeStandaloneLineLatency。删除对应导出时要同步修改，否则文档描述的能力与代码不一致。
- **完成 P021 后，syncLineRuntimeUnderlayFrom 的 force 参数恒为 true**（libbox-dead，可删约 8 行）：删掉 prepareSwitch 的旧分支（force=false）和 RefreshPreparedSwitchLineRuntimes（force=true）后，生产中唯一的调用者是 observeLineNetwork（force=true）。force 参数和“未变化就跳过”的分支会变成只服务于 platform_test.go:249 的 force=false 用例，可以收敛。
- **installRoutingProbe 自 0abde98 起无调用方**（mobile，可删约 8 行）：a5f761f 引入 Libbox.installRoutingProbe(instance)，作为门控后的 tracker 安装入口。0abde98 重写 Start/PrepareSwitch 时把这段逻辑内联成 `if debugRoutingProbeEnabled { ... }`，旧方法留了下来，全仓库（含测试）没有任何调用。
- **移动端验收里的旧版计数接口在生产路径上是死代码，Go 的 6 个标量计数器只供它使用**（mobile，可删约 75 行）：DataPathProbe.Result 的 directLineEgressIP/anyConnectLineEgressIP 在生产调用中恒传 nil（TunnelManager.swift:1725-1729）。它的 linesReachable、splitRoutingOK、isUsable、diagnosticSummary、failureMessage、withRoutingEvidence（TunnelManager.swift:321-378）在生产代码里都没有被读取，生产路径只读 routed*EgressIP 和 hostnameOK。RoutingProbeSnapshot.provesConfiguredRouting(after:) 这个按标量计数的“兼容旧”方法（635-653）只有 DataPathProbeTests:339-341 在用。生产路径只用按 tag 的 provesConfiguredRouting(after:directTag:currentRouteTag:) 和 provesConfiguredDirectRouting。因此 Go 端 routing_probe.go 里 direct_target_direct/vpn/other 和 anyconnect_target_direct/vpn/other 这 6 个标量计数器没有生产消费者。注意 Swift 解码器要求这 6 个 key 必填，删除要两端同步。
- **0abde98 之后，移动端 loadSaved 的整个 .legacy 分支对真实数据不可达**（mobile，可删约 250 行）：移动端 raw（非 envelope）格式只在 2026-07-01 至 07-23 写过，键是 modes/active_mode_id。0abde98 把 raw 形状检查改成必须有 scenarios/active_scenario_id，没有为 modes 留回退。比喻 key 和 v0.2 格式在移动端又从未写过。因此 .legacy profile 分支永远不会命中：raw modes 数据变成 .corrupt，persistence 被阻断。与之配套的 restoreLegacyValues（扁平 vault key）、loadLegacyPerItemValues、legacyOwnerCounts、LegacyMigrationResult 也就没有可达的调用路径。是删除，还是补一条 raw modes→scenarios 迁移后复用这条链路，需要作者决定（与 P138 一并处理）。
- **macos/Package.swift 是不可能编译的陈旧 SPM 清单**（mac-dead，可删约 16 行）：Package.swift 把 Sources/XDial 声明成 SPM executableTarget，但现在的 Sources/XDial 依赖 Shared/（如 XDialBuildIdentity）和 Libbox.xcframework，而 SPM target 两者都没有声明，所以不可能编译。Makefile、scripts 和 .github/workflows 都不引用它，构建完全走 xcodegen 加 xcodebuild。这个文件最后一次修改在 v0.4.1，属于构建配置层面的死文件。
- **MainPopover.currentRuntimeScenarioID 的 profile 守卫恒为真（P061 漏项）**（mac-dead，可删约 1 行）：MainPopover.swift:1256 的 guard state.browsingRecord.id == state.profileLibrary.activeProfileID：browsingRecord 就是 runtimeRecord，其 id 为 configurationID；activeProfileID 经 validated() 后也恒为 configurationID。这个 else 分支不可达，是多 Profile 时代的残留。
- **删除 parse-sub 后 daemon 协议字段和注释成为孤儿**（mac-dead，可删约 12 行）：P152 建议删除 daemon 的 parse-sub 处理。删除后 cmd/xdial/protocol.go 的 SubURL、SubContent、SubFormat 三个请求字段不再有读取方。另外，GoEngine.swift:4 和 :875 的注释仍以 parse-sub 为例，解释 socket 权限和日志脱敏，需要同步改写，否则会误导。这个分支已由 #34 删除。
- **Home DERP 重选能力整条链没有生产调用方（Swift 判定、Go 导出入口、Tailscale 补丁）**（provider-boundary，可删约 130 行）：a5f761f 版 ARCHITECTURE 已把 Home DERP 重选移出连接事务，现行 §3.2 也说它是“显式维护能力，不是连接准备条件”。但仓库里没有任何 UI、DebugServer 路由或宿主命令去触发它。Swift 侧的 shouldReselectTailscaleHomeDERP、TailscalePeerRecoveryFacts、isTailscalePeerRecoveryCandidate 只被测试调用。Go 侧导出的 Libbox.ReselectTailscaleHomeDERP（gomobile 下在 Swift 中应名为 reselectTailscaleHomeDERP）在 macos、appletv、ios 中都没有调用者。patches/tailscale/0005-add-bounded-homederp-reselection.patch 加上 scripts/prepare-patched-go-mod.sh:311 的存在性检查，只为这条链服务的部分需要人工拆分确认。
- **63299e8 文档重写删掉了仍在生效的代码契约，导致代码看起来“违反架构”**（provider-boundary，可删约 0 行）：2026-09-12 的纯文档提交 63299e8 删除了三处与现存代码直接对应的内容，代码没有跟着改：(a) 2026-08-21 的 IPv6 TLS 黑洞事故，以及 Direct 的 IPv6 TCP+TLS 冗余探测契约；(b) 逐 Line 地址族能力“由 Provider 以 Line ID 为键重生成完整候选”；(c) “仅在结构化原因为 underlay-egress-unavailable … 才允许有界重试”。事故证据也没有迁进 docs/incidents/d35-transparent-proxy-evidence.md，那份文档只保留了同日的 link-local 和 bound-flow 两段。结果是现行 §4.3 的绝对措辞与 UnderlayIPv6TLSProbe 直接冲突，自动审计因此把事故驱动的代码判成了越界（P120）。
- **underlay-egress-unavailable 只由 Tailscale 预检产生，Underlay 变化后的自动重试只对 Tailscale 场景有效**（provider-boundary，可删约 0 行）：AutomaticReconnectRetryPolicy 对 .underlayChange 触发的失败，只在错误码为 underlay-egress-unavailable 时安排重试，而全仓唯一的生产者是 waitForTailscale 开头的 Direct 出口预检。所以对没有 Tailscale 的场景，网络变化导致的连接失败永远不会自动重试；对 Tailscale 场景，是否重试取决于一个出口展示服务的探测结果。无论 P121 最终删不删预检，这种不对称都需要作者确认是否有意为之。
- **Swift 的 LineAddressFamilyCapabilityCodec 复制了 Go TLS 探测的失败码表和计数不变量**（provider-boundary，可删约 25 行）：decodeProbe 硬编码了 Go outbound_tls_probe.go 中 6 个失败码（timeout、cancelled、tcp-connect-failed、tls-peer-closed、tls-authentication-failed、tls-handshake-failed），并校验 attempts、tcpConnected、tlsAuthenticated 之间的关系以及失败码计数之和。Go 将来只要新增一个失败类，Swift 就会把整个探测结果判为 invalidProbe，从而让 Line 失败；这属于 §1 禁止的“复制 Go schema”，与 P125 同类。Swift 的 capability(from:) 还没有跟进 Go 对 VPN Line 清空 IPv6 的规则（line_network_readiness.go:428-437），两套能力计算已经出现语义差异。
- **发布时间线与“最低升级起点”对照表**（install-migration，可删约 0 行）：Tag（以 commit 日期为准）：v0.1.0 05-01，v0.2.0 05-01，v0.3.0 05-04，v0.4.0 05-06，v0.4.1 05-08，v0.5.0 07-01，v0.6.0 07-27，v0.7.0 08-22，v0.7.1 08-28，v0.7.2 09-04，v0.7.3 09-07（事故记录称当时没有发布 GitHub Release），v0.8.0 09-11，v0.8.1 09-11，v0.8.2 09-12，v0.8.3 09-12，v0.9.0 09-26，v0.9.1 09-26，v0.9.2–v0.9.6 均为 10-13。没有 next-v* 或 xd tag。  各版本的升级通道： - ≤v0.6.0 没有更新器，只能手动安装。 - v0.7.0 的更新器拒绝跨身份更新，也只能手动；而手动路径因 P084 必然失败。 - v0.7.1–v0.8.1 通过 GitHub API releases/latest 更新，由暂存的新包执行安装，安装时会用新二进制拆掉旧 helper。 - v0.8.2 起使用 Pages 清单（95a36bc）。  按最低升级起点可删的内容： - ≥v0.6.0：可删 /Library helper 清理，包括 cleanupLegacy、legacyInstalled、allowsLegacyCleanup、checkHelper 短路、DebugServer 两个字段、Occupancy 的 legacyHelperIdentifier、PrivilegeManager.legacyLabel，约 50 行。 - ≥v0.7.0：再删 Tailscale 状态迁移（state.go 加 daemon 调用约 130 行，外加 114 行测试）和 v0.6.0 DNS 残留自愈（是否连同整个 DNS 接管一起删见下一条）。 - ≥v0.7.1：再删旧身份迁移（P084，约 170 行源码加测试）和 Occupancy 的 legacyTransparentProxyIdentifier；KeychainStore 与 ConfigurationStorage 中的旧 id 必须保留。 - ≥v0.8.0：再删 legacy handoff 空闲窗口（P085，约 130 行）和 daemon 的 respawn 处理（约 19 行 Go）。 - ≥v0.9.0：理论上可删首启旧单 Profile 转换，但违反 CLAUDE.md 的“首次只读转换旧配置”，卸载清理也还需要旧位置列表，不建议。  与最低版本无关、现在就能删的：孤儿 helper plist、requestRespawn、legacyMigrationFailed、sudoers 的 rm、P089 两个参数、P087 写入分支、P088 的 pre-shared 库与 schema<3（只存在于开发机）、XDail Debug 改名迁移（只存在于开发机）。  推荐的候选起点是 v0.7.1 或 v0.8.0。v0.7.0 及更早的用户现在本来就无法成功升级，定在 v0.7.1 不会造成真实倒退，只需把失败改成明确的“请先卸载旧版”。v0.7.1–v0.7.3 经安装器升级时不依赖 handoff 窗口，所以定在 v0.8.0 的额外代价只落在 Finder 覆盖安装的用户身上。需要作者回答两个问题：v0.7.0 及更早的版本是否发布过公开 Release、有没有外部用户下载；v0.7.x 的 GitHub Release 是否公开。
- **孤儿文件 macos/com.kafeifei.xdial.helper.plist**（install-migration，可删约 33 行）：这是旧 label com.kafeifei.xdial.helper 的 SMAppService plist（33 行）。自 bb53e99（v0.7.1）起 project.yml 改为拷贝 XDIAL_DAEMON_PLIST（app/debug/next 三个 daemon.plist），Makefile:127 也只拷 com.kafeifei.xdial.app.daemon.plist。这个文件不会进入任何产物，可以直接删除。
- **PrivilegeManager.requestRespawn() 自 v0.8.0 起无调用者**（install-migration，可删约 6 行）：Swift 侧发送 respawn 的函数只剩定义，没有调用者；bundledDaemonSHA256 上方的注释“不一致说明重编过 → 发 respawn 让它原地换成新二进制”也已失效。daemon 侧的 respawn 处理现在只为 ≤v0.7.x 的旧 App 存在（见 P049）。
- **HelperRegistrationCoordinator.Failure.legacyMigrationFailed 从未被抛出**（install-migration，可删约 2 行）：这个枚举 case 及其中文描述在全仓没有 throw 点，是死代码，可以随时删除，不依赖最低升级起点。
- **/etc/sudoers.d/xdial 清理的对象从未存在过**（install-migration，可删约 1 行）：cleanupLegacy 中的 rm -f '/etc/sudoers.d/xdial' 来自 v0.3.0 的卸载脚本，但历史上没有任何提交写过这个文件。可能是仓库建立之前的原型遗留，可以无条件删除（P049 和 P086 把它算作 ≤v0.5.0 的行为，这是错的）。
- **daemon 的 start/kill-session/runtime-lines 命令和整个系统 DNS 接管子系统自 v0.7.0 起在仓库内没有客户端（可能与其他条目重叠）**（install-migration，可删约 1180 行）：从 a5f761f（v0.7.0）起，macOS App 只给 daemon 发 tailscale-*、resolver-refresh、parse-sub、connection-report、daemon-info、registration-*、status（legacy 探针）这些命令，不再发 start/stop。CLI 的 xdial start 在进程内运行，并调用 AllowSystemDNSTakeover(false)；xdial stop 仍会向 daemon 发 stop。DNS 接管只能经由 daemon 的 start→Engine.Start→takeoverDNSLocked 触发，所以 RestoreLeftoverDNS/StartDNSSelfHeal 只能清理 v0.6.0 daemon 的残留。dns_takeover.go 有 1180 行，测试 2296 行。kill-session 和 runtime-lines 在仓库内也没有发送方。这一条在 P049 中被一笔带过，可能已由其他审计范围覆盖。
- **Debug 误拼包名 “XDail Debug.app” 的迁移代码只服务开发机**（install-migration，可删约 40 行）：相关代码包括 XDialBuildIdentity.previousApplicationBundleNames、installedChannels 中的 XDail 条目、ApplicationRelocator.previousInstallation/retire 与 handsOverPreviousInstallation 分支，以及 XDialBuildIdentityTests 和 LocalProcessInventoryTests 中的断言。它们由 2bbad06（10-13）引入，只作用于 Debug 身份。作者本机完成迁移后就可以删除，属于同类的升级迁移残留。
- **macos/Package.swift 是无法构建的遗留 SwiftPM 清单**（structure-tests，可删约 16 行）：Package.swift 声明了一个 executableTarget，路径是 Sources/XDial，平台为 .macOS(.v14)，但没有包含 Shared，也没有链接 Libbox。Sources/XDial 有 5 个文件 import Libbox，并大量使用 Shared 中的类型（如 ConnectionReportJournal），因此这个清单不可能构建成功。仓库里没有任何 Makefile、脚本、CI 或文档引用它，它最后一次修改是 2026-05-08（v0.4.1），之后工程已改用 xcodegen 的 project.yml（部署目标 15.0）。
- **测试缺口不止 TPM、AppState、GoEngine：扩展侧约 7.2k 行同样没有测试**（structure-tests，可删约 0 行）：XDialTests 只纳入了 4 个扩展文件。TransparentProxyProvider（3096）、EmbeddedSingBoxRuntime（3175）、UDPFlowSOCKSRelay（978）都不在测试 target 中，宿主侧的 PrivilegeManager（845）、DebugServer（1054）、InstallationCoordinator（415）也不在。未纳入测试的 Swift 共 38 个文件、27,742 行。Provider 侧的连接、Switch 和回滚逻辑同样只能靠 Shared 中的策略类型间接测试。
- **针对已撤销 sing-box 0010 选项的反向门禁有三层，比审计员列出的多**（structure-tests，可删约 12 行）：除了 Makefile:221 和 prepare 脚本第 242-243 行，core/config 的 Go 测试中还有 4 处断言生成的 inbound 不含 xdial_reresolve_ipv4/6_flow_domains。该选项从未进入现行补丁的终态。sing-box 的选项解码使用 DisallowUnknownFields（推断：我在 module cache 中 sing-box v1.14.0-beta.2 的 option/*.go 看到多处使用），生成器误发该键会在启动或 validator 阶段报错。所以这几层门禁都在防同一个已被撤销的补丁复活。
- **libbox 导出的 GenerateTransparentProxySessionWithCallback 没有任何调用方**（structure-tests，可删约 26 行）：core/libbox/configgen.go 中，GenerateTransparentProxySessionWithCallback（约 26 行）在 Swift 和 Go（包括测试）中都没有调用。GenerateTransparentProxySession（约 23 行，包装 legacyDirectIPv6Available:true）只被 Go 测试调用。Swift 端只使用 WithCapabilitiesAndCallback 和 WithLineCapabilitiesAndCallback。前者是死的 gomobile 导出，可以直接删除；后者删除前需要先把 8 处测试改成调用实际在用的入口。
- **推断：helper 不可达时，报告轮询 Timer 在整个连接期间都不会停止**（structure-tests，可删约 0 行）：beginReportPolling 的停止条件是本地 journal 进入终态，而宿主自己从不写 committed，只靠 publishLatestReport 镜像 Provider 报告。如果 helper socket 不可达，probe 每次都会失败，journal 一直停在非终态，Timer 就会在整个已连接期间以 5Hz 在主线程上尝试 connect 并读两次 journal 文件，直到 currentTransactionID 变化。这条需要实际运行验证：helper 未安装或已崩溃时，透明代理能否连上。

### 遗漏审查

**未被盘点覆盖的文件**

- `ARCHITECTURE.md`（362 行）：九个审计员都把它当作“违反依据”来引用，但没有人把它当作盘点对象。本身不藏代码，问题在于它是合同来源却已有多处失真：D 编号的定义已删除，§4.2 的入口链接指错了文件，多条“不变量”没有标注平台范围，在 iOS/tvOS 上不成立。详见 doc_drift 第 1–5 条。
- `core/libbox/line_network_readiness_test.go`（764 行）：测的是核心就绪证明，属于必要功能。例外是 TestNetworkReadinessAcceptsPureSubscriptionClosure（321-348）：它通过 GenerateTransparentProxySession 构造订阅闭包，而 macOS schema 3 下嵌套订阅不可达。对应源码 line_network_readiness.go:170-215（requirement kind "subscription"、subscriptionNetworkIdentity:207）也没有被 P001 列入，P001 的删除范围漏了这一块。
- `core/libbox/routing_probe_test.go`（701 行）：测的是 DEBUG 才开启的路由探针。122-200、459-633 的固定目标计数用例只服务 tvOS/iOS 数据面验收，而 P028 已证明发布构建里这些计数恒为 0。201-458 的 experiment 用例只服务 macOS #if DEBUG 的 route probe。如果按 P028/P149 删掉移动端验收，约一半可以随之删除；其余属于 Debug 诊断，应明确标注为 DEBUG-only 测试。
- `core/libbox/outbound_probe_test.go`（420 行）：134-328 约 190 行（5 个 ForFamily 用例）测的是 Libbox.ProbeOutboundIPForFamily（libbox.go:580）。P153 已认定这个导出在 Swift 里 0 调用方，但测试量没有计入。命名为 Legacy 的用例（239）反而测的是仍在使用的非 family 版本，名字和实际情况相反。
- `macos/Tests/ProxyLineReadinessTests.swift`（346 行）：121-150、196-219、296 起的用例测的是 "subscription" 任务的出口就绪。生产侧 macos/Shared/ProxyLineReadiness.swift:10-90 有 6 个 subscription 分支，MainPopover.swift:1202 还有 subscriptionFailureCode 的文案分支，这些都没有被任何问题列出，而它们在 macOS schema 3 下不可达。
- `core/config/runtime_fingerprint_test.go`（406 行）：27-61 的用例断言订阅改名、导入元数据、订阅顺序对指纹的影响。运行指纹只有 macOS 消费（TransparentProxyManager/AppState.runtimeConfigurationSignature），而 macOS 没有嵌套订阅；移动端完全不调用指纹（rg 'Fingerprint' appletv ios 为 0）。这些用例守护的是不可能出现的组合，应并入 P001 的删除范围。
- `macos/Tests/ConnectionTransactionTests.swift`（424 行）：大部分测的是存活的报告状态机。136-170 用 code "tailscale-homederp-reselection" 作夹具，但生产代码里没有任何地方发出这个 code（rg 'homederp-reselection' 非测试为 0），这是 HomeDERP 重选（P154）这个死概念留在测试里的化石。
- `core/libbox/session_monitor_test.go`（742 行）：测的是 AnyConnect 会话监控和 StartStandalone，属于必要功能。P019 已说明这些测试经 installMonitoredSession 进入，碰不到死掉的回退分支，所以文件本身不需要删除，只是夹具偏重。
- `core/libbox/dataplane_test.go`（570 行）：测 VPNBridge 的 TCP/UDP 数据面（AnyConnect 在用），必要。它和 session_monitor_test.go 是直接依赖 go.uber.org/atomic（go.mod:15）仅有的两个使用者，生产代码不用这个依赖。
- `core/libbox/mobile_dns_transport_test.go`（329 行）：测试质量本身没问题，但它把移动端 DNS 语义固化成了合同：TestMobileDNSUsesPublicFallbackBeforeTailscaleLogin（134）和 TestMobileDNSUsesEnterpriseFallbackWithoutPublicLeak（164）要求“非 Tailnet 名字一律走企业 DNS 或公共 1.1.1.1”，这与 ARCHITECTURE §4.1 冲突。见 cross_cutting 第 2 条。
- `go.mod / go.sum`（463 行）：没有审计员覆盖依赖面。【看到的】(1) gvisor.dev/gvisor v0.0.0-20230916（go.mod:19）在全仓只有 core/engine/bridge.go:14-16（存活的 AnyConnect VPNBridge）导入；sagernet/tailscale、sing-tun、sing-box 用的都是 github.com/sagernet/gvisor 2025-08 版。在模块缓存里 grep：tailscale 分叉导入 gvisor.dev 为 0 处、导入 sagernet/gvisor 为 11 处。(2) github.com/things-go/go-socks5（go.mod:14）只被已死的旧 TUN 引擎 core/engine/engine.go:14 使用。(3) go.uber.org/atomic 只在测试里用。【推论】Libbox 同时链接两套 gVisor 网络栈，其中 AnyConnect 走的是三年前的快照。
- `docs/agent/profile-next.md`（172 行）：标题和框架仍是“Next 测试通道 / 这一版可用”，内容实际上是已合入全部通道的配置库规格，并且有多处与代码矛盾，见 doc_drift 第 8 条。
- `docs/incidents/2026-09-08-download-install-translocation.md`（182 行）：更像现场工作日志，而不是事故结论：记录了构建号、PID、本地日志路径（如 build/installation-runtime-20260909-candidate-build.log，不在仓库里）。不藏代码，相关的兼容逻辑已由 P085/P159 覆盖。可以压缩成根因、改动和未验证项三段。
- `macos/Tests/（其余约 60 个未被引用的测试文件）`（11727 行）：macos/Tests 共 70 个文件、11.7k 行没有被任何问题或功能清单引用，比如 ProviderRelayRegistryTests 598 行、ProviderDiagnosticsIPCTests 494 行、AnyConnectFailureEvidenceTests 467 行、ScenarioSwitchIPCTests 420 行。抽查结果是绝大多数测的是存活代码。已知例外：ProviderDiagnosticsIPCTests 里的 attribution/route-probe 用例只服务 DEBUG（对应 P128）；ProxyLineReadinessTests 和 ConnectionTransactionTests 见上面单独条目。说明测试冗余的盘点并不完整。
- `core/{config,libbox,subscription}/**/_test.go（其余未被引用者）`（10200 行）：共 42 个 Go 测试文件约 10.2k 行没有被引用，其中 libbox 30 个、7.5k 行。抽查到的死代码测试已在上面单独列出（订阅闭包、ForFamily、routing probe、指纹订阅用例）。其余的 outbound_tls_probe、line_runtime_pool、tailscale_runtime、flow_ingress、application_rule、subscription_geoip 等测的是存活路径。line_runtime_pool_test 在测 exclusive 参数，按 P031 它在生产中恒为 true，可一并收窄。

**跨子系统问题**

- **嵌套订阅（Profile.Subscriptions）在 macOS 已不可达，残骸横跨 Go 配置、libbox、Shared、扩展、宿主、UI 和测试 7 层，每个审计员只看到其中一段**：P001（go-config）、P060/P076（mac-connection）、P107（mac-ui）、P128（mac-extension）各报了一段。以下位置没有被任何问题列出：libbox 就绪闭包 line_network_readiness.go:170-215（subscriptionNetworkIdentity:207）；Shared 的 ProxyLineReadiness.swift:10-90 中 6 个 subscription 分支，以及第 80-82 行把 ["direct","vpn","tailscale"] 写死在 Swift 里；ConnectionTransaction.swift:941-947、1009-1015 的任务 kind 字面量；MainPopover.swift:1202；EmbeddedSingBoxRuntime.swift:426、730、1291、1706-1760（verifySubscriptionReadiness）；三份测试（line_network_readiness_test:321-348、ProxyLineReadinessTests、runtime_fingerprint_test:27-61）。更麻烦的是“subscription”一词在 macOS 上还有第二个存活含义：从链接订阅生成 Profile（ProfileManagementView.swift:16、config.ImportSubscriptionProfile 在 subscription_profile.go:12）。移动端仍在使用嵌套订阅。所以按 grep 分头删除，很容易误删存活路径或漏删。【推论】需要一次跨层改动：先在 TP 入口对嵌套订阅 fail-closed，再按任务 kind "subscription" 统一删除 macOS 侧。
- **iOS/tvOS 的 DNS 不按 Scenario Line 解析：非 Tailnet 名字一律交给企业 DNS 或直连 1.1.1.1:53**：【看到的】NE 配置的 DNS 规则只包含 Tailnet 规则，其余查询全部交给 xdial-mobile 分发器。分发器的逻辑是：会话里只要存在 AnyConnect，所有非 Tailnet 名字都走企业 DNS；否则走 publicFallback，也就是不带 detour 的 udp 1.1.1.1:53。Scenario 把某个域名绑到代理 Line 或 Direct，对它的解析路径没有任何影响。【推论】移动端代理域名的 DNS 会经 Underlay 发到 Cloudflare；有 AnyConnect 时，公网域名的查询也会发到企业 DNS。这直接违反 ARCH §4.1 的“先定 Line 再经该 Line 解析”，而 ARCH §4.2 的入口链接恰好指向这个文件。Go 生成器（go-config）、libbox transport（go-libbox）、移动端 Swift（mobile）三个审计员各看一段：P023 只看了 enterprise exchanger 的重复，P151 只说移动端是上一代架构，没有人点出 DNS 语义。
- **默认测速 URL https://www.gstatic.com/generate_204 在 3 种代码里写了 10 次，“移动端只用固定探测地址”这条策略也在 Go 和 Swift 各写一遍**：P024 只数到了 libbox 里的 2 处。完整清单是：Go 有 generator.go:2424、2467，libbox.go:446，standalone_line_latency.go:18，engine/tailscale_readiness.go:132；macOS Swift 有 Models.swift:774、813，都在已死的嵌套 Subscription 模型上；tvOS/iOS Swift 有 appletv/XDialTV/Models.swift:246、285 和 ios/XDialIOS/MobileConfigurationSupport.swift:186。另外 generator.go:2463-2465 在 NE 平台忽略 sub.TestURL，MobileConfigurationSupport.swift:182-189 又在导入时把自定义 URL 改写成固定值，同一条策略在两种语言里各实现一次。
- **Surge/Clash 规则类型的支持矩阵有 7 份、至少 3 种不同集合，同一份订阅在不同平台被接受的范围不同**：P007 只统计了 Go 内部的 3 份，P136 只看到移动端 Swift。完整情况：core/subscription/ruleset.go:155（ruleSetLineToRule）额外接受 PROCESS-NAME、IP-ASN、USER-AGENT；core/config/subscription_profile.go:163-190（importSubscriptionRule，macOS 导入）支持 PROCESS-NAME、GEOIP、IP-ASN；core/libbox/subscription.go:58-67（validateSubscriptionRules，移动端解析）只有 7 种；appletv/XDialTV/AppState.swift:770-772 和 ios/XDialIOS/MobileConfigurationSupport.swift:264-266 是同样 7 种的 Swift 副本；core/config/generator.go:2711-2760（collectSubscriptionRules）和 core/libbox/configgen.go:1859-1940（convertTextRuleSet）各有一份 switch；docs/agent/profile-next.md:80 又列了一套。【推论】带 PROCESS-NAME 或 IP-ASN 的订阅能导入 macOS，在 iOS 上会被 Go 和 Swift 两层同时拒绝，用户看到的错误也不一致。
- **固定公网探针和解析端点没有单一来源，分散在 4 层，相关问题被拆成 7 条**：Go 侧有 libbox.go:533-562（checkip.amazonaws、1.1.1.1/1.0.0.1/2606:4700 trace、r.inews.qq.com）、outbound_tls_probe.go:53、60、routing_probe.go:33-34、generator.go:40-41、1223、1267（TP 代理线路 DoH 与 NE 公共 DNS 都是 1.1.1.1）；macOS Swift 有 UnderlayIPv6TLSProbe.swift:44、48；tvOS/iOS 有 TunnelManager.swift:312-318；iOS UI 测试有 HomeViewUITests.swift:25-28。对应问题分属 P027、P028、P030、P120、P121、P134、P149，没有一条从全局看。ARCHITECTURE §4.3 只说“不能作为门槛”，没有给出允许存在的固定端点清单及用途，例如“出口展示”“代理线路的 DoH”。所以每次修复只能逐个特判。
- **Tailscale BackendState 状态词表没有 Go 侧枚举，4 处消费方各自解释上游原始字符串**：Go 的 tailscalesetup/manager_gvisor.go:239 和 macOS Provider 的 EmbeddedSingBoxRuntime.swift:2416-2420 各写了一份相同的过渡态集合 {NoState, Starting, NeedsLogin}。macOS 设置页 SettingsView.swift:871、1011 用的是 NeedsMachineAuth 的精确比较。移动端 appletv/XDialTV/AppState.swift:2349-2357 先转小写，再额外接受 needs_login、needs_machine_auth 这类 snake 写法，TunnelManager 和 ConfigurationView 里还有 11 处类似判断。P141 只看到移动端的 5 份，P122/P156 只看到 macOS Provider。【推论】Go 应导出归一化后的状态（running / needs-login / needs-machine-auth / transitional）；只要上游改一次拼写，四处就需要分别修改。
- **发布构建里一直在写、只有 #if DEBUG 的 DebugServer 会读的诊断数据，至少有 4 份**：P066（helperInstalled/helperNeedsApproval）和 P069（reconnect-incidents.json）由 mac-connection 审计员报告，P128（应用归属账本）由 mac-extension 报告，P028（路由固定目标计数，tvOS 验收依赖它却恒为 0）由 go-libbox 报告。根因相同：消费方 DebugServer.swift 整个文件处于 #if DEBUG 内，而生产者没有编译条件门控；ProviderDiagnosticsIPC.swift:400-411 只把 route-probe 设为 debug-only。ARCHITECTURE 和 docs/agent/debug-server.md 都没有约定“诊断数据的生产者必须与消费者同条件编译”。
- **没有声明“最低可升级起点”，兼容代码分散在 4 个审计范围，各自没有退役条件**：P049 只在 macOS/Go 安装链里指出“没有统一退役点”。同类代码还有：P036（只服务 v0.6.0 的 DNS 自愈，每 5 分钟 tick）、P084/P085/P086（旧身份、旧 daemon、旧 /Library helper）、P087（--import-xdial-debug）、P083/P152（比喻命名改写）、P138/P162（移动端迁移了从未写过的格式）。另外还有没进入任何问题的：XDialBuildIdentity.swift:31-40 的 legacy/ne-probe 标识、:80 的 "XDail Debug.app" 迁移，以及 development-builds.md:53-56 描述的拼写错误路径迁移。ARCHITECTURE、DESIGN、updates.md 中 grep“最低”“升级起点”均为 0 命中。【推论】先写一句策略，例如“仅支持从 ≥v0.7.x 升级；移动端从当前格式开始”，就可以一次性退役上面全部条目。
- **FormalDevelopment 构建配置在 project.yml、身份门禁和 3 份文档里维护，却没有任何构建入口**：macos/project.yml:9、111、171、247 为它单独配置了签名和 entitlements；scripts/verify-macos-identity-contract.sh:85、135 校验它的身份；ARCHITECTURE.md:307、docs/agent/development-builds.md:4、docs/agent/debug-server.md:4 都说明它的用途是“正式身份专项验证”。但 Makefile 里没有任何目标用 -configuration FormalDevelopment 构建；CI 的 ci-macos-build（Makefile:304）只遍历 Debug、Next、Release、NextRelease，连编译都没覆盖到；build-update-acceptance.py 也走 make release。problems.json 中没有任何问题提到它。
- **AnyConnect 数据面单独使用一份 2023 年的 gVisor，与 sing-box/Tailscale 使用的 sagernet/gvisor 并存**：【看到的】core/engine/bridge.go:14-16 是 gvisor.dev/gvisor v0.0.0-20230916（go.mod:19）在全仓唯一的导入方。VPNBridge 被 libbox 在 macOS TP 和移动端共同使用（engine.NewVPNBridge 等 13 处引用）。sing-tun、sagernet/tailscale、sing-box 用的都是 github.com/sagernet/gvisor 2025-08 版：在模块缓存里 grep，tailscale 分叉导入 gvisor.dev 为 0、导入 sagernet/gvisor 为 11。go-legacy-infra 审计员（P037）只指出 bridge.go 放错了包，go-libbox 审计员看的是消费方，都没有看依赖面。【推论】Libbox 体积和攻击面里多了一套不再更新的用户态 TCP/IP 栈；把 bridge 迁到 sagernet/gvisor 或 sing-tun 的栈后，可以删掉这个直接依赖。顺带一提，go-socks5（go.mod:14）只服务已死的 core/engine/engine.go:14，可以随 P033 一起删除。

**文档漂移明细**

- `ARCHITECTURE.md:18,56,91,138,149,195,200,282,319,339,349`：章节标题里的 D28、D31–D35、D-UNDERLAY、D-INGRESS、D-DNS、D30、D33、D36–D40、D-FAKEIP、D-CRASH 等决策编号已经没有定义。代码注释也在引用这些失效标签。
- `ARCHITECTURE.md:161-175（§4.2 Direct 原生解析）`：本节的入口链接 [DNS transport](core/libbox/mobile_dns_transport.go) 指向的是 iOS/tvOS 的 DNS 分发器。这个分发器恰好实现了本节禁止的“回落公共 DNS”。macOS 的 Direct 原生解析实际在 sing-box 补丁里。
- `ARCHITECTURE.md:10、47、151、179、235`：§1 写“Swift 不复制 Go 的 tag/schema/闭包/指纹”，§2 写“route 只来自 Scenario 与显式系统规则”，§4.1 写“先定 Line 再经该 Line 解析”，§4.3 写“Direct 就绪不依赖固定外部探针”，§5.2 写“Swift 只比较指纹”。这些都没有标注平台范围。全文只有 :127（MagicDNS）和 :352（Packet Tunnel）两处提到 iOS/tvOS 例外，上述五条在移动端都不成立。
- `ARCHITECTURE.md:133、docs/verification/tailscale.md:15、22-23`：ARCH 把 Home DERP 重选写成“显式维护能力”，验证文档把 ProbeTailscalePeer/ProbePreparedSwitchTailscalePeer 列为结构化证据来源，同时又说明它们“不是 Debug Server HTTP 动作”。这两项能力在产品和调试面都没有调用入口。
- `ARCHITECTURE.md:345（§8 SSID）`：文档写“SSID 不进入 Provider、计划、日志、Debug……”，但 Debug 的 /state 直接输出当前 SSID。
- `docs/plans/global-configuration.md:3、7-8、72-95`：这份计划已完成，却仍留在 plans 目录。状态行写“尚未进行新版在线网络验收”，验证记录写“未合入 main 或推送”，并附有 PID 和构建号等现场流水。内容已被 ARCHITECTURE §2 与 profile-next.md 吸收。
- `docs/plans/profile-subscriptions.md:1-6、15-20、67、72、133、143`：v0.3 草案已被全局配置方案取代，但 profile-next.md:5 仍把它当作“产品设计依据”。具体冲突：(a) :15-20 写“线路组/场景属于 Profile、不跨 Profile 引用”，与 ARCH:26-27 的 schema 3 全局组和场景相反；(b) :67 写 SSID 匹配限定在激活的 Profile 内，现在场景已是全局对象；(c) :133 写 Popover 在 B 准备时点击 A 仍会断开，但代码已经改为取消候选；(d) :143 链接的“旧订阅更新”位于 AppState，而那段代码已死（P060）；(e) :72 写 iOS/tvOS 复用同一模型，至今没有落地（P151）。
- `docs/agent/profile-next.md:1、5、46、48-51、153-157`：(a) 标题“XDial Next 测试通道”和 :48“这一版可用”，与 :3 自己写的“已合入 main，各通道同源”矛盾。(b) :5 的设计依据已过期，见上一条。(c) :51 写“通用独立靠右”，实际是三块并列居中，与 global-configuration.md:43 也互相矛盾。(d) :46 只记录了只读的 --check-xdial-debug-import，会写库的 --import-xdial-debug 仍然存在却没有记录。(e) :153-155 写手动测速入口是 ProbeStandaloneLineLatency、固定 HTTPS HEAD；生产实际用的是 …AtURL，并且 urltest 组会传入组自己的 URL；无 URL 版本已死（P017）。
- `docs/plans/next-interface-redesign.md、docs/plans/settings-version-entry.md`：前者已被放弃（P112 已报）。后者是已完成的历史决策，正文自称“历史决策”，并保留了构建号 1788111026 等现场证据，不属于计划。两份都应移出 plans 目录或删除。
- `.github/workflows/claude-review.yml:3、41`：注释和 prompt 都写“Swift 侧无单测”，与现状不符。这个 workflow 用 actions/checkout@v4，其余两个 workflow 用的是 @v7。
- `.golangci.yml、.github/workflows/ci.yml:10`：.golangci.yml 是孤儿配置：Makefile、CI、脚本都不调用 golangci-lint；而 CI 的 job 名为“Go (lint + vet + test)”，实际只跑了 gofmt。这个配置还在用 v1 的 issues.exclude-dirs 写法。【推论】如果它真的在跑，其中的 unused linter 能发现部分零调用的未导出函数，比如 P020 的 installRoutingProbe。
- `Makefile:447-449`：注释让开发者执行 go install …gomobile@latest 和 gobind@latest，但 go.mod 和两个 workflow 都固定在 v0.1.13。照注释操作可能导致 gobind 与 bind 包版本不一致。
- `AGENTS.md:6、docs/agent/next-releases.md:3、NEXT_RELEASE_NOTES.md:1`：文档把 Next 定位为测试通道，但从本地引用看，它已经落后正式版：origin/xdial-next 停在 6678f90（2026-09-23），比 main 少 49 个提交，v0.9.2–v0.9.6 的修复都不在 Next 里；NEXT_RELEASE_NOTES 自 54585fe 起没有更新；本地没有任何 next-v* 标签。远程标签因为不联网没有核实。
