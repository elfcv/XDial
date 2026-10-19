# 应用更新与发布

正式元数据地址为 `https://saymiao.github.io/xdial-updates/stable.json`，beta 通道为同目录的
`beta.json`；发布仓库为 `saymiao/xdial-updates`。应用归档来自 `kafeifei/XDial` 的 GitHub Releases。
客户端不请求 GitHub Releases API，不解析发布页面，也不携带 GitHub 凭据。
安装与通道合同见 [ARCHITECTURE.md](../../ARCHITECTURE.md)。

## 清单合同

canonical 地址不接受重定向。一份不超过 512 KiB 的 JSON 提供：

- 顶层：`schemaVersion: 1`、递增整数 `revision`、`channel`（stable.json 为 `"stable"`，
  beta.json 为 `"beta"`，必须与所读地址一致）、ISO 8601 UTC `generatedAt`，以及 `release`。
  两份清单的键与顺序完全相同。
- `release: null` 表示暂无可用发布；否则包含 canonical `tag`（stable 为 `vX.Y.Z`，beta 为
  `vX.Y.Z-beta.N`）与 `version`、`build`、
  `minimumSystemVersion`、`publishedAt`、非空 Markdown `releaseNotes`、`archiveURL`、
  `archiveSize`、小写 64 位 `archiveSHA256`。
- 正式归档 URL 为
  `https://github.com/kafeifei/XDial/releases/download/<tag>/XDial-<tag>.zip`。
  归档上限 512 MiB，重定向仅限 GitHub 资产下载边界。

HTTP ETag/304 验证持久缓存；成功检查时间与清单的 `generatedAt` 分离。客户端拒绝旧
revision 或相同 revision 的不同字节，429 按 `Retry-After` 退避。下载和安装分别重新
确认候选身份，撤回或无法确认会阻止操作；归档另有大小、SHA-256、组件版本、签名与身份
校验。用户点击安装前，更新流程不改变连接。

## 客户端通道

正式身份只有一个 App；beta 不是独立身份，只是多读一份清单。

- 偏好键 `xdial.update.channel`（App 的 UserDefaults），只有值为 `"beta"` 才算开启，默认关闭。
  开关在“通用 › 关于与更新”；每次切换都立即检查一次，包括已有下载好、待安装的更新时：清单
  给出的仍是它就保留，否则丢弃并改为可下载的新候选，检查不出结论时也保留。检查、下载、验证或
  交接期间拒绝切换。
- 关闭时传输层只请求 stable.json，URL、缓存键 `xdial.update.pages-cache.production`、
  修订链与解析规则与此前的客户端一致。开启后同时读 beta.json（缓存命名空间
  `production-beta`），取标签更高的候选。
- 已安装 beta 时不论开关都继续读 beta.json，直到 stable 给出高于已装版本的标签。关闭开关
  不降级：已装的 beta 只接收同一 X.Y.Z 线的修复（beta.N+1），不会被带进下一条 beta 线，界面
  显示“等待正式版”；只有“从正式版进入 beta 线”的候选或已暂存更新会在关闭时丢弃。
- 两份清单各自维护退避、ETag 与修订链。stable 失败时本次检查不给结论；只有 beta 失败时
  以 stable 为结论，beta 的失败只作次要提示。例外：已装 beta 而 stable 没有高于它的版本时，
  beta.json 是它唯一的更新来源，读取失败即本次检查不给结论，不显示为已是最新。下载和安装前，
  候选所在的清单必须重新确认成功，另一份清单的失败不阻挡。
- 标签按 SemVer 比较：先比 X.Y.Z，同号时 beta 低于正式版，beta 之间按 N。候选构建号必须
  高于当前构建号，否则报“构建号没有提高”（`build_not_newer`），不显示为已是最新：
  更低的构建号替换不了已激活的网络扩展。每份清单的构建号倒序都写诊断（NSLog 与 Debug Server
  的 `lastBuildNotNewer`），被另一份清单的候选盖过时也一样；stable 已是最新而 beta 倒序时
  显示为失败。
- 代价：beta 线开放期间发 stable 热修复后，beta.json 当前条目的构建号低于这个热修复。装了
  热修复又开着 beta 的用户每次检查都会看到 `build_not_newer`，直到发出包含该热修复的
  beta.N+1 或撤回 beta 条目。所以每次发 stable 后，都要尽快重发或撤回 beta.json 中构建号
  已落后的条目；`make publish` 发 stable 前会检查，见[beta 发布机制](#beta-发布机制)。
- 包内 `XDialReleaseTag` 取自构建设置 `XDIAL_RELEASE_TAG`，默认为空；`make release` 把
  发布标签写进它，正式版和 beta 都写，此前构建的正式包为空。它是判断“已装 beta”的唯一
  依据：只有它能解析为 beta、且 X.Y.Z 等于短版本时才算已装 beta，其余一律视为正式版
  `v<短版本>`。因此它决定已装版本属于哪条线、新旧比较（同号正式版能否算作更新），以及
  是否额外读取 beta.json。它只能让客户端多读 beta.json，不能替换或锁定 stable.json，也不
  参与签名包授权；`make test-macos-transaction` 有静态门禁。beta 包的 `XDialReleaseTag`
  必须等于它的标签（发布合约与 release.yml 都检查）：留空的 beta 会被当作正式版
  `v<短版本>`，同号正式版发布时判为不更新、也不再读 beta.json，用户会停在这个 beta 上，
  直到下一个 X.Y.Z 发布。
- 重启意图为 schema 2，带 `targetBuild`；读取时接受 ≤ 当前 schema 的意图，schema 1（v0.9.x
  写出）只比对版本。
- 构建号降级（例如手动安装旧版或同号预置配置包覆盖 beta）有两道门禁，提示相同：先在 App 内
  卸载（不勾选删除数据），再安装这个版本。
  - 安装期：App 从“应用程序”之外启动并自行安装（含自动更新的暂存包）和 `--install-only`，
    都在安装锁内比较来源与“应用程序”中同身份 App 的 CFBundleVersion，来源更低就拒绝替换。
  - 扩展检查：用 Finder 把旧版拖进“应用程序”覆盖时，宿主在 XDial 运行前已被替换，安装期
    门禁拦不住。之后安装或连接检查网络扩展时，若系统中仍登记着更高构建号的同一扩展（不在
    卸载中），就不再提交激活（系统不会用更低构建号替换它），直接报告这个构建号。
  - 范围：两道门禁都由被装进来的那个更旧的 App 执行：安装期门禁在被启动的来源 App 里，扩展
    检查在替换后的宿主里。所以只有带这两道门禁的构建才会拦截降级。装回不带门禁的构建（目前
    已发布的 v0.9.6 及更早的全部正式版，以及用同样旧源码打的预置配置包）不受保护：宿主照样
    被替换，扩展仍是更高的构建号，两者失配，只能先卸载（不勾选删除数据）再安装。
- 验收包的清单地址为 `acceptance/<ID>/<channel>.json`，beta 缓存命名空间为
  `acceptance-<ID>.beta`。

beta 的构建与发布见[beta 发布机制](#beta-发布机制)。带开关的客户端发布前，清单仓库要先部署
`release: null` 的 beta.json 占位；否则开启 beta 的用户会看到 beta 清单的次要提示。

## 稳定版发布机制

稳定版源码先合入并推送 `main`，再从主线提交创建正式 tag。tag workflow 与普通
`make release` 获取 `origin/main`，要求 tag 指向当前干净工作树的 HEAD，且位于远端
主线的 first-parent 历史。机制入口为 [Makefile](../../Makefile)、
[release.yml](../../.github/workflows/release.yml) 与
[release-contract.sh](../../scripts/release-contract.sh)。

`make release RELEASE_TAG=vX.Y.Z RELEASE_BUILD_NUMBER=<递增整数>` 使用正式身份、
provisioning profiles 与 Developer ID 签名，经公证、staple 和归档校验生成
`build/release/XDial-<tag>.zip` 及 SHA-256。公证使用 `NOTARY_KEYCHAIN_PROFILE`，或
`NOTARY_KEY` / `NOTARY_KEY_ID` / `NOTARY_ISSUER`。`make release-app` 只生成待公证 App；
tag workflow 将完整归档上传为 draft Release。

`make publish RELEASE_TAG=vX.Y.Z` 调用 [publish-release.py](../../scripts/publish-release.py)。
它使用签名 Mac 上的操作员 `gh` 登录，重新获取源码仓库的 main/tag 并校验主线归属，
下载、校验真实附件，再公开 draft、派发更新仓库的 `publish.yml`，等待 Pages 部署并
读取 canonical 清单核对版本、build、摘要和说明。

Pages 发布器串行生成清单、历史与审计记录，拒绝旧版本覆盖、同 tag 内容改写和撤回版本
重发。附件公开与 Pages 生效是两个阶段；Pages 失败时原站点保留，同一发布命令可重试。
`publish.yml` 的 `operation=withdraw` 与 `release_tag` 撤回指定版本，使清单变为
`release: null`，保留历史和资产，不降级已安装 App。

两个通道的 `make publish` 在公开 Release 之前，先做 Pages 发布器公开之后才会做的检查，
不让它会拒绝的包先公开：

- 构建号：新包的构建号必须大于所有“X.Y.Z 不高于新包”的已公开包。数据是 GitHub
  Releases 列表（含 prerelease，不含 draft），以及更新仓库 main 上两个通道的 ledger 与
  history（含已撤回的包，构建号取自首次发布该标签的 history 记录）；清单没有记录的公开
  Release 下载归档读取构建号。X.Y.Z 更高的包不构成约束，所以 beta 线开放期间发 X.Y.Z
  更低的 stable 热修复，不要求高于 beta 的构建号。
- 同一通道只能前进；撤回过的标签不能再发。
- 派发前等待更新仓库里排队或运行中的 `publish.yml` 结束，派发后等这次运行成功结束；
  读回清单时，除 `revision`、`generatedAt` 和 `release` 的值以外，字节必须与既有格式
  一致，`release` 的标签、build、SHA-256 和说明必须与这次发布一致。stable 的派发参数
  与此前相同，不传 `channel`。

## beta 发布机制

beta 与正式版走同一条流水线：同一 Release 配置、签名、公证和发布合约，都构建正式身份。
通道（Makefile 的 `RELEASE_CHANNEL`，合约的 `XDIAL_RELEASE_CHANNEL`，默认 stable）只决定
下表中的差异。

| | stable | beta |
|---|---|---|
| 标签 | `vX.Y.Z` | `vX.Y.Z-beta.N`：N 从 1 起、无前导零；X.Y.Z 取下一个正式版号 |
| 标签所在提交 | `main` 的 first-parent 上 | `xdial-beta` 的 first-parent 上，包含最新的 `vX.Y.Z` 标签，且 X.Y.Z 高于它 |
| 说明文件 | `RELEASE_NOTES.md` | `BETA_RELEASE_NOTES.md`（只在 `xdial-beta` 上），标题 `# XDial vX.Y.Z-beta.N` |
| GitHub Release | draft，公开时标为 Latest | draft prerelease，公开时 `--latest=false` |
| 清单 | stable.json | beta.json |
| 包内 `XDialReleaseTag` | 等于标签；共享合约也接受空值（预置配置包） | 必须等于标签 |
| `SeedProfile`、`RuleSetPresets.json` | release.yml 拒绝；共享合约不查（预置配置包带有） | 合约与 release.yml 都拒绝 |

**构建。** beta 只在 CI 构建：本机构建会按 project.yml 回退嵌入 `macos/PrivateConfig`，beta
合约拒绝这样的包。推送 `vX.Y.Z-beta.N` 后，release.yml（`tags: v*` 同样匹配 beta 标签）按
标签形态选通道和说明文件，取 `origin/xdial-beta` 做合约检查，执行
`make release RELEASE_CHANNEL=beta`，再核对归档的 `XDialReleaseTag` 和私有载荷，上传为 draft
prerelease。beta 的 `release-inputs` 刷新 `origin/xdial-beta` 和 `v*` 标签后检查标签；带
`RELEASE_UPDATE_ACCEPTANCE_ID` 的验收构建跳过这项分支门禁，包仍须通过 beta 合约，
`make publish` 和 release.yml 都拒绝验收包。

**公开。** `make publish RELEASE_CHANNEL=beta RELEASE_TAG=vX.Y.Z-beta.N` 重新从源码仓库获取
`xdial-beta`、这个标签和最新正式标签，核对 first-parent、包含关系和版本；要求 Release 是
prerelease，归档的 `XDialReleaseTag` 等于标签、不含私有载荷；X.Y.Z 必须高于所有公开过的
正式版（GitHub Releases、`releases/latest` 和 stable ledger，含已撤回的）；更新仓库必须已有
beta.json；再做上面的构建号检查。通过后以 `--prerelease --latest=false` 公开 draft，复查
`releases/latest` 仍是原来的正式标签，派发 `channel=beta` 的 `publish.yml` 并读回 beta.json。

**与更新仓库的接口。**

```sh
gh workflow run publish.yml -R saymiao/xdial-updates -f operation=<publish|withdraw|restore> \
  -f channel=<stable|beta> -f release_tag=<tag> -f history_revision=<revision> -f request_id=<id>
```

- `channel` 缺省为 stable。publish 与 withdraw 要 `release_tag`、不要 `history_revision`；
  restore 相反，`history_revision` 是该通道 history 中的 revision。
- 运行名为 `<operation> <channel> <标签或 revision> [<request_id>]`，按 `request_id` 找运行。
- 两个通道的所有操作共用一个并发组，同组最多一个运行中、一个排队，再派发会取消排队中的
  那个。所以派发下一次前必须等上一次运行结束（`gh run watch --exit-status`），stable 热修复
  与 beta.N+1 同批时也逐个派发；被取消的运行按失败处理，要重新派发。`make publish` 自己会等。
- beta 有独立的 revision 链、ledger（`state/beta/ledger.json`）、history
  （`state/beta/history/`）和审计；beta.json 与 stable.json 的键和顺序相同，`channel` 为
  `"beta"`。
- 每次部署上传整个 `site/`：某个通道部署失败后，先用同一命令重跑，或对该通道 withdraw /
  restore，再运行另一个通道。

**发布顺序。**

1. 首次发 beta 前：更新仓库已部署 `release: null` 的 beta.json 占位，且带 beta 开关的正式版
   已经发出。
2. `xdial-beta` 合入最新 main（含最新正式标签），写 `BETA_RELEASE_NOTES.md`，推送
   `vX.Y.Z-beta.N`。
3. CI 生成 draft prerelease 后执行 `make publish RELEASE_CHANNEL=beta RELEASE_TAG=vX.Y.Z-beta.N`。
4. 核对：`releases/latest` 仍是正式标签；stable.json 的 revision 和 SHA-256 不变；beta.json
   是新标签和新构建号。

同批发 stable 和 beta 时先发 stable：beta.N+1 要包含新的正式标签、构建号也要更高，所以在
正式标签之后打标签、构建；前一个 Pages 运行结束后再派发下一个。

**撤回与 restore。**

- 撤回 beta：`gh workflow run publish.yml -R saymiao/xdial-updates -f channel=beta
  -f operation=withdraw -f release_tag=<当前 beta 标签> -f request_id=<id>`。beta.json 变为
  `release: null`，Release 和资产保留，已装的 beta 不降级。撤回的标签不能再发，也不能被
  restore。坏 beta 只能往前修：先撤回，挡住新用户进入，再尽快发 beta.N+1；已经装上的用户
  只能等修复版，或走卸载事务。
- restore：`-f channel=<stable|beta> -f operation=restore -f history_revision=<revision>`
  （不带 `release_tag`）把该通道 history 中的一份内容以更高的 revision 重新发布。客户端拒绝
  revision 倒退，所以清单出错时只能这样回退。被替换的 release 在 ledger 中仍是 published，
  选错 revision 可以再 restore 回去；细节见更新仓库的 README。

**stable 热修复后的 beta。** beta 线开放期间发 X.Y.Z 更低的 stable 热修复后，beta.json 的
条目标签比热修复新、构建号却更低，装了热修复又开着 beta 的用户每次检查都报
`build_not_newer`。`make publish`（stable）在公开之前读取更新仓库的 beta.json，发现这样的
条目就停下，要求用 `RELEASE_BETA_FOLLOWUP=republish` 或 `withdraw`（脚本参数
`--beta-followup`）确认同批的后续动作，发布完成后打印下一步命令：

- republish：`xdial-beta` 合入含热修复标签的 main，打 beta.N+1，CI 构建后
  `make publish RELEASE_CHANNEL=beta`；
- withdraw：等 Pages 运行结束后撤回这个 beta 条目。

beta 条目的标签不高于这次 stable 时（例如 stable 追上了这条 beta 线），它只是被取代，不需要
后续动作。

**共享格式门禁。** 持久格式、跨进程协议和依赖版本只经 main 演进，beta 专属数据只能放在
独立文件或 `xdial.beta.*` 键。`xdial-beta` 的 push 和以它为目标的 PR 在 CI 里多一项检查
（[ci.yml](../../.github/workflows/ci.yml) 的 `beta-shared-formats`）：相对上次合入的 main，
依赖与补丁入口、配置库模型与 schema 所在文件必须没有改动，文件清单见该任务。

## 正式身份双包验收

[build-update-acceptance.py](../../scripts/build-update-acceptance.py) 从同一个干净源码提交
构建 A/B，仅改变版本号与递增 build，要求新的输出目录：

```sh
python3 scripts/build-update-acceptance.py \
  --id pages-YYYYMMDD --lower-version 0.8.1 --higher-version 0.8.2 \
  --output /absolute/path/to/new-acceptance-run --notary-profile xdial-notary
```

脚本调用正式 `make release`，保存两份公证包和含 `sourceCommit` 的 `BUILD-INFO.json`，
不安装、启动或上传。`RELEASE_UPDATE_ACCEPTANCE_ID` 使本地验收构建跳过稳定版 tag/main
门禁；稳定版发布脚本仍拒绝验收包。

两包签名 Info.plist 的 `XDialUpdateAcceptanceID` 相同，清单地址固定为
`https://saymiao.github.io/xdial-updates/acceptance/<ID>/stable.json`，资产使用
`saymiao/xdial-updates` 的 prerelease。当前与传入 App 的 acceptance ID 必须相同。
这些包使用正式身份，安装会替换正式 App，重启可能中断当前连接。

同源码 A→B 覆盖该实现的更新机制，不证明旧正式客户端的升级兼容，也不证明修改前后
工作流一致。包签名校验不包含实际 UI、helper、扩展交接、连接恢复或流量结果。
旧客户端仍执行旧更新逻辑，进入新逻辑依赖手动安装或旧通道成功更新。
