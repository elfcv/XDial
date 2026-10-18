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
  已落后的条目。
- 包内 `XDialReleaseTag` 取自构建设置 `XDIAL_RELEASE_TAG`，默认为空；`make release` 目前
  还不传入它，所以现有正式包也为空。它是判断“已装 beta”的唯一依据：只有它能解析为 beta、
  且 X.Y.Z 等于短版本时才算已装 beta，其余一律视为正式版 `v<短版本>`。因此它决定已装版本
  属于哪条线、新旧比较（同号正式版能否算作更新），以及是否额外读取 beta.json。它只能让客户端
  多读 beta.json，不能替换或锁定 stable.json，也不参与签名包授权；`make test-macos-transaction`
  有静态门禁。beta 包的 `XDialReleaseTag` 必须等于它的标签：留空的 beta 会被当作正式版
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
- 验收包的清单地址为 `acceptance/<ID>/<channel>.json`，beta 缓存命名空间为
  `acceptance-<ID>.beta`。

本仓库的发布流程目前只发布 stable。带开关的客户端发布前，清单仓库要先部署 `release: null`
的 beta.json 占位；否则开启 beta 的用户会看到 beta 清单的次要提示。

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
