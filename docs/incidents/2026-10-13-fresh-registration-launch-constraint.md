# 全新登记被接受，launchd 却拒绝启动 daemon

## 现场

2026-10-13 16:25（America/Los_Angeles），本机从 Chrome 下载的正式身份 v0.9.2 企业包
在「下载」中直接打开，经 AppTranslocation 运行后完成 bundle 替换。App 日志：

- 23:25:31Z 旧 v0.9.1 服务注销完成，`statusAfter=0`。
- 23:25:43Z 全新登记 `statusBefore=0`，`result=accepted statusAfter=1`。
- 23:25:50Z 6 秒验证窗口内没有 daemon，安装报告 `helper-serviceUnavailable`。

launchd 日志给出原因：16:25:44 首次 spawn 即 `OS_REASON_CODESIGNING | Launch Constraint
Violation (Constraint not matched)`；随后每 10 秒请求修复 LWCR，均报
`Unable to get updated LWCR for (7C292822-…, (null), 0)`，job 属性为 `needs LWCR update`。
已安装 daemon 的签名、Team ID、Designated Requirement 均有效。

23:30 同一份下载再次打开：同样注销、同样全新登记，launchd 得到新的 BTM 条目
`A124346B-…`，daemon 立即启动，安装 ready。区别在于系统新建了这条后台服务记录。

## 复现尝试

同日依次尝试，均一次 ready，未能复现：

| 通道 | 条件 | 结果 |
|---|---|---|
| Debug | 已确认隔离标记、AppTranslocation、daemon 变化，两次 | ready |
| 正式身份 A/B 验收包 | Chrome 隔离标记、归档实用工具解压、首次 Gatekeeper 确认、0.9.2→0.9.3 | ready |
| 官方 v0.9.1 | 同上流程从 0.9.3 装回 | ready |
| 企业包 v0.9.2 | 原样重放：同一 zip、同一隔离标记，0.9.1→0.9.2 | ready |

未能还原的只有失败当时的系统状态：旧服务记录已存在约两周，旧 daemon 已连续运行约
35 小时。BTM 数据库需要管理员权限读取，没有直接证据说明记录为何携带无法满足的约束，
因此根因停在「系统后台任务记录偶发失效」，不能归因于下载、隔离或企业包内容。

## 改动

安装事务原先把 SMAppService 接受全新登记视为成立，现场证明它不足以说明 launchd 能启动
服务。全新登记后验证窗口内 daemon 缺席时，事务改为沿用既有的「注销后重新登记」路径
重建一次记录，再按原条件验证；重建后仍缺席才报告 `serviceUnavailable`，运行其他版本仍
报告 `versionMismatch` 且不重建。这与界面「重试」及现场恢复的动作相同，只是不再需要用户。

## 已验证与未验证

- `HelperRegistrationCoordinatorTests` 覆盖：重建一次后 ready；最多重建一次；错误版本不重建。
- 重建路径是已在生产中由「重试」触发的既有代码。
- 由于无法复现，新逻辑没有在真实失效记录上验证过；无法证明立即重建一定得到可用记录。
