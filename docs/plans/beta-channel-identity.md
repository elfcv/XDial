# XDial 版本身份改造计划

> 历史记录：本计划已于 2026-10-19 实施（#34–#43、#45），行号与分支状态均为写作时的快照。
> 当前机制见 [更新与发布](../agent/updates.md) 与 [本地开发](../agent/development-builds.md)。

**目标：** beta 并入正式身份，只靠更新源区分。只保留 Debug 一个独立身份。扩展显示名跟着身份走。

状态：已实施。
依据：6 路只读调研，范围是构建身份、更新通道、Swift 中的 Next 路径、扩展显示名、Go/helper、分支与文档；之后由两路评审（用户影响、覆盖完整性）复核，本文已经吸收了它们的修正。行号以 origin/main 为准。标【推断】的结论没有实测过。

---

## 0. 现状要点（看到的）

| 事实 | 依据 |
|---|---|
| 现在有 5 个构建配置：Debug、Next、NextRelease、FormalDevelopment、Release；对应 3 个独立身份：正式、Next、Debug | macos/project.yml:5-10、24-65 |
| Next 从未发布：本地和远程都没有 `next-v*` 标签；origin/xdial-next 是 origin/main 的祖先，main 比它多 65 个提交 | git |
| 客户端只有一个更新通道：清单地址写死为 stable.json，只接受 `channel == "stable"` 和严格的 vX.Y.Z | AppUpdateReleaseLookup.swift:35-43、199-201；AppUpdateTransaction.swift:51-55 |
| 判断新旧只看短版本号，并且会去掉 `-` 之后的后缀，所以 `0.10.0-beta.1` 和 `0.10.0` 被当成相等；构建号不参与比较 | AppVersion.swift:40-49、61-67 |
| 扩展的两个 lproj 把显示名写死成 "XDial Network Extension" 和 "XDial 网络扩展"，覆盖了 project.yml:77 按身份生成的值。本机 Debug 扩展在 `systemextensionsctl list` 里也显示 "XDial Network Extension" | TransparentProxyExtension/{en,zh-Hans}.lproj/InfoPlist.strings:1 |
| CI 的构建号是 UTC 秒；系统扩展只会被构建号更高的版本替换 | release.yml:34-35；Makefile:31-35 注释 |
| 签名包里写死的更新源（XDialUpdateAcceptanceID）要求新旧包取值相等，相当于把用户锁在这个源上 | AppUpdateTransaction.swift:392-405 |
| CI 只编 Debug 配置的 XDialTests，所以 XDialBuildIdentityTests 的正式分支（`#else`）从来没执行过；`make test` 只跑 `./core/...`，不跑 cmd/xdial 的测试 | ci.yml:61-64；Makefile:195、256-259 |
| 仓库是公开的。daemon 安全修复 45282f9 已经随 origin/xdial-debug 推到远程，提交说明写了利用路径；正式版 v0.9.6 用户仍然暴露 | `gh repo view`；git |
| 本机 Debug 现在是 build 1792259467，来自 d892771（Wi-Fi 分支，10-17 10:50 由另一个工作区安装），不含 daemon 修复和 AI 反馈。这就是「各工作区从自己的分支出 Debug 包、互相覆盖」的实例 | Info.plist 的 XDialSourceRevision；git |

---

## 1. 目标

| | 正式版 | beta | Debug |
|---|---|---|---|
| 身份 | 正式身份 `com.kafeifei.xdial.app`，显示名 XDial | **与正式版完全相同**：同一个 /Applications/XDial.app、同一套 helper、扩展、App Group 和 daemon | 独立身份 `com.kafeifei.xdial.debug`，显示名 XDial Debug |
| 构建配置 | Release | Release（不新增配置） | Debug |
| 源分支 | `main` | `xdial-beta`（main 加上实验 `feature/*`） | 正在验证的工作分支（已合入最新 main）；覆盖安装前检查不回退已装 Debug 里尚未进 main 的提交（PR-0） |
| 标签 | `vX.Y.Z` | `vX.Y.Z-beta.N` | 无 |
| 短版本 / 构建号 | X.Y.Z / CI 的 UTC 秒 | X.Y.Z，取下一个正式版的号 / 与正式版共用 UTC 秒序列 | 本地构建号 |
| 签名 | Developer ID 加现有的 Release profiles（release.yml:93-106） | 与正式版相同，不需要新证书或 profile | 开发证书 |
| 发布 | GitHub Release（Latest）+ stable.json | GitHub prerelease（不标 Latest）+ beta.json | 不发布；`make app` / `make restart` 只装在本机 |
| 更新 | 自动更新，只读 `https://saymiao.github.io/xdial-updates/stable.json` | 打开「接收 beta 版本」后，同时读 stable.json 和 beta.json，取较高的一份。**已装 beta 的用户不论开关状态都继续读 beta.json，直到正式版追上已装版本**；关闭开关只表示不再从正式版进入新的 beta 线，不降级 | 不自动更新（XDialBuildIdentity.swift:94） |
| 包内发布标签 `XDialReleaseTag` | `vX.Y.Z` | `vX.Y.Z-beta.N` | 空 |
| Debug Server | 无 | 无 | 有（DebugServer.swift:1 `#if DEBUG`） |
| Tailscale 设备名前缀 | `xdial-stable-` | `xdial-stable-`，和正式版是同一个节点 | `xdial-debug-` |
| 扩展显示名（决策 D1 推荐） | XDial Network Extension | 与正式版相同 | XDial Debug Network Extension |
| 配置库 | 共享的 `~/.xdial/configuration` | 同一份 | 同一份；系统组件和运行目录独立 |

**预置配置包**不算一个版本。它用正式身份，构建时注入首启 Profile（XDIAL_SEED_PROFILE_FILE，project.yml:323-340），在私有仓库打包，靠 stable.json 自动更新覆盖。本次不改它依赖的任何东西：Release 配置的取值、`make release` / `release-app` 的变量和产物路径、release-contract 默认的 stable 行为。

**不变量：**
- 编译期只有两个身份：Debug 和正式。beta 没有编译条件，不新增 XDIAL_BUILD_FLAVOR，helper 也不带 buildFlavor。
- 通道只由三样东西决定：运行时偏好、发布标签、清单。通道不参与签名包的授权比较。
- stable.json 的 URL、字段集合、字节格式和缓存命名空间 `"production"` 都不变。

---

## 2. 需要作者拍板的决策

### A 组：请逐项确认

| # | 问题 | 推荐 | 理由 | 备选 |
|---|---|---|---|---|
| D1 | 扩展名怎么跟着身份走 | 删除两份 InfoPlist.strings 第 1 行的 CFBundleDisplayName，只保留 project.yml:77 这一个来源 | 只改 2 行就消灭了「本地化覆盖身份名」这一类问题，签名路径上不加脚本 | B：strings 里写 `$(XDIAL_PRODUCT_DISPLAY_NAME)` 占位，再给扩展 target 加签名前脚本展开。正式版中文名能逐字不变，但要处理 UTF-16 strings、脚本沙盒和增量构建 |
| D2 | beta 清单的形态 | 独立的 beta.json（schema 1，channel "beta"，只放 beta）；开启 beta 的客户端同时读 stable.json，取较高者 | stable.json 的解析很严格（AppUpdateReleaseLookup.swift:158-201），一改就会让所有已发客户端和预置配置包判清单无效；读两份时，beta 链路故障或撤回，beta 用户仍能拿到正式版 | 由发布器把 beta.json 维护成 max(beta, stable)；或新 schema 的多通道清单 |
| D3 | beta 的标签和版本号 | 标签用 `vX.Y.Z-beta.N`；三个组件的短版本都写 X.Y.Z，而且 X.Y.Z 必须大于最新正式版；构建号与正式版共用 UTC 秒序列 | release-contract.sh:327-333 要求短版本等于 tag 中的版本；AppUpdateTransaction.swift:417-422 要求三个组件一致；按 SemVer，同号 beta 低于正式版，所以正式版发布时 beta 用户会自然升级 | 短版本带 `-beta.N`；或让 beta 单独占用补丁号 |
| D4 | 客户端怎么比较新旧 | 按标签 SemVer 排序：先比 X.Y.Z；X.Y.Z 相同时 beta 低于正式版；beta 之间按 N。另加一条硬条件：候选的构建号必须大于当前构建号。不满足时报独立错误 `buildNotNewer`，显示为失败并写进诊断，不当作「已是最新」 | 现在 beta 和同号正式版被判为相等；构建号更低的扩展装上后不会生效；硬条件只在构建号倒序时才改变 stable 行为，倒序本身就该暴露 | 只在 X.Y.Z 相同时要求构建号更大。前提：先核对已发布正式版的构建号是否单调，有倒序就退到这个备选 |
| D5 | 包里要不要写发布标签 | 写 `XDialReleaseTag`。正式版和 beta 都写，开发和 CI 构建留空。只用于识别当前安装的是哪个发布、界面显示和诊断 | 短版本保持纯数字以后，不写这个键就分不清装的是 beta 还是正式版 | 不写；或写「默认通道」之类的策略值（会随包替换来回翻转，也容易被拿去做授权）。**约束：** 这个键不得参与 AutomaticUpdateBundlePolicy 的授权比较，也不得参与清单地址的选择（acceptance ID 的锁定就是前车之鉴，AppUpdateTransaction.swift:400-405） |
| D6 | 偏好的默认值 | 默认关闭。偏好只来自用户开关（键 `xdial.update.channel`，只有值为 `"beta"` 才算开启）。另有一条与偏好无关的规则：已装包的 `XDialReleaseTag` 是 beta 时，始终同时读 beta.json，直到 stable 的版本 ≥ 已装版本 | 存量用户和预置配置包的行为完全不变；手动装了 beta、或关了开关的 beta 用户也不会滞留（否则他们短版本更高，stable 永远给「已是最新」，收不到任何修复） | 偏好未设置、而装的是 beta 包时，默认按 beta 处理 |
| D7 | 退出 beta | 不降级。关闭开关后继续接收当前 beta 线的修复（beta.N+1），界面提示「正式版 vX.Y.Z 发布后自动回到正式版」；下载、校验、交接期间禁用开关 | 更新器只会往前走；构建号更低的扩展不会替换已激活的扩展 | 提供降级入口（要同时解决扩展不被替换、注册交接、数据向后兼容） |
| D8 | beta 的源分支 | 新建长期分支 `xdial-beta`，只接收 main 和 `feature/*` 的合并，不合回 main。beta 标签必须在它的 first-parent 上，并且包含最新的 `vX.Y.Z` 标签 | AI 反馈实验要进 beta、不进 main；「包含最新正式标签」保证 beta 不缺正式版的修复 | beta 直接从 main 发，实验功能靠开关隔离（实验代码会随正式版一起发出） |
| D9 | 预置配置包要不要锁定只跟 stable | 不锁 | 默认关闭、stable.json 不变、公开发布门禁，这三条已经够用；构建期加的锁在第一次官方更新后就失效了。开过 beta 的用户再装一次同号预置配置包，只要该包本身含 PR-4，就不会把扩展装坏：从下载位置打开时被 D26 的安装期门禁拒绝；用 Finder 拖进“应用程序”覆盖时宿主已被替换，D26 的扩展检查发现仍登记着更高构建号的扩展，不再激活并提示先卸载（不删数据）（PR #41 评审后修正）。D26 的两道门禁都由被装进来的那个更旧的 App 执行，仅限含 PR-4 的构建；装回不含 PR-4 的版本（v0.9.6 及更早，或用旧源码打的预置配置包）不受保护，仍会宿主与扩展失配，只能先卸载再安装（PR #41 第二轮评审后补充） | 首启写入持久锁（需要新增跨版本状态和解锁路径） |
| D10 | PR #32 | 关闭，从最新 main 新开分支模型的文档 PR | 仓库用 merge commit 合并 PR，在原分支追加提交会把「build Debug from xdial-debug」永久留在 main 历史里 | 原分支追加提交；或 force-push |
| D26 | 手动降级安装 | 安装期加门禁：ApplicationRelocator.prepareForLaunch（:278-311）比较目标与来源的 CFBundleVersion，来源更低时新增决策 `.rejectDowngrade`，提示「已安装更新的版本（可能是 beta），请先在 XDial 内卸载（不勾选删除数据）」；install() 在安装锁内复核同一条件，覆盖 `--install-only` 与并发安装。Finder 拖拽覆盖在 App 运行前已替换宿主，安装期拦不住；由扩展检查补上：系统中仍登记着更高构建号的同一扩展（不在卸载中）时不再提交激活，报告该构建号并给出同样的卸载提示（PR #41 评审后补充）。范围：仅限含 PR-4 的构建，两道门禁都在被装进来的更旧 App 里执行（安装期在来源 App，扩展检查在替换后的宿主）；装回 v0.9.6 及更早不受保护（PR #41 第二轮评审后补充） | 现在手动装旧版会直接替换宿主，而扩展因构建号更低不被替换，宿主和扩展失配，连接失败只能卸载重装 | 只写文档不拦 |
| D27 | Debug 被其他工作区回退 | 新增 PR-0：`make app` / `make restart` 安装前读已装 Debug 的 XDialSourceRevision，若它不是当前 HEAD 的祖先，列出会被丢掉的提交并停止，除非显式 `ALLOW_DEBUG_ROLLBACK=1` | 规则改成「Debug 从工作分支构建」后，多个 agent 会互相覆盖；今天已经发生一次 | 只写文档提醒 |

**D1 的代价：** 中文系统里，正式版扩展名会从「XDial 网络扩展」变成「XDial Network Extension」。这只影响显示；系统按 Team 加 bundle ID 记录批准，不会要求重新批准【推断，还没在系统设置里截图核实】。

### B 组：默认按推荐执行，有异议请指出

| # | 问题 | 推荐 | 理由 |
|---|---|---|---|
| D11 | beta 用什么构建配置 | 复用 Release，不新增配置，也不改显示名 | 身份、签名、entitlements 完全相同；Next 当年就是复制配置才膨胀起来的（project.yml:37-52、95-106、159-167、222-239） |
| D12 | beta 在哪里构建 | 只在 CI（release.yml）构建 | CI 的 checkout 里没有 macos/PrivateConfig；本机构建会按 project.yml:300-340 回退，把私有预设和首启 Profile 嵌进包里 |
| D13 | 私有载荷门禁放在哪里 | beta 通道的 release-contract 拒绝 SeedProfile / RuleSetPresets.json；官方 release.yml 对 stable 和 beta 都检查；stable 的共享合约不加这项 | 预置配置包本身就带 SeedProfile |
| D14 | 只有一份清单失败时 | stable 成功就给出结论，beta 失败只作次要提示；下载和安装前，要求候选所在的清单重新验证成功 | beta 链路的故障不应挡住正式版修复 |
| D15 | Tailscale 前缀 | beta 沿用 `xdial-stable-`；剥离表里保留 `xdial-next-` | beta 与正式版共用 node key，换前缀会让切换通道时 tailnet 里的设备改名；共享 Profile 里可能还存着 `xdial-next-<id8>`（d2aff02 引入，76e746c 改掉） |
| D16 | daemon 的 Tailscale 通道值 | 改为从 runtimeIdentity 的字段取，不再直接传原始 buildFlavor（daemon.go:282、373） | 输出等价，而且在结构上保证 beta 不可能得到另一个名字 |
| D17 | Next 的兄弟进程识别 | 从 installedChannels 删除（XDialBuildIdentity.swift:147），再用测试把「残留的 Next 进程被判为未知」固定下来 | 失败方式是保守的：只会暂停 helper 维护，不会结束进程（LocalProcessInventory.swift:44-48 → HelperRegistrationCoordinator.swift:161-163） |
| D18 | Next 的旧数据位置 | 保留 ConfigurationStorage.swift:24-25 和 ConfigurationDataDeletion.swift:8 里的条目，只改注释 | 首启只读迁移要用它做来源；「删除数据」要靠它清掉本机仍存在的 ~/.xdial-next/profiles.enc 和对应钥匙串项 |
| D19 | 开发机上的 Next 残留 | 不加检测代码，只在文档里列清理清单 | Next 从未分发，检测代码对所有用户都是死代码；正式版也无权卸载 Next 的系统组件【推断，依据是 Apple 平台语义】 |
| D20 | 未知的 buildFlavor | 运行时仍回落到正式身份；在发布门禁里拒绝正式包的 helper 带 `main.buildFlavor` | helper 是 root 常驻进程，运行时报错会直接断网 |
| D21 | 仍然传入 `DEVELOPMENT_CHANNEL` | 取值不是 `debug` 时 `$(error)`；`app-debug` 改写为 `app-debug: app` | 让还在用旧参数的脚本立刻暴露，同时不打断现有的 `make app-debug` |
| D22 | beta 专属代码能不能改共享格式 | 不能。持久格式、跨进程协议版本和依赖版本只经 main 演进。beta 专属数据只能放在 profiles.enc 和既有 UserDefaults 键之外（独立文件或 `xdial.beta.*` 键）。xdial-beta 加门禁：`go.mod go.sum third_party patches/ scripts/prepare-patched-go-mod.sh` 以及配置库模型与 schema 所在文件相对 main 必须无差异（清单在 scripts/check-beta-shared-formats.sh）。CI 只作提示；release.yml 和 publish-release.py 在发 beta 前对标签提交执行同一脚本，不通过就不构建、不公开（PR #42 评审后补上 patches/ 和发布路径拦截） | 注册意图和交接协议两侧都只认 version 1（registration_handoff.go:137、PrivilegeManager.swift:269）；配置库是固定 CodingKeys 的 Codable，正式版保存时会丢掉 beta 写入的未知字段，beta 一旦把 schemaVersion 升到 4，正式版和 Debug 会拒绝加载整个配置库；App Group 里的 sing-box cache 和 Tailscale state 还受依赖版本影响 |
| D23 | FormalDevelopment 配置 | 保留，不在本次处理 | 它不是独立身份；删掉会碰到正式身份的签名配置 |
| D24 | Next 独有的分发检查 | 单独开 PR 移植：与身份无关的检查进共享合约；源码提交对应的检查只放在 release.yml | 正式通道目前没有「DebugServer 不存在」这项检查 |
| D25 | 发布文档放哪里 | beta 发布写进 docs/agent/updates.md；删除 next-releases.md 和 NEXT_RELEASE_NOTES.md；profile-next.md 改名为 profiles.md | beta 和正式版是同一条流水线，分两份文档迟早不一致 |

---

## 3. 改造步骤

### 合入顺序

```
第 0 步：v0.9.7 安全补丁（只含 daemon 修复，走现有 stable 流程，不等任何 PR）
PR-0 Debug 防回退检查（独立，尽早）
分支整理 B2–B6（与代码并行）
PR-1 扩展名 ─┐
PR-2 删 Next 发布链 ─→ PR-3 删 Next 构建身份 ─→ PR-4 客户端 beta 通道（可并行开发）
                                   Pages 先部署 beta.json 占位 ─┘
                     → 发一个带开关的正式版
                     → PR-5 发布侧 beta + PR-6 三包验收 → 首个 beta
B7 删 xdial-next（在 PR-3 之后）
加固 H1–H4：各自单独开 PR
```

### 第 0 步 v0.9.7 安全补丁（立即，独立于本计划其余部分）

- **原因：** 45282f9 的修复和利用路径说明已经在公开远程上，正式版 v0.9.6 用户仍然暴露。删掉 xdial-debug 撤不回已经公开的内容，不能算缓解。
- **做法：** 从 origin/main 拉 `claude/daemon-reject-retired-commands`，cherry-pick 45282f9，向 main 提 PR；合入后按现有 stable 流程发 v0.9.7（`make publish`，预置配置包按惯例同步发布）。Wi-Fi 修复如果已经审完，可以一起带上，但不要为它等待。
- **验证：** cmd/xdial 测试（含 TestDaemonRejectsRetiredCommands）、`make test`、`make test-macos-transaction`；发布后核对正式包的 xdial-daemon 含拒绝逻辑。

### PR-0 Debug 防回退检查（独立，低风险）

- **目标：** 任何 agent 用自己的分支覆盖安装 Debug 时，不会悄悄丢掉已装 Debug 里还没进 main 的提交（D27）。
- **文件：** 新增 `scripts/check-debug-rollback.sh`（只读：读 `/Applications/XDial Debug.app` 的 XDialSourceRevision；`git merge-base --is-ancestor <rev> HEAD` 不成立时列出 `git log --oneline HEAD..<rev>` 并退出非零，`ALLOW_DEBUG_ROLLBACK=1` 时放行）；`Makefile` 的 restart 与安装入口在动 /Applications 之前调用它；`docs/agent/development-builds.md` 写明规则。
- **依赖：** 无。
- **验证：** 在一个不含已装提交的分支上 `make -n restart` 应停止并列出提交；设置 `ALLOW_DEBUG_ROLLBACK=1` 后放行；已装版本是 HEAD 祖先时直接通过。

### PR-1 扩展显示名跟着身份走（独立，低风险）

- **目标：** 扩展名只来自 `XDIAL_PRODUCT_DISPLAY_NAME`，并用校验把这一类问题锁住。
- **文件：**
  - `macos/TransparentProxyExtension/en.lproj/InfoPlist.strings`、`zh-Hans.lproj/InfoPlist.strings`：删除第 1 行，保留 NSSystemExtensionUsageDescription。
  - `macos/Sources/XDial/InstallationView.swift:170-171、175-176`：写死的 XDial 改为 `XDialBuildIdentity.applicationDisplayName`。
  - `macos/Sources/XDial/TransparentProxyManager.swift:4177、4207-4217`、`macos/TransparentProxyExtension/TransparentProxyProvider.swift:3047`、`macos/Sources/XDial/ApplicationRelocator.swift:1059、1063`：写死的「XDial 网络扩展」改为由 `XDialBuildIdentity.applicationDisplayName` 拼出，和系统显示保持一致。
  - 新增 `scripts/verify-macos-component-names.py`，只读校验：宿主和 Settings UI 的 CFBundleDisplayName、CFBundleName 等于产品名；扩展 Info.plist 等于「产品名 Network Extension」；扩展的任何 lproj 都不定义 CFBundleDisplayName；所有值里不出现 `$(`。读取用 `plutil -convert json -o -`，因为产物是 UTF-16 文本。
  - 接入新校验：`scripts/verify-macos-debug-app.py`（:52-57 附近）、`scripts/release-contract.sh` 的 verify_app（:318-332 附近，正式版、beta 和预置配置包都会经过）、`Makefile` 的 ci-macos-build（:313-324）。
  - `scripts/verify-macos-identity-contract.sh`：静态检查源码里所有 `*.lproj/InfoPlist.strings` 都不定义名字键，三个 Info.plist 的 CFBundleDisplayName 都含 `$(XDIAL_PRODUCT_DISPLAY_NAME)`。
  - 新增 `test/component_names_test.py` 并挂到 test-release-contract，正反例都要有。
  - `docs/agent/development-builds.md:10-20`：身份表加一行「系统设置显示名」。
- **依赖：** 无。
- **验证：**
  - `make macos-identity-contract`；反向检查：临时把 strings 改回写死的名字，应失败。
  - 依次跑 `make ci-macos-build`、`make test-release-contract`、`make app`（要通过 verify-macos-debug-app.py）。
  - 用 `plutil -p` 只读查看产物的 lproj，应不含 CFBundleDisplayName。
  - 作者按自己的流程装上新 Debug 后：`systemextensionsctl list` 里 debug 扩展名为 "XDial Debug Network Extension"；在系统设置「登录项与扩展 → 网络扩展」里目视确认。这一步是把【推断】变成看到的事实。
  - 预置配置包用同一份源码构建，按理也能通过新校验；由作者在私有仓库重打一次确认。

### PR-2 删除 Next 发布链（独立，低风险）

- **目标：** release-contract 只剩 stable，为后面加 beta 让出位置。
- **文件：**
  - 删除：`scripts/publish-next-release.py`、`scripts/verify-next-release-identity.py`、`test/next_release_contract_test.sh`、`test/publish_next_release_test.py`、`NEXT_RELEASE_NOTES.md`、`docs/agent/next-releases.md`。
  - `Makefile`：删除 388-429（NEXT_* 变量、release-next-inputs/app、release-next、publish-next）和 396 的 .PHONY；删除 199 行的 next 测试。
  - `scripts/release-contract.sh`：删除 next 的 case（14-19）、version_from_tag 的 next 分支（62-65）、assert_git_tag 的 next 分支（116-118）、verify_app 的 next 钩子（313-316）。stable 的正则、报错和默认值一律不改。
  - `test/release_contract_test.sh:219-227`：改写过时的注释；会触发远程 fetch 的 `make publish` 用例改成离线拒绝用例，或者删掉。
  - 用 rg 找出所有指向 next-releases.md 的链接（包括 AGENTS.md:6），一并改掉。
- **依赖：** 无。
- **验证：**
  - `make test-release-contract`：stable 原有用例一条不改，全部通过。
  - `rg -n 'next-v|publish-next|release-next|NEXT_RELEASE' Makefile scripts test .github` 无结果。
  - `make -n release-next` 报 no rule。

### PR-3 删除 Next 构建身份（必须作为一个 PR 原子合入）

- **目标：** 编译期只剩 Debug 和正式两个身份。Swift、project.yml、Makefile 和校验脚本如果分开合入，会出现 bundle ID 是 next.\*、身份常量却是正式身份的中间状态。
- **构建与签名：**
  - `macos/project.yml`：删除 configs 里的 Next、NextRelease（7-8）；删除 Next 锚点和 NextRelease 设置（37-52）；删除三个 target 的 Next 签名块（95-106、159-167、222-239）；285、381 改为只判断 Release；删除 307-310 和 333 的 NextRelease 条件；改写 22-23 的注释。Debug、FormalDevelopment、Release 的键值一个都不改。
  - 删除 `macos/XDialNext.entitlements`、`XDialNextRelease.entitlements`、`XDialDaemonNext.entitlements`、`TransparentProxyExtension/XDialTransparentProxyNext.entitlements`、`XDialTransparentProxyNextRelease.entitlements`、`macos/com.kafeifei.xdial.next.daemon.plist`。
  - `Makefile`：5-16 固定为 Debug，派生数据目录仍是 build/macos-debug-xcode，增量缓存不会失效；DEVELOPMENT_CHANNEL 取值不是 debug 时报错（D21）。删除 cli-next（275-277）、app-next（284-285）和相关 .PHONY（83、280）。app 改为依赖 cli-debug；309 行不再传通道；restart（437）去掉 DEVELOPMENT_CHANNEL；`app-debug`（282）改为 `app-debug: app`。ci-macos-build 去掉 cli-next，循环只编 `Debug Release`。
- **Swift：**
  - `macos/Shared/XDialBuildIdentity.swift`：删除 42-68；8-16 只剩 debug 和 stable，并注明 beta 必须报告 stable；删除 147；160-165 改为按 isDevelopment 二选一，取值不变；改写 3-6、133-135 的注释。
  - `macos/Sources/XDial/main.swift`：删除 13-52，这是 Next 专用的导入命令。
  - `macos/Sources/XDial/ProfileDocumentService.swift:69-72`、`ExistingXDialProfileReader.swift:7-14、107-109`：删除。保留 read、restore、readKeychainVault，首启转换要用。
  - `macos/Sources/XDial/DebugServer.swift:691-694`：删除。Debug 下这些 action 本来就返回 400（:836-842）。
  - `macos/Shared/InstallationTransaction.swift:376`：删除 next 映射。
  - `macos/Shared/ScenarioSwitchFeedback.swift:72`：白名单改为 debug、stable。
  - `ConfigurationStorage.swift:3、24-25`、`ConfigurationDataDeletion.swift:8`、`ProfileLibraryMigration.swift:5`：只改注释，条目保留（D18）。
  - 文案：`GeneralSettingsView.swift:195-200`（只剩 Debug 的手动更新说明）、`LineLatencyView.swift:73`、`InstallationView.swift:250-251、487-488`。可选：`GeneralSettingsView.swift:172` 的「与其他版本的数据独立」与共享配置库的事实不符，可以一并改。
- **Go：**
  - `cmd/xdial/identity.go`：删除 27-40；8-10 的注释补充「没有 beta flavor」；新增 tailscaleDeviceChannel 字段（D16）。
  - `cmd/xdial/daemon.go:282、373`：改用身份结构里的字段。
  - `core/config/tailscale_channel.go`：15 只认 debug；20 保留 `xdial-next-` 并注明来历；11-12 的注释说明 channel 指的是安装身份。
- **脚本：**
  - `scripts/verify-macos-identity-contract.sh`：删除 106-134、177-187；191 只留 debug 和 app。新增四项检查：`xcodebuild -list` 恰好列出 Debug、FormalDevelopment、Release；每个配置的 XDIAL_PRODUCT_DISPLAY_NAME 和 XDIAL_BUILD_FLAVOR；Release 和 FormalDevelopment 三个 target 的编译条件都不含 DEBUG（从 118-120 移植）；`git grep -n XDIAL_NEXT_IDENTITY -- macos` 无命中（发布环境不保证有 rg；退出码 1 算通过，≥2 算失败）。
  - `scripts/verify-macos-debug-app.py:26-29` 只认 debug；`scripts/jev_loop.py:107` 改为 {debug, stable}；`test/scenario_layout_test.py:17` 只接受 Debug。
- **测试：**
  - `XDialBuildIdentityTests.swift`：删除 5-53；正式身份断言 "stable"，Debug 断言 "debug"；installedChannels 的标识集合为 {app, debug}。
  - `LocalProcessInventoryTests.swift`：第 6 行去掉 "XDial Next.app"；新增用例：Next 路径下的 xdial-daemon 返回 nil。
  - `SiblingProductProcessIdentityTests.swift:18`、`InstallationTransactionTests.swift:299/306`：next 标识换成正式标识。
  - `ConfigurationDataDeletionTests.swift:31`：外层只遍历在用身份，内层仍覆盖 next。
  - `ExistingXDialProfileReaderTests.swift:36/47/59/76`：改为调用 read(...)。
  - `cmd/xdial/identity_test.go`：删除 33-53；13-24、56-67 的 want 加上 tailscaleDeviceChannel；第 68 行的列表加入 beta、stable、next，断言它们都等于正式身份；新增断言：正式身份和 Debug 的 socket、目录、App Group 等资源两两不同。
  - **门禁前移（原 H2、H3）：** `Makefile:195` 的 `make test` 加上 `./cmd/xdial/`；CI 用 Release 配置、`CODE_SIGNING_ALLOWED=NO` 跑一次 XDialTests。否则本 PR 最关键的身份断言（正式身份分支、cmd/xdial）在 CI 里一条都不执行。
  - `core/config/tailscale_channel_test.go`：通道改为 {debug, stable}；保留 `xdial-next-*` 输入用例；新增别名测试和金样本测试。金样本的值要先在改动前的 main 上实测得到。
  - `test/jev_loop_test.py`：channel=next 计为 invalid。
- **文档：**
  - `AGENTS.md:6、16`；`ARCHITECTURE.md:27、94、97-98、300、335`；`docs/agent/development-builds.md:6、48、55-56`，并新增「开发机 Next 残留清理」一节（内容见 §4）。
  - `docs/agent/profile-next.md` 用 git mv 改为 `docs/agent/profiles.md`：删除 3-22、131-132、136；:170 改为 Debug；42-44 的历史目录清理保留；同步改 3 处引用。
  - `docs/agent/jev-loop.md:55-61`；`DESIGN.md:226`；`macos/Examples/README.md:17`。
  - `docs/plans/next-interface-redesign.md`、`global-configuration.md`：开头加一行「历史记录」。
- **依赖：** PR-2。
- **验证：**
  - 改前保存、改后对比 9 组 `xcodebuild -showBuildSettings`（Debug、FormalDevelopment、Release × 三个 target）。Release 和 FormalDevelopment 必须逐键一致；Debug 只允许出现预期内的变化。
  - `xcodebuild -list` 只列出 3 个配置。
  - `rg -n 'XDIAL_NEXT_IDENTITY|NextRelease|com\.kafeifei\.xdial\.next|XDial Next|xdial-next|buildFlavor=next' macos scripts test cmd core Makefile .github` 的结果只剩明确保留的旧数据兼容项和测试输入。
  - 依次跑 `make macos-identity-contract`、`make test-release-contract`、`make ci-macos-build`、`make test-macos-transaction MACOS_TEST_XCODEBUILD_FLAGS=CODE_SIGNING_ALLOWED=NO`，以及 `go test ./cmd/xdial/ ./core/config/`（带补丁环境）。
  - `make -n app-debug`、`make -n restart` 能展开；`make app` 要通过；用 `go version -m` 只读检查 helper，构建信息应含 `main.buildFlavor=debug`。
  - 收尾核对：`rg -n -w -e '"next"' -e 'Next' macos scripts test cmd core Makefile`，只允许 D15、D18 明确保留的条目和分页按钮等无关命中。
  - `make test-scenario-layout` 会执行 Debug 产物，由作者决定是否跑。

### PR-4 客户端 beta 通道（必须先随一个正式版发出）

- **目标：** 正式身份的客户端能按偏好订阅 beta；偏好关闭时，stable 用户的行为逐字节不变。
- **文件：**
  - `AppUpdateReleaseLookup.swift`：
    - 新增 AppUpdateChannel。production(stable) 的 URL 和 cacheNamespace `"production"` 不变；production(beta) 指向 beta.json，命名空间为 `"production-beta"`；acceptance 的地址改为 `acceptance/<ID>/<channel>.json`。
    - parse 增加 expectedChannel，把 199-201 改为「必须等于配置的通道」。
    - 新增 AppUpdateChannelLookup，两个 feed 各自独立维护 backoff、ETag 和修订链。偏好为 stable 时只请求 stable.json。
  - `AppVersion.swift`：新增 ReleaseTag，用严格正则解析并实现比较（D4）；保留 stableVersion(fromTag:)（22-38），DebugServer.swift:732 在用。
  - `AppUpdateTransaction.swift`：
    - selectCandidate（51-55）按通道选择标签规则；isNewer（100-105）改为 ReleaseTag 比较加构建号硬条件；候选增加 channel 和 tag 字段。
    - 重启意图升到 schema 2，增加 targetBuild。`AppUpdateRelaunchIntentPolicy.permitsTarget` 同时接受 schema 1（只比 targetVersion）和 2（再比 targetBuild），以后也沿用「接受 ≤ 当前 schema」。否则从 v0.9.x 首次自动更新到这个版本会整体失败，不只是不恢复连接。loadDecision 和 permitsStagedSuccessor 两条路径都要有单测，输入用 v0.9.6 实际写出的 JSON 字节。
    - 已装 beta 时不论开关都读 beta.json（D6）；开关从开到关时，只丢弃「从正式版进入 beta 线」的暂存更新。
  - `AppUpdateChecker.swift`：
    - 新增 InstalledRelease，读取短版本、构建号和 XDialReleaseTag。只有标签能解析为 beta、且 X.Y.Z 等于短版本时才算 beta 安装；其余情况一律当作正式版 `v<短版本>`。它替换 218-221、322-324、457-461 的裸版本号。
    - 新增偏好键 `xdial.update.channel`；开启时立即检查一次；忙碌时拒绝切换；新增 awaitingStable 状态。
  - `ApplicationRelocator.swift:259-269`、`AppState.swift:666-671`：重启意图匹配时额外传入 CFBundleVersion。
  - `ApplicationRelocator.swift:278-311`：降级门禁 `.rejectDowngrade`（D26），`InstallationTransactionTests` 补用例。
  - `macos/project.yml`：base 加 `XDIAL_RELEASE_TAG: ""`，宿主 info.properties 加 `XDialReleaseTag: "$(XDIAL_RELEASE_TAG)"`；重新生成入库的 macos/Info.plist。
  - UI：
    - `GeneralSettingsView.swift:189-194` 下方加「接收 beta 版本」开关，默认关闭、忙碌时禁用，说明写明不降级；`230-234` 显示标签。
    - `AppUpdateView.swift:162-173`、`MainPopover.swift:86-87、190、211-212` 改用标签显示，beta 候选加标记。
  - `DebugServer.swift:268-275`：appUpdate 增加 tag、channel、preference、最近一次 buildNotNewer 诊断。`DebugServer.swift:725-745` 的 fake-update 和 `AppUpdateChecker.injectFakeRelease` 增加 tag、channel 参数，用来在本机验证 beta 候选的界面。
  - `macos/Tests/AppUpdateCheckerTests.swift`：
    - 冻结 stable 的 URL 和命名空间；保留 :170 和 16-25 的拒绝断言。
    - 版本序穷举：纯 X.Y.Z 时，新比较与旧 isNewer 结果完全等价。
    - 偏好关闭时，传输层只看到 stable.json 一个 URL。
    - 覆盖取高者、beta 撤回后回落、部分失败、关闭时不降级、「开关关、已装 beta、beta.json 有 beta.N+1 → 升级」、重启意图 v1/v2、beta 包与 stable 包互相替换、构建号倒序报 buildNotNewer。
    - 版本序穷举的等价性只在「候选构建号 > 当前」的输入上断言。
  - 文档：`DESIGN.md:225-226、316-317`、`ARCHITECTURE.md:311-314`。
- **依赖：** PR-3 合入后再合，两者在 GeneralSettingsView:195-200 有重叠。Pages 上的 beta.json 占位必须在这个正式版发布前上线。
- **验证：** `make test-macos-transaction`。确认发布的正式版只请求 stable.json（看网络日志）。

### Pages 清单仓库（跨仓库，本仓库看不到那边的代码）

- **先补回退能力，再改生成器：** 新增并演练一次 `operation=restore`，把最后一份已知良好的 stable 清单字节以 revision+1 重新发布，只对这个操作放开「旧版本覆盖」限制；在 `acceptance/<ID>/stable.json` 上演练。现有发布器拒绝旧版本覆盖和同标签改写，没有它，stable 清单出错时无路可退。
- 新增 channel 输入。beta.json 用 schema 1、channel "beta"，有独立的 revision 链和历史，withdraw 按通道执行。
- 首个带开关的客户端发布之前，先部署 release:null、revision 1 的 beta.json，以及 `acceptance/<ID>/beta.json`。
- stable.json 的生成逻辑和字节格式不变。发布器拒绝两种写入：把 prerelease 标签写进 stable.json，把正式标签写进 beta.json。
- **验证：** beta.json 返回 200、application/json、带 ETag、不重定向；改造前后各取一次 stable.json，逐字节比对；publish-release.py 的 verify_feed 增加结构比对（除 revision、generatedAt、release 外与改造前逐字节一致）。

### PR-5 发布侧 beta（release.yml、合约和 Makefile 必须同 PR 合入）

- **目标：** 从 xdial-beta 按 `vX.Y.Z-beta.N` 发 prerelease 并写 beta.json；stable 的默认行为不变。
- **文件：**
  - `scripts/release-contract.sh`：
    - 身份常量无条件取正式身份；通道只决定标签语法和源分支（stable 对应 main，beta 对应 xdial-beta）；默认仍是 stable。
    - beta 正则严格到 `-beta\.[1-9][0-9]*$`。assert_git_tag 对 beta 沿用 first-parent 规则，并要求包含最新的 vX.Y.Z 标签。
    - 新增只读子命令 version-from-tag 和 release-branch。
    - beta 通道的 verify_app 要求 XDialReleaseTag 严格等于标签、拒绝空值：它是客户端认出已装 beta 的唯一依据，留空的 beta 会被当作正式版，同号正式版发布时判为不更新、也不再读 beta.json。只有 stable 通道为预置配置包保留宽松规则（为空或等于标签）。beta 通道拒绝 SeedProfile 和 RuleSetPresets.json。
  - `Makefile`：
    - 新增 `RELEASE_CHANNEL ?= stable`。24 行改用合约的 version-from-tag，stable 的结果与现在的 patsubst 相同。
    - 通道接线写明：`RELEASE_CONTRACT := XDIAL_RELEASE_CHANNEL=$(RELEASE_CHANNEL) scripts/release-contract.sh`，覆盖 Makefile:364-375、381-386 的全部合约调用。
    - release-inputs（329-339）按合约给出的分支 fetch，并选 notes 文件（RELEASE_NOTES.md 或 BETA_RELEASE_NOTES.md）。beta 允许带 RELEASE_UPDATE_ACCEPTANCE_ID 构建（PR-6 需要），只在 publish 和 release.yml 里拒绝；acceptance 构建跳过 xdial-beta 分支门禁。
    - release-app（341-366）的两次 xcodebuild 都传 XDIAL_RELEASE_TAG。产物路径不变。
  - `.github/workflows/release.yml`：
    - 34-44 按标签形态选通道并 fetch 对应分支；121-126、143 的 notes 文件随通道走。
    - beta 用 `--prerelease --latest=false`，仍然先建 draft（137-143）。
    - 新增官方产物检查：stable 和 beta 都不含 SeedProfile 与 RuleSetPresets.json；XDialReleaseTag 严格等于标签。
    - 93-106 的签名断言不变。
  - `.github/workflows/ci.yml:5`：push 触发加上 xdial-beta。
  - `scripts/publish-release.py`：
    - 29 行的标签正则拆成 stable 和 beta 两套；validate_release（108-138）按通道核对 prerelease 标志。
    - beta 要校验三点：标签在 xdial-beta 的 first-parent 上、包含最新正式标签、X.Y.Z 大于最新正式版。
    - 新增构建号门禁，数据源是全部已公开过的 release（含 prerelease 和已撤回的，取 GitHub Releases 列表或 Pages 历史），不只是两份清单的当前值。规则：新包构建号必须大于所有「X.Y.Z ≤ 新包 X.Y.Z」的已发布包；stable 热修复的 X.Y.Z 低于开放中的 beta 线时，不要求大于 beta 的构建号。
    - beta 线开放期间发 stable 热修复时，脚本提示并要求同批发 beta.N+1，避免 beta 用户收不到修复。每次发 stable 后，若 beta.json 当前条目的构建号低于新 stable，必须同批重发 beta.N+1 或撤回该条目：否则装了热修复又开着 beta 的用户每次检查都会看到 `build_not_newer` 失败（PR-4 按 D4 字面实现，代价见 docs/agent/updates.md）。
    - beta 公开时用 `--latest=false`，替换 260 行的 `--latest`。dispatch 时传 channel；回读按通道读取并核对。
    - stable 是否也拒绝 SeedProfile，取决于预置配置包是否走这个脚本（本仓库看不到，需作者确认）。
  - 测试：
    - `test/release_contract_test.sh` 新增 beta 用例：接受 v1.4.0-beta.1；拒绝 v1.4.0、-beta.0、-beta.01、-rc.1；first-parent fixture；归档名 XDial-v1.4.0-beta.1.zip。stable 仍拒绝 -beta.1。
    - `test/publish_release_test.py:95` 保留，另加 beta 的正反例，以及「beta 撤回后，同号 stable 构建号更低被拒」。
  - 文档：`docs/agent/updates.md` 新增「通道」和「beta 发布机制」两节；`ARCHITECTURE.md:300` 后补一句通道不改变身份；`AGENTS.md` 去掉 xdial-beta 那一行的「上线前」限定。`BETA_RELEASE_NOTES.md` 只放在 xdial-beta 分支上。
- **依赖：** PR-2、PR-4（XDialReleaseTag 键）、Pages 清单仓库。`tags: v*` 已经会被 beta 标签触发（release.yml:3-6），所以 PR-5 合入之前不能推任何 beta 标签。
- **验证：**
  - `make test-release-contract`，stable 用例不改；`python3 -m unittest discover -s test -p 'publish*release_test.py'`。
  - 在 fork 或验收仓库推 `v0.0.1-beta.1` 演练：应生成 draft prerelease、不标 Latest、归档名正确。
  - 构造一个含 SeedProfile 的假 zip，确认会被拒绝。

### PR-6 三包验收

- `scripts/build-update-acceptance.py` 增加 `--beta`。用同一个 acceptance ID 构建三个包：A 为 stable X.Y.Z（构建号 n），B 为 X.Y.(Z+1)-beta.1（n+1），C 为 stable X.Y.(Z+1)（n+2）。
- 验收步骤：
  1. A 开启 beta，应升级到 B。
  2. B 关闭 beta，应停留在 B，并显示「等待正式版」。
  3. C 发布后，B 应升级到 C。
  4. 每一步核对 host、settings、extension、daemon 的版本和构建号。
- **跨版本验收：** `build-update-acceptance.py` 再加 `--lower-ref`，低版本包从当前正式标签构建（而不是同一个 HEAD），用来覆盖 schema 1 重启意图等跨版本兼容；同一 HEAD 构建的两个包测不出这类问题。还要明确覆盖 schema 2 → schema 2：低版本包取第一个含 PR-4 的正式标签，确认它写出的重启意图（带 targetBuild）被高版本接受、暂存继任通过、原场景恢复连接。
- 文件清单写明 `--beta` 时 tag、notes 标题、归档名，以及 BUILD-INFO 中的 tag 和 channel 怎么改。
- 验收包用正式身份，**会替换本机的正式 App**，由作者执行。
- **依赖：** PR-4、PR-5、Pages 清单仓库。

### 上线顺序

0. v0.9.7 安全补丁（见第 0 步），不等下面任何一步。
1. Pages 先补 restore 并演练，再部署 beta.json 占位。
2. 发一个含 PR-4 的正式版；预置配置包按现有流程跟随。
3. 合入 PR-5 和 PR-6，三包验收通过。
4. xdial-beta 合入最新 main，写 BETA_RELEASE_NOTES.md，打 `vX.Y.Z-beta.1`（X.Y.Z 取下一个正式版号）。CI 产出 draft 后执行 `make publish RELEASE_CHANNEL=beta`。
5. 核对三点：`releases/latest` 仍是正式标签；stable.json 的 revision 和 SHA-256 不变；beta.json 是新标签和新构建号。

### 分支整理（涉及推送和删除远程分支，每一步都要作者确认）

| 步骤 | 内容 | 依据 / 前置 |
|---|---|---|
| B1 | daemon 修复：即第 0 步，单独发 v0.9.7 | 45282f9 已随 origin/xdial-debug 公开；main 自 774829f 以来没改过它涉及的 6 个文件，可以干净 cherry-pick |
| B2 | Wi-Fi 修复：origin/claude/notebook-wifi-switch-issues-0e290d（d892771）直接向 main 提 PR | 它已包含 main 顶端 9b7cf58；【推断】可能已经是 PR #11。和 B1 都改了 ARCHITECTURE.md，后合入的那个要手工合并该段 |
| B3 | 新建 `feature/ai-feedback`：从 origin/main 拉出，revert 9b7cf58（重新应用 AI 反馈），再合入 origin/feature/ai-feedback-native（a33df5c） | 和 xdial-debug 上 ee67fe4→e8c0d23 的顺序一致，那次 `--cc` 为空；成熟后由这条分支向 main 提 PR |
| B4 | 新建 `xdial-beta`：从 origin/main 拉出，`--no-ff` 合入 feature/ai-feedback 后推送。以后只用 merge，不 force push | D8 |
| B5 | 分支模型文档 PR（替代 #32）：AGENTS.md 第 5 行恢复 main 现行的 Debug 安装规则（验证后直接覆盖安装并重启 Debug），加上 PR-0 的防回退说明，去掉 xdial-debug 的内容。分支表改为 main、工作分支、xdial-beta（注明「beta 发布上线前只作集成线，不分发」）、xdial-next（已冻结）。表下写三条规则：Debug 从正在验证的工作分支构建，没有 Debug 专用分支；修复直接向 main 提 PR，实验在 feature/* 上开发、合进 xdial-beta，成熟后由同一 feature/* 向 main 提 PR；被 main 回滚过的功能要先在它的 feature/* 上撤销回滚。`docs/agent/development-builds.md` 新增「Debug 构建来源」一节，说明 XDialSourceRevision 记录的是构建时的提交 | D10 |
| B6 | 撤掉 xdial-debug：先确认 `git log --no-merges origin/main..origin/xdial-debug` 列出的 8 个提交都有去处（Wi-Fi 分支、xdial-beta，或在 daemon PR 分支上 `git cherry` 显示为 `-`），再删除远程和本地分支以及工作区。工作区里有未提交的两个 .icns，先确认它们是构建产物。删除分支撤不回已公开的内容，不能代替第 0 步 | B1–B4 |
| B7 | 删除 xdial-next 和 next-baseline 工作区 | PR-3 合入之后；`rev-list --count origin/main..origin/xdial-next` 为 0，且没有 next-v* 标签 |

### 加固（各自单独开 PR，都是净增的门禁）

| # | 内容 |
|---|---|
| H1 | 把 Next 独有的分发检查移植过来（D24）。进共享合约的：四个组件都有 runtime 和 timestamp；helper 和 carrier 没有 get-task-allow（现在只检查宿主和扩展，release-contract.sh:345-346）；宿主不含 "DebugServer:"；helper 不带 main.buildFlavor（D20）。只放官方 CI 的：helper 的 vcs.revision 等于标签所在提交，且 vcs.modified=false |
| H2、H3 | 已前移到 PR-3（`make test` 加 `./cmd/xdial/`；Release 配置跑 XDialTests） |
| H4 | 版本常量契约测试：注册意图和交接协议版本、dns-takeover.json 版本、Tailscale 迁移标记 v1、配置库 schemaVersion，对应 D22 |

**工作量（调研估算）：** PR-1 约 0.5 天；PR-2 约 0.25 天；PR-3 1.5–2 天；PR-4 2.5–3 天；PR-5 约 1.5 天；Pages 清单仓库 0.5–1 天；PR-6 0.5–1 天（含公证）；分支整理约 0.5 天。另加第 0 步安全补丁约 0.5 天、PR-0 约 0.25 天。合计约 9–11 人日，不含加固 PR。

---

## 4. 迁移与兼容

| 对象 | 影响 | 要做什么 |
|---|---|---|
| 正式版现有用户 | bundle ID、App Group、daemon label、数据目录、helper 的构建方式（Makefile:342-345）、Tailscale 前缀都不变，不会重新批准，也不会重装 helper。stable 的缓存键 `xdial.update.pages-cache.production` 和修订链继续沿用。旧客户端只读 stable.json，看不到 beta。可见变化只有扩展显示名（采用 D1 推荐时） | 在发布说明里提一句扩展名的变化。新版本必须能读旧版本写的 schema 1 重启意图，否则从旧正式版自动更新到首个新版本后不会恢复连接 |
| 预置配置包 | 打包命令和 Release 配置不变；release-contract 默认仍是 stable；它带私有后缀的标签不会匹配严格的 beta 正则。被官方 stable 覆盖后会出现开关，默认关闭；首启 Profile 账本和更新偏好互不影响（AppState+Profiles.swift:77-140） | 需作者确认（本仓库看不到）：① 私有流程没有传 `-X main.buildFlavor`；② 没用 NextRelease 或 `XDIAL_RELEASE_CHANNEL=next`；③ 构建号与官方一致且单调；④ 是否调用 publish-release.py；⑤ 如果流程会自动挑「最新标签」，确认只会挑到正式标签。合入后在私有仓库用新的 main 重打一次，并跑 verify-app |
| 本机 Debug | 身份、19877 端口、~/.xdial-debug、debug.\* 都不变；`make app`、`make app-debug`、`make restart` 用法不变。当前装的是 d892771（Wi-Fi 分支顶端），今天被另一个工作区从 xdial-debug 覆盖回来，因此不含 daemon 修复和 AI 反馈 | PR-0 合入后，这类覆盖会被拦下并列出丢失的提交。daemon 修复随 v0.9.7 进 main 后自然回到 Debug；AI 反馈改到 beta 线。下次覆盖安装后扩展名变为 XDial Debug，旧条目在重启前可能还显示旧名【推断】 |
| 开发机上残留的 Next | 本机看到：没有 XDial Next.app；`launchctl print` 查不到 next daemon，但另一路调研看到 launchd 里还有一条 enabled 记录【推断：只剩启用记录，服务没有加载】；Next 扩展处于 terminated waiting to uninstall on reboot。残留数据有：~/.xdial-next/profiles.enc、钥匙串 com.kafeifei.xdial.next、~/Library/Preferences/com.kafeifei.xdial.next.plist、App Group 容器 UVZM439VGU.com.kafeifei.xdial.next.network、~/Library/Logs/XDial Next、/Library/Application Support/XDial Next（root 属主）、/Applications/.XDial-next.installation.lock、/tmp/xdial-next\* | 写进 development-builds.md：① 先用只读命令自查；② 如果 Next.app 还在，用它自己的卸载流程，**不要勾选「删除数据」**，否则会删掉共享配置库（ARCHITECTURE.md:304-306）；③ 扩展在重启后由系统移除；④ **不要用任何版本的「卸载并删除数据」清理 Next**：它会同时删掉共享配置库、正式版与 Debug 的旧数据和全部配置密钥，还会卸载那个 App 本身；只用定点命令：`rm -rf ~/.xdial-next`、`defaults delete com.kafeifei.xdial.next`、`security delete-generic-password -s com.kafeifei.xdial.next`（重复执行到 not found）；⑤ App Group 容器、日志、root 目录和锁文件按上面的路径手动删；⑥ 升级 Debug **或正式版**前都不能有 Next 进程在运行，否则 helper 维护会停在「进程状态未知」。另外：Apple 开发者后台里 Next 的 App ID、App Group 和两份 profile 可以作废；tailnet 里 `xdial-next-*` 的陈旧设备可以手动删；本地 build/\*next\* 目录可以删 |
| 共享配置库 | 路径和密钥 service 与通道无关（ConfigurationStorage.swift:6-7、ProfileLibraryStore.swift:18-19）。本机 ~/.xdial/configuration 已存在，首启迁移不会再运行。beta 和正式版共用同一份 | 保留 ~/.xdial-next，作为只读迁移源和删除清单项（D18）。beta 不得单方面提升配置库 schema（D22） |
| Tailscale 身份 | 持久状态路径由 App Group 加 Profile ID 决定，与设备名无关（tailscale_channel_test.go:27-63）。正式版仍是 xdial-stable-…，Debug 仍是 xdial-debug-…。beta 与正式版同一个 node key、同一个名字，切换通道不改名、不需要重新登录。已持久化的 `xdial-next-<id8>` 继续投影成 `xdial-stable-<id8>` | 用金样本测试把投影输出固定下来 |

---

## 5. 风险与回退

| 风险 | 影响 | 预防 | 回退 |
|---|---|---|---|
| 误改 Release 的取值或 stable 合约的默认行为 | 正式版和预置配置包出包失败，或产物与官方不一致 | 9 组 showBuildSettings 对比；stable 用例不改；私有仓库重打一次 | revert 对应 PR；验证通过前不发版 |
| stable.json 的格式或内容被改动 | 所有已发客户端判清单无效，收不到更新【推断，由解析器的严格校验推出】 | 客户端测试冻结格式；Pages 发布器拒绝错误写入；verify_feed 结构比对 | 用事先演练过的 `operation=restore` 以 revision+1 重发上一份良好内容。不能直接回退 revision，客户端会拒绝（AppUpdateReleaseLookup.swift:613-626） |
| Swift 删除和 project.yml 删除不在同一个 PR | Next 配置用正式身份常量编译，身份失配 | PR-3 原子合入 | revert 整个 PR |
| 还有 `buildFlavor=next` 的构建入口没删 | helper 得到正式身份，与正式版抢同一个 socket | PR-3 删除所有入口；H1 门禁 | revert |
| 漏删 `#if XDIAL_NEXT_IDENTITY` | 编译不报错，死代码静默留下 | 身份合约里的 rg 门禁 | — |
| 某台开发机上 Next 还在运行 | helper 维护停在 processStateUnknown | 文档写明前置条件；测试固定 fail-closed 行为 | 卸载 Next 即恢复 |
| 扩展名变成英文 | 中文系统用户看到的名字变了 | 在发布说明里提一句 | 另开 PR 改用 D1 方案 B |
| 在 PR-5 之前推了 beta 标签 | release.yml 失败，留下无用标签 | PR-5 合入前不打 beta 标签；推标签前先在本地跑 validate-inputs | 删掉 draft 和标签 |
| beta Release 被标成 Latest | publish-release.py:242-247 会拒绝之后的正式版发布 | 发布器断言 prerelease 且 latest=false，公开后再复查一次 | 用 gh 改回 prerelease，把正式版重新标为 Latest |
| 构建号不单调 | 扩展不被替换，宿主和 Provider 版本不配套 | 只用 CI 时间戳；发布门禁；客户端构建号硬条件 | 发一个构建号更高的修复版 |
| beta 和同号正式版共用短版本号 | 重启意图误判；界面出现「v0.10.0 → v0.10.0」 | 重启意图带上构建号；界面用标签；用 rg 复查 `CFBundleShortVersionString` 和 `candidate.version` | — |
| 私有载荷进了公开包 | 私有配置外泄 | beta 只在 CI 构建；beta 合约和 release.yml 两道门禁 | 撤回 Release，清单 withdraw |
| beta 实验代码改了共享格式或协议版本 | 更高版本的正式版读不懂：Tailscale 要重新登录，或维护标记卡住 helper | D22 规则；H4 测试 | 下一个 beta 把格式改回去 |
| 用户手动安装旧正式版或同号预置配置包覆盖 beta | 不处理时宿主降级、扩展不降级，连接失败 | D26（仅限含 PR-4 的构建，门禁由被装进来的更旧 App 执行）：从下载位置打开或 `--install-only` 时安装期直接拒绝；Finder 拖拽覆盖时扩展检查不再激活，并提示先卸载（不删数据）。装回不含 PR-4 的版本（v0.9.6 及更早，或用旧源码打的预置配置包）不受保护；上线顺序第 2 步先发含 PR-4 的正式版，覆盖最常见的同号预置配置包 | 先走卸载事务，再安装 |
| stable 发热修复时 beta 版本更高 | beta 用户要等下一个 beta 才拿到修复 | 门禁要求 beta 包含最新正式标签；publish-release.py 提示同批发 beta.N+1 | — |
| 某个 agent 用自己的分支覆盖安装 Debug | 丢掉已装 Debug 里还没进 main 的提交（今天已发生） | PR-0 防回退检查 | `ALLOW_DEBUG_ROLLBACK=1` 显式放行，或先把缺的提交合进来 |
| 安全修复已公开、正式版未修 | v0.9.6 用户可被同机进程利用 | 第 0 步立即发 v0.9.7 | — |
| Pages 清单仓库的改动在本仓库看不到 | beta.json 缺失时，开启 beta 的用户会看到部分失败 | 先部署占位；三包验收 | beta.json 写 release:null：还没装 beta 的用户不受影响；已装 beta 的用户停在当前 beta，修复只能靠发 beta.N+1 或等正式版追上 |
| 分支整理和 Next 删除改的是同一批文件 | 合并冲突 | 按上面的顺序串行合入 | — |

**总体回退：** 每个 PR 都能单独 revert。开关默认关闭，存量用户不受 beta 影响。坏 beta 的处理方式是**往前修**：撤回该 beta（beta.json 置 release:null，阻止新用户进入），再尽快发 beta.N+1；已经装上坏 beta 的用户无法靠撤回救回，只能等修复版或走卸载事务。

---

## 6. 不在本次范围

- 删除 FormalDevelopment 配置（D23）。
- 订阅请求的 User-Agent "XDial-Next/1"（ProfileDocumentService.swift:105）。这是对外网络可见的行为，要单独验证后再改。
- DebugServer 里没有调用方的旧迁移包装（ProfileDocumentService.swift:5-14、24-67），以及 docs/agent/debug-server.md:77-103。
- 死文件 macos/com.kafeifei.xdial.helper.plist。
- 宿主的 InfoPlist.strings 本地化：NSLocation\* 等字段在英文系统下也显示中文（macos/Info.plist:35-43）。
- NE 配置名 "XDial Transparent Proxy" 改名。它是迁移时的兜底匹配键（TransparentProxyManagerSelection.swift:61-65）。
- jev 区分 beta 与正式版（update_channel 字段），等 AI 反馈真正上了 beta 线再加。
- 降级安装能力；dns-takeover.json 遇到未知版本时的安全回退。
- Pages 清单仓库的内部实现。本计划只给出接口要求。
- 预置配置包私有仓库的任何改动。
- AI 反馈功能本身的评审，以及它何时进入 main。
- iOS / tvOS。