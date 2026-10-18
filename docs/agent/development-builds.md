# macOS 构建与安装

日常 Debug 由 `make app`（等同 `make app-debug`）生成 `build/XDial Debug.app`，使用 Apple Development 签名，
不提交公证。`FormalDevelopment` 保留正式身份，仅用于该身份的专项验证。
正式归档由 `make release` 生成，签名、公证与发布机制见 [updates.md](updates.md)。
编译期只有 Debug 与正式两个身份；beta 发布使用正式身份，不另设构建配置。`make app` 只接受
`DEVELOPMENT_CHANNEL=debug`（默认值），传入其他值直接报错。

## 通道身份

| 所有权 | Debug | 正式身份 |
|---|---|---|
| 安装路径 | `/Applications/XDial Debug.app` | `/Applications/XDial.app` |
| 系统设置显示名（App / 网络扩展） | `XDial Debug` / `XDial Debug Network Extension` | `XDial` / `XDial Network Extension` |
| Host | `com.kafeifei.xdial.debug` | `com.kafeifei.xdial.app` |
| Settings UI / Extension / Helper / Daemon | Host 加 `.settings-ui` / `.transparent-proxy` / `.helper` / `.daemon` | 同左 |
| 通道偏好域 | `com.kafeifei.xdial.debug` | `com.kafeifei.xdial` |
| 通道运行目录 | `~/.xdial-debug` | `~/.xdial` |
| 新版共享配置 / 密钥 service | `~/.xdial/configuration/profiles.enc` / `com.kafeifei.xdial.configuration` | 同左 |
| helper 状态目录 | `/Library/Application Support/XDial Debug` | `/Library/Application Support/XDial` |
| App Group | `UVZM439VGU.com.kafeifei.xdial.debug.network` | `UVZM439VGU.com.kafeifei.xdial.network` |
| helper socket | `/tmp/xdial-debug.sock` | `/tmp/xdial.sock` |
| 诊断 HTTP | `127.0.0.1:19877` | 当前构建不包含；旧正式身份 Debug 可能使用 `19876` |

新版 Profile 库跨通道共享，首次转换和显式删除数据的边界见 [Profile 配置库](profiles.md)。
系统组件及运行目录仍独立，Debug 不消费正式更新包。身份定义在
[XDialBuildIdentity.swift](../../macos/Shared/XDialBuildIdentity.swift)；通道隔离合同见
[ARCHITECTURE.md](../../ARCHITECTURE.md)。独立安装不表示两个数据面同时接管已经过验证。
显示名只来自 `XDIAL_PRODUCT_DISPLAY_NAME`，各组件的 `.lproj/InfoPlist.strings` 不得定义名字键，所以中文系统里扩展名也是英文；
开发构建、CI 构建和正式归档都经 [verify-macos-component-names.py](../../scripts/verify-macos-component-names.py) 只读核对。

## 签名与构建产物

Debug 的开发证书与 host、extension provisioning profiles 必须匹配 Debug identity。
已登录开发者账号的 Xcode 可通过下列构建参数创建或更新签名资源，该参数会访问 Apple
开发者账号服务：

```sh
make app-debug MACOS_DEBUG_XCODEBUILD_FLAGS=-allowProvisioningUpdates
```

开发构建入口末尾的 [verify-macos-debug-app.py](../../scripts/verify-macos-debug-app.py)
校验嵌套组件身份、签名、开发 profile、App Group、daemon plist 与 helper 编译通道，
不启动 App。host、Settings UI 和 extension 使用同次构建的 `DEBUG_BUILD_VERSION`，
默认取 Unix 时间戳；构建号用于系统识别扩展升级，不等于源码提交。

## 安装命令的实际效果

| 入口 | 实际效果 |
|---|---|
| `make app` / `make app-debug` | 构建并校验 Debug 开发候选包，不替换 `/Applications`，不启动 App |
| 候选包的 `Contents/MacOS/XDial --install-only` | 安装到该通道的 `/Applications` 路径；替换时终止同通道旧 App，并维护旧 helper；不启动后继 App |
| `make restart` | 完整构建 Debug 后退出旧 Debug、安装、启动最终 App，等待安装与连接意图收敛 |
| 从 `/Applications` 外正常启动 App | 自动定位、替换同通道安装并启动最终 App，不是隔离的源码运行 |

`make restart` 在构建前和安装前各运行一次只读的 [check-debug-rollback.sh](../../scripts/check-debug-rollback.sh)：
已装 Debug 的 `XDialSourceRevision` 不是当前 HEAD 的祖先时，列出会被丢掉的提交并停止；读不到修订或本地没有该提交时同样停止
（后者先 `git fetch`）。被拒时，这些提交都已在 `origin/main` 上，就先合入最新 main；否则它们属于别的分支尚未合入的工作，
或本分支 amend / rebase 前的旧提交（列表用 `=` 标出 HEAD 已有同样改动的提交），不要合进当前工作分支，
先和用户确认，再设 `ALLOW_DEBUG_ROLLBACK=1` 显式放行。修订取构建时的 HEAD，不记录未提交的改动。

Debug 曾安装为 `/Applications/XDail Debug.app`。新包发现该路径上签名相同的 Debug 时，先结束旧 App，
由新包注销旧容器注册的 helper，再装到新路径；新版 helper 与 System Extension 就绪后才把旧包移入废纸篓，
仍有进程占用时留给下一次安装事务。正式版按新旧两个路径识别 Debug；此前发布的版本只认旧路径，
新 Debug 运行期间它们的 helper 维护会因进程状态未知而停止，退出 Debug 后恢复。

`--install-only` 不提供保留旧进程或连接的安装能力。实现见
[ApplicationRelocator.swift](../../macos/Sources/XDial/ApplicationRelocator.swift)；
既有重启脚本的交接和验收见 [restart-macos-app.sh](../../scripts/restart-macos-app.sh)。
该脚本在新事务提交后执行一次 HTTPS 检查，目标由 `XDIAL_RESTART_PROBE_URL` 指定，
未设置时为 `https://www.apple.com/`；这次访问仅反映该目标的当前路径结果。

daemon plist 使用标准 `Program` 指向各通道的固定安装路径，保留 SMAppService 的
注册、批准和签名检查。App 在注册前已完成 `/Applications` 定位，不使用依赖后台项目
容器记录的 `BundleProgram` 路径解析。构建门禁校验这一路径与通道身份一致。

不要另写临时脚本交换正在注册的 App 容器来代替产品安装事务。保留运行中的版本时，
先保留已验证候选包，等允许升级时通过安装入口完成旧服务退出、文件替换及新服务验证。
磁盘替换和签名通过均不能替代这笔事务；服务报告 ready 还需实际 PID 和运行 hash 匹配。

候选包校验、磁盘安装、Host 进程与实际运行的 Provider 是不同状态。新扩展代码只有在
系统激活对应扩展后才生效；安装报告与运行态字段见 [debug-server.md](debug-server.md)。

## 开发机 Next 残留清理

Next 身份已移除，产品不再把它当作已知的兄弟版本；它从未分发，只可能残留在开发机上。
Next 的旧配置仍是首次只读迁移的来源，也仍在“删除数据”的清单里，所以下面只做定点清理。

1. 先只读自查，有输出才需要处理：

   ```sh
   ls -d "/Applications/XDial Next.app" ~/.xdial-next ~/Library/Preferences/com.kafeifei.xdial.next.plist \
     ~/Library/Logs/"XDial Next" ~/Library/"Application Support"/"XDial Next" \
     "/Library/Application Support/XDial Next" \
     ~/Library/"Group Containers"/UVZM439VGU.com.kafeifei.xdial.next.network \
     ~/Library/"Application Scripts"/UVZM439VGU.com.kafeifei.xdial.next.network 2>/dev/null
   ls -a /Applications | grep '^\.XDial-next\.'
   sudo ls -d "/private/var/root/Library/Group Containers/UVZM439VGU.com.kafeifei.xdial.next.network" 2>/dev/null
   find /tmp/ -maxdepth 1 -name 'xdial-next*'
   security find-generic-password -s com.kafeifei.xdial.next >/dev/null 2>&1 && echo "keychain item present"
   systemextensionsctl list | grep -F com.kafeifei.xdial.next
   launchctl print system/com.kafeifei.xdial.next.daemon >/dev/null 2>&1 && echo "daemon loaded"
   launchctl print-disabled system | grep -F com.kafeifei.xdial.next
   pgrep -fl 'XDial Next\.app|xdial-next|xdial\.next'
   ```

   `/Applications` 下以 `.XDial-next.` 开头的是安装锁，以及安装事务中断后留下的 `.install-*`、`.backup-*`、
   `.transaction-*`。`pgrep` 要同时匹配 App、Settings UI、扩展和 root 常驻的 helper：helper 的命令行只有
   `xdial-daemon daemon --socket /tmp/xdial-next.sock`，不含 `XDial Next.app`。

2. `XDial Next.app` 还在时，用它自己的卸载流程卸载，**不要勾选“同时删除新旧版本的配置与密码”**。
   这一步会注销 Next 的 helper。
3. 卸载后扩展可能显示 `terminated waiting to uninstall on reboot`，重启后由系统移除。
4. 删 Next 的旧配置前，在 Debug 或正式版的配置窗口确认 Next 用过的 Profile 都已在共享库里；共享库已经存在时也要确认。
   共享库只在 `~/.xdial/configuration/profiles.enc` 不存在时由首启转换建立一次：整库复制 `.xdial`、`.xdial-debug`、
   `.xdial-next` 中修改时间最新的 `profiles.enc`（用对应身份的钥匙串项解密），建立后不再读 `~/.xdial-next`。
   共享库当初从 `.xdial` 或 `.xdial-debug` 转换而来时，Next 的多 Profile 配置库从没进过共享库。
   `ls ~/.xdial/configuration/profiles.enc` 没有输出时，先启动一次 Debug 或正式版完成首启转换，再确认。
5. 不要用任何版本的“卸载并删除数据”清理 Next：它会同时删掉所有版本共用的配置库、正式版与 Debug
   的旧数据和全部配置密钥，还会卸载执行它的那个 App。只用定点命令。第 4 步确认 Profile 都在时：

   ```sh
   rm -rf ~/.xdial-next
   defaults delete com.kafeifei.xdial.next
   security delete-generic-password -s com.kafeifei.xdial.next   # 重复执行，直到提示找不到
   ```

   缺 Profile 或无法确认时不要删：`~/.xdial-next`、它的偏好设置和钥匙串项可能是 Next 配置库仅有的一份，
   删掉无法恢复。只把目录改名备份，偏好设置和钥匙串项都先保留；备份里的 `profiles.enc` 要用钥匙串项
   `com.kafeifei.xdial.next` 里的密钥解密：

   ```sh
   mv ~/.xdial-next ~/.xdial-next.bak-$(date +%Y%m%d)
   ```

   保留备份期间，卸载任何版本都不要勾选“同时删除新旧版本的配置与密码”，它会删掉这个钥匙串项。确认不再需要备份后，
   再删除备份目录，并执行上面的 `defaults delete` 和 `security delete-generic-password`。

6. 其余路径按第 1 步的结果手动删除：两处 App Group 容器（root 那份需要 `sudo`）及
   `~/Library/Application Scripts` 下的同名目录、`~/Library/Logs/XDial Next`、`~/Library/Application Support/XDial Next`、
   root 属主的 `/Library/Application Support/XDial Next`、`/Applications` 下以 `.XDial-next.` 开头的文件和目录，
   以及 `/tmp/xdial-next*`。`launchctl print-disabled` 里只剩的启用记录不对应已加载的服务，可以不处理。
7. 升级 Debug 或正式版前，确认第 1 步的 `pgrep` 没有输出。Next 不再是已知的兄弟身份，它的 App 和 helper
   都会让 helper 维护停在“进程状态未知”；这只暂停维护，不会结束任何进程。Next 的 helper 是 KeepAlive 的
   root daemon，退出 App 不会停止它，用 Next 自己的卸载流程注销 helper 后才恢复。`XDial Next.app` 已被直接删除、
   helper 仍在运行时，重启 Mac：helper 的 launchd plist 和程序都在已删除的包里，重启后不会再被拉起（按
   SMAppService 的机制推断）。

另外：Apple 开发者后台里 Next 的 App ID、App Group 和两份 Developer ID profile 可以作废；
tailnet 里 `xdial-next-*` 的陈旧设备可以手动删除；本地 `build/` 下名字含 `next` 的目录可以删除。
